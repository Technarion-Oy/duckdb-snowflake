# Snowflake Iceberg on S3 -> DuckDB -> Power BI

Report on three Snowflake-managed Apache Iceberg tables (`products`, `customers`, `orders`)
in Power BI, with DuckDB as the engine. DuckDB reads the Iceberg metadata and Parquet data
files **directly from the S3 external volume**. Snowflake is never queried, so no Snowflake
warehouse runs for reporting. Everything runs natively on the Windows machine that has
Power BI; Docker is only an option for a shared server.

```
 Snowflake writes Iceberg tables to the external volume
      |
      v
 s3://<bucket>/<prefix>/mock_data/{products,customers,orders}/{metadata,data}/
      |  iceberg_scan('s3://.../orders', version = '?')   (AWS read-only credentials)
      v
 DuckDB 2.0 (refresh\refresh.py, Windows Scheduled Task every REFRESH_INTERVAL_SECONDS)
      |  CREATE TABLE reporting.orders AS SELECT * FROM iceberg_scan(...)
      v
 data\warehouse.duckdb  +  data\parquet\*.parquet
      |  DuckDB ODBC driver / Power Query connector, or Parquet connector
      v
 Power BI Desktop
```

## Files

| Path | Purpose |
|------|---------|
| `create-snowflake-iceberg-tables.sql` | creates the three Iceberg tables with sample data (existing) |
| `snowflake/02-find-s3-locations.sql` | shows the bucket/prefix and current metadata file per table; optional task to keep metadata fresh |
| `aws/iam-read-policy.json`, `aws/README.md` | read-only S3 access for DuckDB |
| `.env.example` | S3 location + AWS settings -> copy to `.env` |
| `refresh/refresh.py` | scan Iceberg tables from S3, materialise, export Parquet, build views; `--export-sql` writes the same as a SQL script |
| `refresh/sql/reporting_views.sql` | `v_sales`, `dim_date`, `v_daily_revenue` for the report |
| `duck.ps1` | all commands: setup, refresh, Scheduled Task, status, shell, export-sql, notebook |
| `requirements.txt` | Python packages for `.venv` (DuckDB 2.0.0, Jupyter, pandas) |
| `powerbi/README.md` | driver install, connection, data model, DAX starters |
| `notebooks/explore.ipynb` | Jupyter notebook for local SQL / pandas analysis of `data\warehouse.duckdb` |
| `docker/` | optional image + compose for a shared Linux server (`docker/README.md`) |
| `data/` | output folder Power BI points at (git-ignored contents) |

## Quick start (Windows)

Requirements: Python 3.10+ and, for the Power BI side, the DuckDB ODBC driver 2.0.x
(see `powerbi\README.md`). Open PowerShell in the repo folder. If scripts are blocked once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

```powershell
# 1. Snowflake: run create-snowflake-iceberg-tables.sql, then snowflake\02-find-s3-locations.sql
#    to get the S3 root and to flush Iceberg metadata for the fresh tables.
# 2. AWS: give DuckDB read access to that prefix (aws\README.md). SSO: aws sso login --profile <name>

# 3. Install: .venv with DuckDB 2.0.0 + notebook packages, DuckDB CLI via winget (optional)
.\duck.ps1 setup

# 4. Configure
.\duck.ps1 init                     # creates .env
#    edit .env: ICEBERG_S3_ROOT, AWS_REGION, AWS_PROFILE (or static keys)

# 5. First sync
.\duck.ps1 refresh
.\duck.ps1 status                   # tables, row counts, snapshot ids, refresh log

# 6. Keep it fresh: Scheduled Task every REFRESH_INTERVAL_SECONDS (default 15 min)
.\duck.ps1 register-task

# 7. Power BI: see powerbi\README.md
.\duck.ps1 powerbi-path             # prints C:\...\data\warehouse.duckdb to paste into the connector

# 8. Optional: analyse locally in Jupyter
.\duck.ps1 notebook
```

Other handy commands:

