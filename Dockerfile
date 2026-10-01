# syntax=docker/dockerfile:1

# Django healthchecks, image for ECS Fargate.
# Two stages: pycurl and psycopg compile from source, the toolchain stays here.

################################################
#                    Build                     #
################################################
# Pinned by digest: a tag can move, a digest cannot.
FROM python:3.12-slim@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f AS builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libcurl4-openssl-dev \
        libssl-dev \
        libpq-dev

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
RUN python -m venv "${VIRTUAL_ENV}"

# Before the code: copying the code first would invalidate this layer on every
# edit and rebuild pycurl.
COPY requirements.txt ./

# gunicorn is a deployment choice, not an application dependency.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip && \
    pip install -r requirements.txt gunicorn==26.2.0

################################################
#                   Runtime                    #
################################################
FROM python:3.12-slim@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f

# Runtime libraries only. upgrade picks up fixes released after the base image;
# cleanup shares the layer, otherwise the files stay in the image.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
        libcurl4 \
        libpq5 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
             /var/log/apt/* \
             /var/cache/debconf/*-old \
             /var/lib/dpkg/*-old \
             /tmp/* \
    && find /var/log -type f -delete

RUN useradd --system --create-home --uid 10001 --shell /usr/sbin/nologin app

# TMPDIR points at /dev/shm: with a read-only root ECS mounts /tmp as a
# root-owned volume that uid 10001 cannot write to.
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TMPDIR=/dev/shm \
    HOME=/dev/shm

COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}

WORKDIR /app
COPY --chown=app:app . .

# COMPRESS_OFFLINE is on: without compress at build time the app fails at runtime.
RUN python manage.py collectstatic --noinput && \
    python manage.py compress --force && \
    chown -R app:app /app/static-collected

USER app

# Fails the build if the image ends up running as root.
RUN test "$(id -u)" -ne 0 || (echo "image runs as root" && exit 1)

EXPOSE 8000

# Same endpoint the load balancer uses: it queries the database.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/v3/status/', timeout=3).status == 200 else 1)"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
# worker-tmp-dir on tmpfs: gunicorn touches that file on every request.
CMD ["gunicorn", "hc.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "--error-logfile", "-"]
