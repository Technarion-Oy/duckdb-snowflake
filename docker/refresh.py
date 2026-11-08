#!/usr/bin/env python3
"""
Read Snowflake-managed Apache Iceberg tables straight from S3 with DuckDB and
materialise them into a local DuckDB file (+ Parquet) for Power BI.

Snowflake is NOT contacted. DuckDB's iceberg extension reads the table's
metadata/*.metadata.json, manifests and Parquet data files directly from the
external volume bucket using your AWS credentials.

Flow per refresh:
  1. Open a scratch DuckDB file next to the target.
  2. CREATE SECRET (TYPE s3) from the AWS credential chain or explicit keys.
  3. For every table in ICEBERG_TABLES:
       CREATE TABLE reporting.<table> AS
       SELECT * FROM iceberg_scan('s3://<root>/<table>', version = '?')
     and export the same rows to Parquet.
  4. Create the reporting views (sql/reporting_views.sql) and a refresh log.
  5. Atomically swap the scratch file over DUCKDB_PATH.

Power BI opens DUCKDB_PATH read-only (DuckDB ODBC driver / Power Query connector)
or reads the Parquet folder directly.

`refresh.py --export-sql refresh.sql` writes the same refresh as a plain SQL script that
can be run with the DuckDB CLI instead of this program (see export_sql()).
"""
from __future__ import annotations

import argparse
import datetime as dt
import logging
import os
import re
import sys
import time

import duckdb

log = logging.getLogger("refresh")


# ----------------------------------------------------------------------------- config
def env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        log.error("Environment variable %s is required (see docker/.env.example)", name)
        sys.exit(2)
    return value or ""


def env_bool(name: str, default: bool) -> bool:
    return env(name, "true" if default else "false").strip().lower() in ("1", "true", "yes", "on")


def sql_str(value: str) -> str:
    """Escape a value for use inside a single-quoted SQL literal."""
    return value.replace("'", "''")


def ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


class Config:
    def __init__(self) -> None:
        # Where Snowflake wrote the tables: external volume STORAGE_BASE_URL + parent of BASE_LOCATION.
        # DDL uses BASE_LOCATION = 'mock_data/<table>/'  ->  ICEBERG_S3_ROOT = s3://<bucket>/<prefix>/mock_data
        self.s3_root = env("ICEBERG_S3_ROOT", required=True).rstrip("/")
        self.tables = [t.strip().lower() for t in env("ICEBERG_TABLES", "products,customers,orders").split(",") if t.strip()]
        self.version_guessing = env_bool("ICEBERG_VERSION_GUESSING", True)
        self.allow_moved_paths = env_bool("ICEBERG_ALLOW_MOVED_PATHS", False)

        # AWS
        self.aws_key = env("AWS_ACCESS_KEY_ID")
        self.aws_secret = env("AWS_SECRET_ACCESS_KEY")
        self.aws_token = env("AWS_SESSION_TOKEN")
        self.aws_region = env("AWS_REGION") or env("AWS_DEFAULT_REGION")
        self.aws_profile = env("AWS_PROFILE")
        self.s3_endpoint = env("S3_ENDPOINT")          # only for S3-compatible stores (MinIO, R2, ...)
        self.s3_url_style = env("S3_URL_STYLE")        # 'path' for most S3-compatible stores
        self.s3_use_ssl = env_bool("S3_USE_SSL", True)

        # Output
        self.duckdb_path = env("DUCKDB_PATH", "/data/warehouse.duckdb")
        self.parquet_dir = env("PARQUET_DIR", "/data/parquet")
        self.interval = int(env("REFRESH_INTERVAL_SECONDS", "900") or "0")
        self.views_sql = env("VIEWS_SQL", os.path.join(os.path.dirname(__file__), "sql", "reporting_views.sql"))

        if not self.s3_root.startswith(("s3://", "s3a://", "gs://", "az://", "abfss://", "r2://")):
            log.warning("ICEBERG_S3_ROOT %r is not an object-store URL; treating it as a local path (test mode)", self.s3_root)

    def table_location(self, table: str) -> str:
        """Table folder (or explicit *.metadata.json) for one table. Override per table with ICEBERG_PATH_<TABLE>."""
        override = os.environ.get(f"ICEBERG_PATH_{table.upper()}")
        return override.rstrip("/") if override and not override.endswith(".metadata.json") else (override or f"{self.s3_root}/{table}")


