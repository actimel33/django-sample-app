# Docker image optimization

The week 6 image worked but carried a compiler toolchain, an installer, a copy of
every Django translation and the whole source tree. This describes what was
removed, what it bought, and where the optimization deliberately stopped.

All numbers come from the same machine (WSL2, Docker 29.6.1, buildx 0.35) and the
same method, described under [Reproducing the measurements](#reproducing-the-measurements).
Build and latency figures are the mean of two runs; the before column is built from
the week 6 Dockerfile in a worktree, so both are measured under identical conditions.

## Result

| Metric | Before | After | Change |
|---|---|---|---|
| Image size, unpacked | 319.9 MB | 255.7 MB | −64 MB (−20%) |
| Image size, compressed (what a pull transfers) | 104.4 MB | 77.3 MB | −27 MB (−26%) |
| Cold build, empty builder cache | 94 s | 40 s | −57% |
| Rebuild after a one-line code change | 9 s | 8 s | −11% |
| `dive` efficiency | 91.0% | 97.7% | +6.7 pp |
| `dive` wasted bytes | 44 MB | 6.0 MB | −86% |
| Trivy findings with a fix available | 15 (4 HIGH) | 3 (0 HIGH) | −80% |
| Time from `docker run` to first HTTP 200 | 2.82 s | 2.85 s | unchanged |
| Latency, 200 sequential requests | 14.6 ms/req | 14.6 ms/req | unchanged |

## How the image is assembled

Three stages. Only the third one ships.

| Stage | Purpose | Reaches the final image |
|---|---|---|
| `deps` | creates the venv, installs dependencies with uv | the venv, as a single layer |
| `assets` | runs `collectstatic`, `compress`, `populate_searchdb` | the generated files only |
| runtime | base image, `libpq5`, the application code | this is the image |

The `assets` stage exists because building the static files needs inputs the
running application never reads: `static/` sources, the full source tree, Django's
staticfiles finders.

## What was removed, and why

### The build toolchain (−43.5 s of build time)

The old builder stage installed `build-essential`, `libcurl4-openssl-dev`,
`libssl-dev` and `libpq-dev` so that pycurl and psycopg could be compiled. Reading
the build log showed that nothing was being compiled:

```
Building wheels for collected packages: oncalendar
```

### pip, in two places (−13 MB, −6 findings)

`pip` is a build-time tool. It was shipped twice:

- inside the venv — removed by switching to `uv`, whose `uv venv` creates an
  environment without pip at all;
- inside the base image — `python:3.12-slim` carries its own pip in
  `/usr/local/lib/python3.12`. It is deleted in the runtime stage.

### Django's compiled translations (−9 MB)

`USE_I18N = False` in `hc/settings.py`, so the `.mo` catalogs are never read.

### Build-time inputs, via a selective COPY (−11 MB)

`COPY . .` put 19.7 MB into the image. The runtime stage now copies only what the
application reads: `hc/`, `templates/`, `manage.py`, `CHANGELOG.md` (settings read
it at import time), the entrypoint, and the two generated artifacts from the
`assets` stage.

`.dockerignore` additionally drops `docs/`, `stuff/`
(development helpers) and `requirements-dev.txt` from the build context.

### A `chown -R` that duplicated the static files (−10 MB)

```dockerfile
RUN chown -R app:app /app/static-collected /app/tmp /app/run
```

`chown -R` rewrites metadata on every file it touches, so the layer contains a
second copy of all 10.4 MB of collected static files. Nothing writes to
`static-collected` at runtime — `collectstatic` already ran during the build — so the
directory stays owned by root and only the two writable directories are chowned.

`dive` found this: the same files appeared twice, in two adjacent layers.

### A stale base image digest (−20 MB of waste)

The runtime stage runs `apt-get upgrade` to pick up fixes published after the base
image was built. Against a four-month-old digest it replaced `libcrypto.so.3`,
`libssl.so.3`, `openssl` and `libpcre2` — and the superseded copies stay in the base
layer forever. That was 20 MB of the 44 MB `dive` reported as wasted, and an
18-second build step.

### libcurl (one dependency fewer)

pycurl's wheel bundles its own libcurl:

## Build time and layer caching

Two things make the cached rebuild fast, and both were already in place before
this week:

- `requirements.txt` is copied before the source code.
- the installer's download cache lives in a cache mount
  (`--mount=type=cache,target=/root/.cache/uv`), so it survives between builds
  without ever being written into a layer.

What changed this week is the work being cached. Removing the toolchain took the
cold build from 94 s to 40 s. Replacing pip with uv took dependency installation
from 22.1 s to 15.6 s — real, but a smaller share of the total than expected, and
on a cold builder it is partly offset by pulling the uv binary (6 s). The honest
summary: uv's measurable win here is a venv without pip; the speed-up matters more
on a warm builder, where the uv image is already present.

The remaining 8 seconds of a cached rebuild are `collectstatic` and `compress`.
They depend on the source tree, so a code change always re-runs them. Splitting
them into their own stage keeps them off the critical path for dependency changes
but cannot make them free.

`python:3.12-alpine` is 62 MB against 134 MB for `python:3.12-slim`, so it was
worth an experiment rather than an assumption. It builds and runs correctly, after
two musl-specific problems:

- **pycurl has no musl wheel.** It compiles from source, which brings
  `build-base`, `curl-dev` and `openssl-dev` back into the build.
- **psycopg could not find libpq.** The pure-Python build locates it with
  `ctypes.util.find_library`, which on musl returns `None` — it relies on
  `ldconfig`, `gcc` or `objdump`, none of which exist in a runtime image.
  `ctypes.CDLL("libpq.so.5")` works, so the library is there; the lookup is what
  fails. The fix is `psycopg[c]`, a compiled implementation that links libpq
  directly — which means deviating from `requirements.txt` and compiling another
  package.

With both in place, the Alpine image works: all pages return 200 and pycurl
completes a real HTTPS request.

| | slim (shipped) | Alpine |
|---|---|---|
| Image size, unpacked | 255.7 MB | 186.9 MB |
| Cold build | 40 s | 96 s |
| Time to first HTTP 200 | 2.85 s | 4.29 s |
| Latency, 200 requests | 14.6 ms/req | 16.2 ms/req |
| Trivy findings with a fix | 3 | 9, six of them the base image's pip |
| Trivy findings without a fix | 187 | 0 |

Alpine is 69 MB smaller and loses on everything else: a cold build takes more than
twice as long, startup is 50% slower, and requests are 12% slower — both measured
twice with consistent results. Startup matters here because the image runs on ECS
Fargate, where every rolling deployment and every scale-out waits for it.

The security column looks decisive and is not. Once the base image's pip is
removed — the same one-line deletion the shipped image does — both are left with the
**same three** fixable findings, all in application dependencies. The 187 others are Debian
packages where the Debian security team has marked the CVE as not warranting a
fix; Alpine's tracker simply does not carry those entries. Different accounting of
the same code, not a different risk.

Trading 69 MB for slower builds, slower startup, a compiler in the build and a
dependency deviation is not worth it. The decision is reversible: the diff is five
lines, documented above.