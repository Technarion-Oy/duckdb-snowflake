# Optional: DuckDB 2.0 runtime for a shared server that refreshes the Power BI warehouse
# file unattended. On a single Windows workstation use duck.ps1 natively instead.
# Build context is the repo root (see docker-compose.yml): it copies refresh/ and docker/.
FROM python:3.12-slim

ARG DUCKDB_VERSION=2.0.0
# Set automatically by Docker buildx: amd64 on Intel, arm64 on Apple Silicon.
ARG TARGETARCH=amd64

ENV PYTHONUNBUFFERED=1 \
    DUCKDB_PATH=/data/warehouse.duckdb \
    PARQUET_DIR=/data/parquet \
    HOME=/root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# DuckDB CLI (same version as the Python package so both share one extension dir).
RUN set -eux; \
    mkdir -p /tmp/duckdb-cli; \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb-cli-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp/duckdb-cli; \
    install -m 0755 "$(find /tmp/duckdb-cli -type f -name duckdb | head -n1)" /usr/local/bin/duckdb; \
    rm -rf /tmp/duckdb-cli; \
    duckdb --version

RUN pip install --no-cache-dir "duckdb==${DUCKDB_VERSION}"

# Pre-install the extensions at build time so a refresh never has to reach
# extensions.duckdb.org at runtime.
RUN python -c "import duckdb; c = duckdb.connect(); c.execute('INSTALL httpfs; INSTALL iceberg;'); print('extensions installed')"

WORKDIR /app
COPY refresh/refresh.py /app/refresh.py
COPY refresh/sql /app/sql
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

VOLUME ["/data"]
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["loop"]
