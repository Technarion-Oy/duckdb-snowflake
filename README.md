# Snowflake Iceberg on S3 -> DuckDB (Docker) -> Power BI

Report on three Snowflake-managed Apache Iceberg tables (`products`, `customers`, `orders`)
in Power BI, with DuckDB as the engine. DuckDB reads the Iceberg metadata and Parquet data
files **directly from the S3 external volume**. Snowflake is never queried, so no Snowflake
warehouse runs for reporting.

```
 Snowflake writes Iceberg tables to the external volume
      |
      v
 s3://<bucket>/<prefix>/mock_data/{products,customers,orders}/{metadata,data}/
      |  iceberg_scan('s3://.../orders', version = '?')   (AWS read-only credentials)
      v
 DuckDB 2.0 in Docker  (docker/refresh.py, every REFRESH_INTERVAL_SECONDS)
      |  CREATE TABLE reporting.orders AS SELECT * FROM iceberg_scan(...)
      v
 ./data/warehouse.duckdb  +  ./data/parquet/*.parquet
      |  DuckDB ODBC driver / Power Query connector, or Parquet connector
      v
 Power BI Desktop (Windows / Windows VM)
```

## Files

| Path | Purpose |
|------|---------|
| `create-snowflake-iceberg-tables.sql` | creates the three Iceberg tables with sample data (existing) |
| `snowflake/02-find-s3-locations.sql` | shows the bucket/prefix and current metadata file per table; optional task to keep metadata fresh |
| `aws/iam-read-policy.json`, `aws/README.md` | read-only S3 access for DuckDB |
| `docker/Dockerfile` | DuckDB 2.0.0 (Python + CLI) with `httpfs` and `iceberg` pre-installed |
| `docker/docker-compose.yml` | the `duckdb` service; mounts `./data` and `~/.aws` (read-only) |
| `docker/.env.example` | S3 location + AWS settings -> copy to `docker/.env` |
| `docker/refresh.py` | scan Iceberg tables from S3, materialise, export Parquet, build views |
| `docker/sql/reporting_views.sql` | `v_sales`, `dim_date`, `v_daily_revenue` for the report |
| `docker/entrypoint.sh` | container modes: `refresh`, `loop`, `shell`, `live` |
| `duck.ps1` | one-command wrapper around docker compose for Windows PowerShell |
| `duck.sh` | same wrapper for macOS / Linux / WSL |
| `.gitattributes` | keeps container scripts on LF endings when cloned on Windows |
| `powerbi/README.md` | driver install, connection, data model, DAX starters |
| `notebooks/explore.ipynb` | Jupyter notebook for local SQL / pandas analysis of `data/warehouse.duckdb` |
| `data/` | output folder Power BI points at (git-ignored contents) |

## Quick start (Windows, Docker Desktop already installed)

Open PowerShell in the repo folder. If scripts are blocked once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

```powershell
# 1. Snowflake: run create-snowflake-iceberg-tables.sql, then snowflake\02-find-s3-locations.sql
#    to get the S3 root and to flush Iceberg metadata for the fresh tables.
# 2. AWS: give DuckDB read access to that prefix (aws\README.md).

# 3. Configure
.\duck.ps1 init                     # creates docker\.env
#    edit docker\.env: ICEBERG_S3_ROOT, AWS_REGION, AWS_PROFILE + AWS_DIR (or static keys)

# 4. First sync (builds the image on first run, ~1-2 min)
.\duck.ps1 refresh
.\duck.ps1 status                   # tables, row counts, snapshot ids, refresh log

# 5. Keep it fresh in the background (default every 15 min, survives reboots via restart policy)
.\duck.ps1 up
.\duck.ps1 logs

# 6. Power BI (same machine): see powerbi\README.md
.\duck.ps1 powerbi-path             # prints C:\...\data\warehouse.duckdb to paste into the connector

# 7. Optional: analyse locally in Jupyter (creates notebooks\.venv on first run)
.\duck.ps1 notebook
```

