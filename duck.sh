#!/usr/bin/env bash
# Helper for the DuckDB <- Snowflake Iceberg on S3 -> Power BI stack (macOS / Linux / WSL).
# On Windows use duck.ps1 instead.
#   ./duck.sh init        create docker/.env from the example
#   ./duck.sh build       build the DuckDB 2.0 image
#   ./duck.sh refresh     one-off read of the Iceberg tables from S3 into data/warehouse.duckdb (+ Parquet)
#   ./duck.sh up          start the background sync loop (REFRESH_INTERVAL_SECONDS)
#   ./duck.sh down        stop it
#   ./duck.sh logs        follow the sync log
#   ./duck.sh shell       DuckDB CLI, read-only, on data/warehouse.duckdb
#   ./duck.sh live        DuckDB CLI querying the S3 Iceberg tables directly (no local copy)
#   ./duck.sh status      what Power BI will see: tables, row counts, last refresh
#   ./duck.sh notebook    JupyterLab (local venv) with notebooks/explore.ipynb on data/warehouse.duckdb
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose -f "$ROOT/docker/docker-compose.yml" --env-file "$ROOT/docker/.env")

need_env() {
  if [[ ! -f "$ROOT/docker/.env" ]]; then
    echo "docker/.env is missing. Run ./duck.sh init and fill in the S3 location + AWS access." >&2
    exit 1
  fi
}

need_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed. See https://docs.docker.com/engine/install/" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker engine is not running. Start Docker Desktop (or: colima start)." >&2
    exit 1
  fi
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  init)
    if [[ -f "$ROOT/docker/.env" ]]; then
      echo "docker/.env already exists; not overwriting."
    else
      cp "$ROOT/docker/.env.example" "$ROOT/docker/.env"
      echo "Created docker/.env. Edit it: ICEBERG_S3_ROOT, AWS_REGION and AWS_PROFILE (or static keys)."
    fi
    ;;
  build)   need_docker; need_env; "${COMPOSE[@]}" build ;;
  refresh) need_docker; need_env; "${COMPOSE[@]}" run --rm duckdb refresh ;;
  up)      need_docker; need_env; "${COMPOSE[@]}" up -d --build; echo "Sync loop running. ./duck.sh logs to follow." ;;
  down)    need_docker; "${COMPOSE[@]}" down ;;
  logs)    need_docker; "${COMPOSE[@]}" logs -f duckdb ;;
  shell)   need_docker; need_env; "${COMPOSE[@]}" run --rm -it duckdb shell "$@" ;;
  live)    need_docker; need_env; "${COMPOSE[@]}" run --rm -it duckdb live "$@" ;;
  status)
    need_docker; need_env
    "${COMPOSE[@]}" run --rm duckdb shell -c "
      SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_schema = 'reporting' ORDER BY 3, 2;
      SELECT * FROM reporting.refresh_log ORDER BY refreshed_at DESC LIMIT 10;"
    ;;
  notebook)
    VENV="$ROOT/notebooks/.venv"
    if [[ ! -x "$VENV/bin/jupyter" ]]; then
      echo "Creating notebooks/.venv and installing notebooks/requirements.txt ..."
      python3 -m venv "$VENV"
      "$VENV/bin/pip" install -q -r "$ROOT/notebooks/requirements.txt"
    fi
    [[ -f "$ROOT/data/warehouse.duckdb" ]] || echo "Note: data/warehouse.duckdb does not exist yet; run ./duck.sh refresh first."
    exec "$VENV/bin/jupyter" lab --notebook-dir="$ROOT/notebooks" "$ROOT/notebooks/explore.ipynb"
    ;;
  help|*)
    sed -n '2,15p' "$0"
    ;;
esac