# ----------------------------------------------------------------------------- S3 access
def s3_secret_sql(cfg: Config) -> str:
    """Build the S3 secret that tells DuckDB how to sign requests to the bucket.

    Default (AWS_PROFILE / SSO / env vars / instance role via the AWS credential chain):

        CREATE OR REPLACE SECRET s3_iceberg (
            TYPE s3,
            PROVIDER credential_chain,
            PROFILE 'duckdb-reader',          -- only if AWS_PROFILE is set
            REGION 'eu-west-1'
        );

    With static keys (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in .env):

        CREATE OR REPLACE SECRET s3_iceberg (
            TYPE s3,
            KEY_ID 'AKIA...',
            SECRET '...',
            SESSION_TOKEN '...',              -- only if AWS_SESSION_TOKEN is set
            REGION 'eu-west-1'
        );

    S3-compatible stores (S3_ENDPOINT set) additionally get ENDPOINT, URL_STYLE and USE_SSL.
    The secret is temporary: it lives in this connection only and is never written to the
    warehouse file.
    """
    opts = ["TYPE s3"]
    if cfg.aws_key and cfg.aws_secret:
        opts += [f"KEY_ID '{sql_str(cfg.aws_key)}'", f"SECRET '{sql_str(cfg.aws_secret)}'"]
        if cfg.aws_token:
            opts.append(f"SESSION_TOKEN '{sql_str(cfg.aws_token)}'")
    else:
        # env vars, ~/.aws/credentials + config (incl. SSO cache), instance / task role, ...
        opts.append("PROVIDER credential_chain")
        if cfg.aws_profile:
            opts.append(f"PROFILE '{sql_str(cfg.aws_profile)}'")
    if cfg.aws_region:
        opts.append(f"REGION '{sql_str(cfg.aws_region)}'")
    if cfg.s3_endpoint:
        opts.append(f"ENDPOINT '{sql_str(cfg.s3_endpoint)}'")
        opts.append(f"URL_STYLE '{sql_str(cfg.s3_url_style or 'path')}'")
        opts.append(f"USE_SSL {'true' if cfg.s3_use_ssl else 'false'}")
    elif cfg.s3_url_style:
        opts.append(f"URL_STYLE '{sql_str(cfg.s3_url_style)}'")
    return "CREATE OR REPLACE SECRET s3_iceberg (\n    " + ",\n    ".join(opts) + "\n);"


def scan_sql(cfg: Config, location: str) -> str:
    """Build the table function that reads one Iceberg table from S3.

    Table folder (the normal case; DuckDB lists <folder>/metadata/ and picks the
    lexicographically newest *.metadata.json, which for Snowflake is the latest commit):

        iceberg_scan('s3://my-bucket/snowflake/mock_data/orders', version = '?')

    With ICEBERG_ALLOW_MOVED_PATHS=true (table folder was copied elsewhere):

        iceberg_scan('s3://.../orders', version = '?', allow_moved_paths = true)

    Pinned metadata file (ICEBERG_PATH_<TABLE> points at a *.metadata.json):

        iceberg_scan('s3://.../orders/metadata/00007-1f2e....metadata.json')

    The result is used as a FROM clause, e.g. SELECT * FROM iceberg_scan(...).
    """
    if location.endswith(".metadata.json"):
        return f"iceberg_scan('{sql_str(location)}')"
    params = []
    if cfg.version_guessing:
        # Snowflake writes no version-hint.text; its metadata files are named
        # 0000N-<uuid>.metadata.json, so the lexicographically largest one is the newest.
        params.append("version = '?'")
    if cfg.allow_moved_paths:
        params.append("allow_moved_paths = true")
    return f"iceberg_scan('{sql_str(location)}'" + (", " + ", ".join(params) if params else "") + ")"