```powershell
.\duck.ps1 shell                    # DuckDB CLI, read-only, on data\warehouse.duckdb
.\duck.ps1 live                     # DuckDB CLI with views products/customers/orders that
                                    # query S3 directly:  SELECT count(*) FROM orders;
.\duck.ps1 loop                     # foreground loop instead of the Scheduled Task
.\duck.ps1 unregister-task
```

The Scheduled Task runs as your user while you are logged in, so it can use your SSO profile.
For an always-on refresh on a server nobody logs into, use `docker\` with an instance role or
a dedicated read-only IAM user.

## Plain SQL variant

Everything the refresh job does is DuckDB SQL; Python only adds the loop, the atomic file
swap and logging. To see or run that SQL yourself:

```powershell
.\duck.ps1 export-sql       # writes data\refresh.sql with your .env values filled in
.\duck.ps1 refresh-sql      # regenerates it and runs it through the DuckDB CLI
```

`refresh.sql` contains `LOAD httpfs; LOAD iceberg;`, the `CREATE SECRET`, one
`CREATE OR REPLACE TABLE reporting.<t> AS SELECT * FROM iceberg_scan(...)` plus `COPY ... TO
parquet` and a `refresh_log` insert per table, the views from `refresh\sql\reporting_views.sql`,
and `CHECKPOINT`. Edit it freely and run it against any DuckDB 2.0 client:

```
duckdb data\warehouse.duckdb.tmp < data\refresh.sql
move /Y data\warehouse.duckdb.tmp data\warehouse.duckdb
```

Write to a scratch file as shown, never to a file Power BI has open. The file is
git-ignored because it can contain static AWS keys if you use those.

## Jupyter notebook

`notebooks\explore.ipynb` opens `data\warehouse.duckdb` read-only with the DuckDB Python
package, so it can run while a refresh happens. It lists tables and the refresh log, has
ad-hoc SQL cells, a few charts (revenue by region, monthly trend, product mix), pandas
hand-off, a CSV export, and an optional cell that queries the Iceberg tables on S3 directly
using the same settings as the refresh. Start it with `.\duck.ps1 notebook`.

## How DuckDB reads the Iceberg tables

`refresh.py` runs this (values from `.env`):

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
`snowflake\02-find-s3-locations.sql` has an optional task that calls it every 15 minutes
so DuckDB's view of the data never lags.

Each refresh writes to `warehouse.duckdb.tmp` and renames it over the live file, so Power BI
(which opens the file read-only) never sees a partial write. The previous good file stays in
place if a refresh fails.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `403 Forbidden` / `Access Denied` | IAM policy must allow `s3:ListBucket` on the bucket (prefix condition) and `s3:GetObject` on `<prefix>/*`. SSE-KMS buckets also need `kms:Decrypt`. SSO users: `aws sso login` again. |
| `No metadata file found` / version guessing fails | `ICEBERG_S3_ROOT` or table folder wrong. Compare with the `metadataLocation` from `snowflake\02-find-s3-locations.sql`. Table folders are lower case as in the DDL `BASE_LOCATION`. |
| Row counts behind Snowflake | Metadata not yet published. Call `SYSTEM$GET_ICEBERG_TABLE_INFORMATION('orders')` in Snowflake or enable the task. |
| `Unable to connect to ... amazonaws.com` / wrong region | Set `AWS_REGION` to the bucket's region. |
| Scheduled Task runs but nothing changes | Check `Get-ScheduledTaskInfo 'DuckDB Iceberg Refresh'` for the last result; run `.\duck.ps1 refresh` in a terminal to see the error. |
| Power BI cannot open the file | ODBC driver version must be 2.0.x to read a DuckDB 2.0 file. Close Power BI before deleting `data\`. |

## Versions

DuckDB 2.0.0 (Python package and CLI), DuckDB ODBC 2.0.0.1, DuckDB Power Query connector 0.2.0.
Pin a different DuckDB in `requirements.txt` (and `docker/docker-compose.yml`), and install the
matching ODBC driver on the Power BI side.
