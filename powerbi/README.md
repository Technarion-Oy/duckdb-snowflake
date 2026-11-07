# Power BI on top of DuckDB

The container writes everything Power BI needs into the repo's `data\` folder on the same
Windows machine:

| File | What it is | How Power BI reads it |
|------|------------|-----------------------|
| `data/warehouse.duckdb` | DuckDB 2.0 database with schema `reporting` (tables `products`, `customers`, `orders`, views `v_sales`, `dim_date`, `v_daily_revenue`, `refresh_log`) | DuckDB Power Query connector (recommended) or plain ODBC |
| `data/parquet/*.parquet` | one Parquet file per table | built-in Parquet connector, no driver needed |

`.\duck.ps1 powerbi-path` prints the full path, e.g. `C:\Users\kalle\duckdb-snowflake\data\warehouse.duckdb`.

## Option A: DuckDB Power Query connector (recommended)

Versions must match the DuckDB that wrote the file. The container uses DuckDB **2.0.0**.

1. Install the DuckDB ODBC driver 2.0.0.1 for Windows:
   https://github.com/duckdb/duckdb-odbc/releases/download/v2.0.0.1/duckdb_odbc-windows-amd64.zip
   (ARM Windows: `duckdb_odbc-windows-arm64.zip`). Unzip and run the installer.
   Check: `ODBC Data Sources (64-bit)` -> Drivers tab shows `DuckDB Driver` 2.0.0.1.
2. Download the connector (v0.2.0):
   https://github.com/motherduckdb/duckdb-power-query-connector/releases/download/v0.2.0/duckdb-power-query-connector.mez
   Copy it to `%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors\` (create the folder;
   if Documents is redirected to OneDrive, use that Documents folder).
3. Power BI Desktop -> File -> Options -> Security -> Data Extensions ->
   "(Not Recommended) Allow any extension to load without validation" -> restart Power BI.
4. Get Data -> search **DuckDB** -> Database: the path from `.\duck.ps1 powerbi-path`.
   Leave the MotherDuck token empty. Connection mode: **Import**.
5. In Navigator expand `reporting` and tick `products`, `customers`, `orders`, `dim_date`
   (or just `v_sales` for a single flat table).

The connector opens the file read-only, so the container can keep refreshing in the
background. The refresh job writes to a temp file and swaps it in atomically, so Power BI
never sees a half-written database. Press **Refresh** in Power BI to pick up new data.

## Option B: plain ODBC (no custom connector)

Get Data -> ODBC -> Advanced options -> connection string:

```
Driver={DuckDB Driver};Database=C:\path\to\data\warehouse.duckdb;access_mode=read_only
```

Known limitation: the DuckDB ODBC driver is not UTF-8 aware in Power BI; non-ASCII text may
render wrong. Option A or C avoids that.

## Option C: Parquet files (zero drivers)

Get Data -> Folder -> `data\parquet` -> Combine, or Get Data -> Parquet per file.
Same data, same refresh cadence. Use this when installing drivers is not possible or when
the report runs in the Power BI Service without a gateway (upload the folder to OneDrive /
SharePoint and use the SharePoint folder connector).

## Model

Star schema, all relationships single-direction, many-to-one:

```
orders.customer_id  (many) -> (one) customers.customer_id
orders.product_id   (many) -> (one) products.product_id
orders.order_day    (many) -> (one) dim_date.date      (mark dim_date as Date table)
```

`orders` comes from the Iceberg table as-is (no `order_day` column), so either add a
calculated column `order_day = DATEVALUE(orders[ORDER_DATE])` or load `v_sales` instead,
which already has `order_day`, `revenue`, and the joined dimension columns.

Column names arrive in UPPER CASE from Snowflake (`ORDER_ID`, `CUSTOMER_ID`, ...) in the raw
tables; the views use lower-case friendly names.

Starter measures:

```dax
Revenue       = SUM ( v_sales[revenue] )
Orders        = DISTINCTCOUNT ( v_sales[order_id] )
Units         = SUM ( v_sales[quantity] )
Avg Order     = DIVIDE ( [Revenue], [Orders] )
Last Refresh  = MAX ( refresh_log[refreshed_at] )
```

## Scheduled refresh in the Power BI Service

A `.duckdb` file is a local file, so the Service needs an **on-premises data gateway** on a
Windows box that has the ODBC driver + connector installed and can reach `data/`.
The Parquet-on-SharePoint route (Option C) needs no gateway.
