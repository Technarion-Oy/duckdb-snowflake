#!/usr/bin/env bash
# Shared-server (Linux) wrapper around docker compose. Run from anywhere.
#   docker/server.sh build | up | down | logs | refresh | status | shell | live | export-sql | refresh-sql
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] || { echo "$ROOT/.env is missing (copy .env.example)" >&2; exit 1; }
COMPOSE=(docker compose -f "$ROOT/docker/docker-compose.yml" --env-file "$ROOT/.env")
cmd="${1:-help}"; shift || true
case "$cmd" in
  build)   "${COMPOSE[@]}" build ;;
  up)      "${COMPOSE[@]}" up -d --build ;;
  down)    "${COMPOSE[@]}" down ;;
  logs)    "${COMPOSE[@]}" logs -f duckdb ;;
  refresh|export-sql|refresh-sql) "${COMPOSE[@]}" run --rm duckdb "$cmd" "$@" ;;
  shell|live) "${COMPOSE[@]}" run --rm -it duckdb "$cmd" "$@" ;;
  status)
    "${COMPOSE[@]}" run --rm duckdb shell -c "
      SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = 'reporting' ORDER BY 2, 1;
      SELECT refreshed_at, table_name, row_count, snapshot_id FROM reporting.refresh_log ORDER BY refreshed_at DESC LIMIT 10;" ;;
  *) sed -n '2,3p' "$0" ;;
esac