def snapshots_sql(cfg: Config, location: str) -> str:
    """Build the snapshot listing for one table (same path/version rules as scan_sql):

        SELECT snapshot_id, timestamp_ms, sequence_number
        FROM iceberg_snapshots('s3://.../orders', version = '?')
    """
    fn = scan_sql(cfg, location).replace("iceberg_scan(", "iceberg_snapshots(", 1).replace(", allow_moved_paths = true", "")
    return f"SELECT snapshot_id, timestamp_ms, sequence_number FROM {fn}"


REFRESH_LOG_DDL = """CREATE TABLE IF NOT EXISTS reporting.refresh_log (
    refreshed_at TIMESTAMP, table_name VARCHAR, source VARCHAR,
    snapshot_id BIGINT, snapshot_ts VARCHAR, row_count BIGINT, seconds DOUBLE
)"""


def setup_connection(con: duckdb.DuckDBPyConnection, cfg: Config) -> None:
    """Prepare a connection for reading Iceberg from S3. Runs, in order:

        LOAD httpfs;                                   -- s3:// file system
        LOAD iceberg;                                  -- iceberg_scan / iceberg_snapshots
        SET unsafe_enable_version_guessing = true;     -- allows version = '?' (no version-hint.text)
        CREATE OR REPLACE SECRET s3_iceberg ( ... );   -- see s3_secret_sql()
    """
    con.execute("LOAD httpfs; LOAD iceberg;")
    if cfg.version_guessing:
        con.execute("SET unsafe_enable_version_guessing = true")
    con.execute(s3_secret_sql(cfg))
    log.info("S3 secret created (%s)", "static keys" if cfg.aws_key else f"credential chain{' profile ' + cfg.aws_profile if cfg.aws_profile else ''}")


def latest_snapshot(con: duckdb.DuckDBPyConnection, cfg: Config, location: str) -> tuple[int | None, str | None]:
    """Look up which Iceberg snapshot was just read, for the refresh log. Runs:

        SELECT snapshot_id, timestamp_ms
        FROM iceberg_snapshots('s3://.../orders', version = '?')
        ORDER BY sequence_number DESC
        LIMIT 1;

    Informational only; a failure here does not fail the refresh.
    """
    try:
        row = con.execute(f"{snapshots_sql(cfg, location)} ORDER BY sequence_number DESC LIMIT 1").fetchone()
        return (int(row[0]), str(row[1])) if row else (None, None)
    except Exception as e:  # informational only
        log.debug("snapshot lookup failed for %s: %s", location, e)
        return (None, None)


# ----------------------------------------------------------------------------- refresh
def run_sql_file(con: duckdb.DuckDBPyConnection, path: str) -> None:
    """Execute every statement in a .sql file (used for sql/reporting_views.sql), i.e.

        CREATE OR REPLACE VIEW reporting.v_sales AS ...;
        CREATE OR REPLACE VIEW reporting.dim_date AS ...;
        CREATE OR REPLACE VIEW reporting.v_daily_revenue AS ...;

    Line comments are stripped and the file is split on ';'.
    """
    if not os.path.exists(path):
        log.warning("Views file %s not found, skipping", path)
        return
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"--[^\n]*", "", text)
    for stmt in (s.strip() for s in text.split(";")):
        if stmt:
            con.execute(stmt)
    log.info("Applied %s", path)