Other handy commands:

```powershell
.\duck.ps1 shell                    # DuckDB CLI, read-only, on data\warehouse.duckdb
.\duck.ps1 live                     # DuckDB CLI with views products/customers/orders that
                                    # query S3 directly:  SELECT count(*) FROM orders;
.\duck.ps1 down
```

On macOS / Linux / WSL the same commands exist as `./duck.sh <command>`.

## Jupyter notebook

`notebooks/explore.ipynb` opens `data/warehouse.duckdb` read-only with the DuckDB Python
package, so it can run while the container keeps refreshing. It lists tables and the refresh
log, has ad-hoc SQL cells, a few charts (revenue by region, monthly trend, product mix),
pandas hand-off, a CSV export, and an optional cell that queries the Iceberg tables on S3
directly using the same settings as the container. Start it with `./duck.sh notebook`, or
point any Python 3.10+ with `pip install -r notebooks/requirements.txt` at it.

## How DuckDB reads the Iceberg tables

`refresh.py` runs this (values from `docker/.env`):

```sql
LOAD httpfs; LOAD iceberg;
SET unsafe_enable_version_guessing = true;        -- Snowflake writes no version-hint.text

CREATE OR REPLACE SECRET s3_iceberg (
    TYPE s3,
    PROVIDER credential_chain,                    -- or KEY_ID / SECRET / SESSION_TOKEN
    PROFILE 'duckdb-reader',
    REGION 'eu-west-1'
);

CREATE OR REPLACE TABLE reporting.orders AS
SELECT * FROM iceberg_scan('s3://my-bucket/snowflake/mock_data/orders', version = '?');
```

`version = '?'` makes DuckDB list `metadata/` and take the lexicographically largest
`*.metadata.json`. Snowflake names them `00001-<uuid>.metadata.json`, `00002-...`, so the
largest is the newest. To pin an exact file instead, set
`ICEBERG_PATH_ORDERS=s3://.../orders/metadata/00007-....metadata.json`.

Snowflake-managed tables publish Iceberg metadata to S3 shortly after DML, or immediately
when `SYSTEM$GET_ICEBERG_TABLE_INFORMATION` is called. Step 3 in
`snowflake/02-find-s3-locations.sql` has an optional task that calls it every 15 minutes
so DuckDB's view of the data never lags.

Each refresh writes to `warehouse.duckdb.tmp` and renames it over the live file, so Power BI
(which opens the file read-only) never sees a partial write. The previous good file stays in
place if a refresh fails.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `403 Forbidden` / `Access Denied` | IAM policy must allow `s3:ListBucket` on the bucket (prefix condition) and `s3:GetObject` on `<prefix>/*`. SSE-KMS buckets also need `kms:Decrypt`. |
| `No metadata file found` / version guessing fails | `ICEBERG_S3_ROOT` or table folder wrong. Compare with the `metadataLocation` from `snowflake/02-find-s3-locations.sql`. Table folders are lower case as in the DDL `BASE_LOCATION`. |
| Row counts behind Snowflake | Metadata not yet published. Call `SYSTEM$GET_ICEBERG_TABLE_INFORMATION('orders')` in Snowflake or enable the task. |
| `Unable to connect to ... amazonaws.com` / wrong region | Set `AWS_REGION` to the bucket's region. |
| `credential_chain` finds nothing | `~/.aws` not mounted or profile missing. Set `AWS_PROFILE`, or use static keys in `docker/.env`. SSO profiles need `aws sso login` on the host first. |
| Power BI cannot open the file | ODBC driver version must be 2.0.x to read a DuckDB 2.0 file. Close Power BI before deleting `data/`. |

## Versions

DuckDB 2.0.0 (image, Python package, CLI), DuckDB ODBC 2.0.0.1, DuckDB Power Query connector 0.2.0.
Pin a different DuckDB with `DUCKDB_VERSION` in `docker/docker-compose.yml`, and install the
matching ODBC driver on the Power BI side.
