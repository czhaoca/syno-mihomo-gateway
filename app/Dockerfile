# Panel image - minimal + non-root (build context = app/, so:
#   docker build -f app/Dockerfile app/
# from the repo root). Runtime deps only; tests/dev files are pruned via
# app/.dockerignore. Build + publish wiring is proven at the Sequence-70
# image pipeline; this file stays lintable and minimal here.

# --- frontend builder (#78) --------------------------------------------------
# The UI build lives HERE rather than in CI because the sibling Panel Build
# workflow builds from a fresh checkout of the release tag and cannot consume
# a Woodpecker artifact. Keeping it in the Dockerfile is what makes a local
# `docker build` reproduce the shipped image exactly.
#
# `npm ci` (not `install`) so the lockfile is authoritative: a build that
# silently resolved different versions than the one that was tested is not a
# reproduction of anything.
FROM node:22-slim AS ui
WORKDIR /build
COPY ui/package.json ui/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY ui/ ./
RUN npm run build

# --- runtime -----------------------------------------------------------------
FROM python:3.12-slim

RUN adduser --disabled-password --gecos "" --uid 10001 panel

WORKDIR /srv/panel
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# The tree lands under /srv/panel/app so `uvicorn app.main:app` resolves.
COPY . ./app

# The built UI, copied into the source tree the app already serves from.
# Nothing built is committed to git; it exists only inside the image.
COPY --from=ui /build/dist ./app/ui/dist

# NOTE the final stage stays python:3.12-slim with python3 on PATH, and that
# is load-bearing beyond uvicorn: since #74 `gateway.sh alias --sync` runs
# THIS image as a one-shot python runtime
# (`docker run --rm -i --entrypoint python3 $PANEL_IMAGE`), because DSM has
# no host python3. Swapping the runtime base for a distroless or node image
# would break a shipped CLI verb with no test in this repo to catch it.
USER panel
ENV PANEL_PORT=8090
EXPOSE 8090
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PANEL_PORT:-8090}"]