def refresh_once(cfg: Config) -> None:
    """One full refresh of the warehouse file. Against a scratch copy (<DUCKDB_PATH>.tmp):

        -- setup_connection(): LOAD httpfs; LOAD iceberg; SET ...; CREATE SECRET ...;
        CREATE SCHEMA IF NOT EXISTS reporting;
        CREATE TABLE IF NOT EXISTS reporting.refresh_log (
            refreshed_at TIMESTAMP, table_name VARCHAR, source VARCHAR,
            snapshot_id BIGINT, snapshot_ts VARCHAR, row_count BIGINT, seconds DOUBLE);

        -- per table in ICEBERG_TABLES (products, customers, orders):
        CREATE OR REPLACE TABLE reporting."orders" AS
            SELECT * FROM iceberg_scan('s3://.../orders', version = '?');
        SELECT count(*) FROM reporting."orders";
        COPY reporting."orders" TO '/data/parquet/orders.parquet.tmp' (FORMAT parquet, COMPRESSION zstd);
        INSERT INTO reporting.refresh_log VALUES (now(), 'orders', 's3://.../orders', <snapshot_id>, <snapshot_ts>, <rows>, <seconds>);

        -- run_sql_file(): CREATE OR REPLACE VIEW reporting.v_sales / dim_date / v_daily_revenue ...;
        CHECKPOINT;

    Then the scratch file is renamed over DUCKDB_PATH and each Parquet .tmp over its final
    name, so Power BI (which opens the file read-only) never sees a half-written database.
    If anything fails, the previous warehouse file is left untouched.
    """
    started = time.time()
    os.makedirs(os.path.dirname(cfg.duckdb_path), exist_ok=True)
    os.makedirs(cfg.parquet_dir, exist_ok=True)

    tmp_db = cfg.duckdb_path + ".tmp"
    for leftover in (tmp_db, tmp_db + ".wal"):
        if os.path.exists(leftover):
            os.remove(leftover)

    con = duckdb.connect(tmp_db)
    try:
        setup_connection(con, cfg)
        con.execute("CREATE SCHEMA IF NOT EXISTS reporting")
        con.execute(REFRESH_LOG_DDL)

        for table in cfg.tables:
            t0 = time.time()
            location = cfg.table_location(table)
            target = f"reporting.{ident(table)}"
            con.execute(f"CREATE OR REPLACE TABLE {target} AS SELECT * FROM {scan_sql(cfg, location)}")
            rows = con.execute(f"SELECT count(*) FROM {target}").fetchone()[0]
            snap_id, snap_ts = latest_snapshot(con, cfg, location)

            parquet_tmp = os.path.join(cfg.parquet_dir, f"{table}.parquet.tmp")
            parquet_final = os.path.join(cfg.parquet_dir, f"{table}.parquet")
            con.execute(f"COPY {target} TO '{sql_str(parquet_tmp)}' (FORMAT parquet, COMPRESSION zstd)")
            os.replace(parquet_tmp, parquet_final)

            secs = time.time() - t0
            con.execute(
                "INSERT INTO reporting.refresh_log VALUES (now(), ?, ?, ?, ?, ?, ?)",
                [table, location, snap_id, snap_ts, rows, round(secs, 2)],
            )
            log.info("%-12s %8d rows  %.1fs  snapshot=%s  <- %s", table, rows, secs, snap_id, location)

        run_sql_file(con, cfg.views_sql)
        con.execute("CHECKPOINT")
    finally:
        con.close()

    os.replace(tmp_db, cfg.duckdb_path)
    log.info("Refresh complete in %.1fs -> %s", time.time() - started, cfg.duckdb_path)


