# Panel image - minimal + non-root (build context = app/, so:
#   docker build -f app/Dockerfile app/
# from the repo root). Runtime deps only; tests/dev files are pruned via
# app/.dockerignore. Build + publish wiring is proven at the Sequence-70
# image pipeline; this file stays lintable and minimal here.
FROM python:3.12-slim

RUN adduser --disabled-password --gecos "" --uid 10001 panel

WORKDIR /srv/panel
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# The tree lands under /srv/panel/app so `uvicorn app.main:app` resolves.
COPY . ./app

USER panel
ENV PANEL_PORT=8090
EXPOSE 8090
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PANEL_PORT:-8090}"]
