# Coldwater, self-hosted.
#
# Multi-stage so the runtime image carries no build toolchain. The contract —
# the schema and the prompt exported from Dart — is copied in beside the
# application rather than being read from a git checkout two directories up,
# which is what COLDWATER_CONTRACT_DIR exists for.

FROM python:3.12-slim AS build

WORKDIR /build
COPY server/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim

# Nothing here runs as root. The data directory is the only writable path the
# application needs, and it is the one thing worth protecting: it holds the
# API key and, if the user turned history on, their audits.
RUN useradd --create-home --uid 10001 coldwater \
    && mkdir -p /data \
    && chown coldwater:coldwater /data

COPY --from=build /install /usr/local

WORKDIR /srv
# The build context is the repository root, not server/, because the
# exported contract lives outside this directory and a COPY cannot reach
# above its context.
COPY --chown=coldwater:coldwater server/app ./app
COPY --chown=coldwater:coldwater server/web ./web
COPY --chown=coldwater:coldwater contracts /srv/contracts

ENV COLDWATER_CONTRACT_DIR=/srv/contracts \
    COLDWATER_DATA_DIR=/data \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER coldwater
VOLUME ["/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/api/health', timeout=4).status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
