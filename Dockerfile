# syntax=docker/dockerfile:1

# Django healthchecks, image for ECS Fargate.
# Three stages: dependencies, static assets, runtime. Nothing that is only
# needed to build the image reaches the final one.

# Pinned by digest: a tag can move, a digest cannot.
ARG BASE=python:3.12-slim@sha256:ddb0207ae1f0356c2b724d740769b0c5f5f51cc54a0525178f721825f78fe74c

################################################
#                 Dependencies                 #
################################################
FROM ${BASE} AS deps

# uv resolves and installs in parallel, and its venv carries no pip.
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /usr/local/bin/uv

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
RUN uv venv "${VIRTUAL_ENV}"

COPY requirements.txt /tmp/requirements.txt

# gunicorn is a deployment choice, not an application dependency.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --compile-bytecode -r /tmp/requirements.txt gunicorn==26.2.0

# Compiled translations are never read.
RUN find "${VIRTUAL_ENV}" -name '*.mo' -delete

################################################
#                Static assets                 #
################################################
FROM deps AS assets
WORKDIR /app
COPY . .

RUN python manage.py collectstatic --noinput && \
    python manage.py compress --force && \
    python manage.py populate_searchdb

################################################
#                 Development                  #
################################################
FROM deps AS dev

# psycopg loads libpq at runtime; deps does not need it.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/*

# The code is bind-mounted, not copied. No collectstatic: COMPRESS_ENABLED
# defaults to `not DEBUG`.
WORKDIR /app
ENV PYTHONUNBUFFERED=1

EXPOSE 8000
# runserver reloads itself when a file changes.
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]

################################################
#                   Runtime                    #
################################################
FROM ${BASE}

# hadolint ignore=DL3008
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
        libpq5 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
             /var/log/apt/* \
             /var/cache/debconf/*-old \
             /var/lib/dpkg/*-old \
             /tmp/* \
    && find /var/log -type f -delete \
    && rm -rf /usr/local/lib/python3.12/site-packages/pip \
              /usr/local/lib/python3.12/site-packages/pip-*.dist-info \
              /usr/local/lib/python3.12/ensurepip

RUN useradd --system --create-home --uid 10001 --shell /usr/sbin/nologin app

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TMPDIR=/app/tmp \
    HOME=/app/run

COPY --from=deps ${VIRTUAL_ENV} ${VIRTUAL_ENV}

WORKDIR /app
# Only what the application reads at runtime, and it stays owned by root
COPY hc ./hc
COPY templates ./templates
COPY manage.py CHANGELOG.md docker-entrypoint.sh ./
COPY --from=assets /app/static-collected ./static-collected
COPY --from=assets /app/search.db ./search.db

RUN mkdir -p /app/tmp /app/run /app/static && chown app:app /app/tmp /app/run

USER 10001

# Fails the build if the image ends up running as root.
RUN test "$(id -u)" -ne 0 || (echo "image runs as root" && exit 1)

EXPOSE 8000

ENTRYPOINT ["/app/docker-entrypoint.sh"]

CMD ["gunicorn", "hc.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "--error-logfile", "-"]
