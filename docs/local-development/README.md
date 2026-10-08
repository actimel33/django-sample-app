# Local development with Docker Compose

The application and PostgreSQL start with one command; only Docker is needed on the
host. Tested with Docker Engine 29.6.1 and Compose 5.2.0.

## Quick start

```bash
cp .env.example .env
docker compose up -d --wait
docker compose exec web python manage.py createsuperuser
```

Open <http://localhost:8000> (start-up takes about 20 s) and log in with that
account; email login needs SMTP, which is not configured. The values in
`.env.example` are for a local database that is not published on the host; do not
reuse them elsewhere.

## Services

| Service | Purpose | Published |
|---|---|---|
| `db` | `postgres:18-alpine` (same major as RDS), data in the `db-data` volume | nothing |
| `migrate` | applies migrations once, then exits | nothing |
| `web` | `runserver` with auto-reload, code bind-mounted | `127.0.0.1:8000` |

Start order: `db` healthy → `migrate` exited 0 → `web` healthy. `web` and `migrate`
use the `dev` target of the production `Dockerfile` (same `deps` stage, same
packages); its last stage is still production.

## Commands

| Task | Command |
|---|---|
| Logs | `docker compose logs -f web` |
| Edit code | save the file, `runserver` reloads |
| Dependencies or Dockerfile changed | `docker compose up -d --build`, or keep `docker compose watch` running |
| Management command | `docker compose exec web python manage.py <cmd>` |
| `psql` | `docker compose exec db psql -U postgres hc` |
| Stop, keep data / wipe data | `docker compose down` / `docker compose down -v` |

## Decisions

- **Volume on `/var/lib/postgresql`.** Postgres 18 exits with `in 18+, these Docker
  images...` if the volume is on `.../data`, even when empty.
- **Healthcheck over TCP as the real user and database.** A bare `pg_isready`
  passed about 600 ms before the database accepted connections: the init server
  listens on the unix socket only (`listen_addresses=''`).
- **Migrations in a one-shot service.** `web` starts only after it exits 0
  (`service_completed_successfully`). Without a migration step the stack came up
  healthy with no tables.
- **`APP_UID`/`APP_GID` (default 1000).** An empty `user:` means root, and files
  written to the bind mount become `root:root`. `UID`/`GID` are not used: bash does
  not export `UID` and has no `GID`, so Compose sees both empty. Set them from
  `id -u` / `id -g` if yours differ, then `docker compose up -d --force-recreate`.
- **Ports on `127.0.0.1`, database not published:** the development server must not
  be reachable from the LAN.
- **`:?` on `DB_PASSWORD`:** a missing `.env` fails before anything starts, with a
  message saying what to do.
- **`.env` is in `.gitignore` and `.dockerignore`.**

## Why it helps a team

One reviewed file replaces per-machine steps (install Postgres, create a role and a
database, set up a virtualenv, export variables, run migrations). The Postgres major
and Python packages match production, `down -v` then `up` gives a clean database,
and nothing is installed on the host.

## Differences from production

| | Local | ECS |
|---|---|---|
| Server | `runserver` | `gunicorn` |
| Code | bind-mounted | copied in, owned by root |
| Root filesystem | writable | read-only |
| `DEBUG` | on | off |
| Migrations | one-shot service | entrypoint |

The dev image is for development only; do not deploy it.