def export_sql(cfg: Config) -> str:
    """Render one complete refresh as a plain SQL script for the DuckDB CLI.

    Same statements as refresh_once(), minus the Python-only parts (temp-file swap, retries,
    timing). The row count and snapshot id for the log are computed in SQL instead:

        LOAD httpfs; LOAD iceberg;
        SET unsafe_enable_version_guessing = true;
        CREATE OR REPLACE SECRET s3_iceberg ( ... );
        CREATE SCHEMA IF NOT EXISTS reporting;
        CREATE TABLE IF NOT EXISTS reporting.refresh_log ( ... );

        CREATE OR REPLACE TABLE reporting."orders" AS
        SELECT * FROM iceberg_scan('s3://.../orders', version = '?');
        COPY reporting."orders" TO '/data/parquet/orders.parquet' (FORMAT parquet, COMPRESSION zstd);
        INSERT INTO reporting.refresh_log
        SELECT now(), 'orders', 's3://.../orders', s.snapshot_id, CAST(s.timestamp_ms AS VARCHAR),
               (SELECT count(*) FROM reporting."orders"), NULL
        FROM (SELECT ... FROM iceberg_snapshots('s3://.../orders', version = '?')
              ORDER BY sequence_number DESC LIMIT 1) s;
        -- ... same for every table in ICEBERG_TABLES ...

        -- contents of sql/reporting_views.sql
        CHECKPOINT;

    Run it with:  duckdb <DUCKDB_PATH>.tmp < refresh.sql && mv <DUCKDB_PATH>.tmp <DUCKDB_PATH>
    (that is what the container's 'refresh-sql' mode does).
    """
    out: list[str] = [
        f"-- Generated by refresh.py --export-sql at {dt.datetime.now():%Y-%m-%d %H:%M:%S}",
        "-- One full refresh of the Power BI warehouse as plain DuckDB SQL.",
        f"-- Run:  duckdb {cfg.duckdb_path}.tmp < refresh.sql && mv {cfg.duckdb_path}.tmp {cfg.duckdb_path}",
        "-- Write to a scratch file as above, never to a file Power BI currently has open.",
    ]
    if cfg.aws_key:
        out.append("-- WARNING: contains static AWS keys. Keep this file out of git and chat.")
    out += [
        "",
        "LOAD httpfs;",
        "LOAD iceberg;",
    ]
    if cfg.version_guessing:
        out.append("SET unsafe_enable_version_guessing = true;")
    out += ["", s3_secret_sql(cfg), "", "CREATE SCHEMA IF NOT EXISTS reporting;", REFRESH_LOG_DDL + ";", ""]

    for table in cfg.tables:
        location = cfg.table_location(table)
        target = f"reporting.{ident(table)}"
        parquet = f"{cfg.parquet_dir}/{table}.parquet"
        out += [
            f"-- {table}  <-  {location}",
            f"CREATE OR REPLACE TABLE {target} AS",
            f"SELECT * FROM {scan_sql(cfg, location)};",
            f"COPY {target} TO '{sql_str(parquet)}' (FORMAT parquet, COMPRESSION zstd);",
            "INSERT INTO reporting.refresh_log",
            f"SELECT now(), '{sql_str(table)}', '{sql_str(location)}', s.snapshot_id, CAST(s.timestamp_ms AS VARCHAR),",
            f"       (SELECT count(*) FROM {target}), NULL",
            f"FROM ({snapshots_sql(cfg, location)} ORDER BY sequence_number DESC LIMIT 1) s;",
            "",
        ]

    if os.path.exists(cfg.views_sql):
        out += [f"-- {os.path.basename(cfg.views_sql)}", open(cfg.views_sql, encoding="utf-8").read().rstrip(), ""]
    out += ["CHECKPOINT;", ""]
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--once", action="store_true", help="refresh once and exit (ignore REFRESH_INTERVAL_SECONDS)")
    parser.add_argument("--print-sql", action="store_true", help="print the secret + iceberg_scan SQL and exit (used by 'live' mode)")
    parser.add_argument("--export-sql", nargs="?", const="-", metavar="PATH",
                        help="write one full refresh as a plain SQL script for the DuckDB CLI to PATH ('-' or no value = stdout) and exit")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    cfg = Config()

    if args.export_sql:
        script = export_sql(cfg)
        if args.export_sql == "-":
            sys.stdout.write(script)
        else:
            os.makedirs(os.path.dirname(os.path.abspath(args.export_sql)), exist_ok=True)
            with open(args.export_sql, "w", encoding="utf-8") as f:
                f.write(script)
            log.info("Wrote %s (%d lines)", args.export_sql, script.count("\n"))
        return 0

    if args.print_sql:
        print("LOAD httpfs; LOAD iceberg;")
        if cfg.version_guessing:
            print("SET unsafe_enable_version_guessing = true;")
        print(s3_secret_sql(cfg))
        for table in cfg.tables:
            print(f"CREATE OR REPLACE VIEW {ident(table)} AS SELECT * FROM {scan_sql(cfg, cfg.table_location(table))};")
        print(".print 'Live views over S3 Iceberg: " + ", ".join(cfg.tables) + "   e.g.  SELECT count(*) FROM orders;'")
        return 0

    if args.once or cfg.interval <= 0:
        refresh_once(cfg)
        return 0

    log.info("Loop mode: refreshing every %ds", cfg.interval)
    while True:
        try:
            refresh_once(cfg)
        except Exception:  # keep the loop alive; the previous good file stays in place
            log.exception("Refresh failed; will retry in %ds", cfg.interval)
        time.sleep(cfg.interval)


if __name__ == "__main__":
    sys.exit(main())
