#!/bin/sh
# Migrations run here because a single copy is running. With more than one,
# parallel starts would race on the schema and this belongs in a separate
# one-off task instead.
set -eu

echo "==> applying database migrations"
python manage.py migrate --noinput

echo "==> starting application"
# exec, so ECS signals reach gunicorn and the container stops cleanly.
exec "$@"
