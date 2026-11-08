#!/bin/sh
# Container entrypoint (shared-server deployment). Modes:
#   refresh  - read the Iceberg tables from S3 once, write /data/warehouse.duckdb + Parquet, exit
#   loop     - same, repeated every REFRESH_INTERVAL_SECONDS (default 900)
#   shell    - open the DuckDB CLI read-only on the reporting file
#   live     - open the DuckDB CLI with views that query the S3 Iceberg tables directly (no local copy)
#   export-sql [PATH] - write one full refresh as a plain SQL script (default /data/refresh.sql)
#   refresh-sql       - generate that script and run it with the DuckDB CLI (same result as 'refresh')
#   anything else is executed as a command
set -e

case "${1:-loop}" in
  refresh)
    exec python /app/refresh.py --once
    ;;
  loop)
    exec python /app/refresh.py
    ;;
  shell)
    shift
    exec duckdb -readonly "${DUCKDB_PATH:-/data/warehouse.duckdb}" "$@"
    ;;
  live)
    shift
    python /app/refresh.py --print-sql > /tmp/live.sql
    exec duckdb -init /tmp/live.sql "$@"
    ;;
  export-sql)
    shift
    exec python /app/refresh.py --export-sql "${1:-/data/refresh.sql}"
    ;;
  refresh-sql)
    db="${DUCKDB_PATH:-/data/warehouse.duckdb}"
    python /app/refresh.py --export-sql /tmp/refresh.sql
    rm -f "$db.tmp" "$db.tmp.wal"
    duckdb "$db.tmp" < /tmp/refresh.sql
    mv -f "$db.tmp" "$db"
    echo "refresh-sql complete -> $db"
    ;;
  *)
    exec "$@"
    ;;
esac
