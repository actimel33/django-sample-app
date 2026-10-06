# syntax=docker/dockerfile:1

# Django healthchecks, image for ECS Fargate.
# Three stages: dependencies, static assets, runtime. Nothing that is only
# needed to build the image reaches the final one.

# Pinned by digest: a tag can move, a digest cannot.
ARG BASE=python:3.12-slim@sha256:ddb0207ae1f0356c2b724d740769b0c5f5f51cc54a0525178f721825f78fe74c

################################################
#                 Dependencies                 #
################################################
# No compiler here: every dependency but oncalendar (pure Python) ships a
# manylinux wheel, so build-essential and the -dev headers were dead weight.
FROM ${BASE} AS deps

# uv resolves and installs in parallel, and its venv carries no pip at all.
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /usr/local/bin/uv

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
RUN uv venv "${VIRTUAL_ENV}"

# Before the code: copying the code first would invalidate this layer on every edit.
COPY requirements.txt /tmp/requirements.txt

# gunicorn is a deployment choice, not an application dependency.
# compile-bytecode: without it Python recompiles every import on each start,
# because the runtime filesystem is read-only.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --compile-bytecode -r /tmp/requirements.txt gunicorn==26.2.0

# USE_I18N is False, so the compiled translations are never read. Deleting them
# in a later layer still pays off: the runtime stage copies this venv as one layer.
RUN find "${VIRTUAL_ENV}" -name '*.mo' -delete

################################################
#                Static assets                 #
################################################
# COMPRESS_OFFLINE is on: without compress at build time the app fails at runtime.
# Runs where static/ and the full source tree are available; only the result is
# carried into the runtime stage.
FROM deps AS assets
WORKDIR /app
COPY . .
# populate_searchdb rebuilds search.db from templates/docs; the file is a build
# artifact, so it is generated here instead of being committed.
RUN python manage.py collectstatic --noinput && \
    python manage.py compress --force && \
    python manage.py populate_searchdb

################################################
#                   Runtime                    #
################################################
FROM ${BASE}

# libpq5 only: psycopg loads libpq at runtime, and pycurl's wheel bundles its
# own libcurl. upgrade picks up fixes released after the base image; cleanup
# shares the layer, otherwise the files stay. The base image's pip goes too:
# unused here, and its CVEs would show up in every scan.
# No version pin: the upgrade above already moves packages to the latest patch
# release, and a pin would break whenever the base digest is refreshed.
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

# TMPDIR and HOME point at writable paths: the root filesystem is read-only.
# /dev/shm is not used for these: Fargate caps it at 64 MB.
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TMPDIR=/app/tmp \
    HOME=/app/run

COPY --from=deps ${VIRTUAL_ENV} ${VIRTUAL_ENV}

WORKDIR /app
# Only what the application reads at runtime, and it stays owned by root: the
# process runs as app and must not be able to rewrite its own code.
COPY hc ./hc
COPY templates ./templates
COPY manage.py CHANGELOG.md docker-entrypoint.sh ./
COPY --from=assets /app/static-collected ./static-collected
COPY --from=assets /app/search.db ./search.db

# tmp and run are the only writable paths; volumes mounted over them inherit
# this ownership. static/ stays empty: the sources are not needed once the
# assets are built, but Django's checks warn when STATICFILES_DIRS is missing.
RUN mkdir -p /app/tmp /app/run /app/static && chown app:app /app/tmp /app/run

# Numeric, so a host checking for a non-root user does not need to resolve the name.
USER 10001

# Fails the build if the image ends up running as root.
RUN test "$(id -u)" -ne 0 || (echo "image runs as root" && exit 1)

EXPOSE 8000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
# worker-tmp-dir on tmpfs: gunicorn touches that file on every request.
CMD ["gunicorn", "hc.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "--error-logfile", "-"]
