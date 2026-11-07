-- Snowflake side: find where the Iceberg files live so DuckDB can read them from S3.
-- Nothing here grants DuckDB access to Snowflake; DuckDB only needs AWS read access
-- to the bucket (see aws/iam-read-policy.json).

-- 1. Bucket + prefix of the external volume used in create-snowflake-iceberg-tables.sql.
--    In STORAGE_LOCATION_1 look at STORAGE_BASE_URL, e.g. s3://my-bucket/snowflake/
--    ICEBERG_S3_ROOT (docker/.env) = STORAGE_BASE_URL + 'mock_data'
DESCRIBE EXTERNAL VOLUME your_external_volume_name;

-- 2. Current metadata file per table (this is what DuckDB resolves with version = '?').
--    For Snowflake-managed tables this call also flushes any pending DML into new
--    Iceberg metadata on S3, so run it after loading data and before the first DuckDB read.
SELECT 'products'  AS tbl, PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('products'))['metadataLocation']::VARCHAR  AS metadata_location
UNION ALL
SELECT 'customers', PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('customers'))['metadataLocation']::VARCHAR
UNION ALL
SELECT 'orders',    PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('orders'))['metadataLocation']::VARCHAR;
-- Expect: s3://my-bucket/snowflake/mock_data/orders/metadata/00003-<uuid>.metadata.json
--          \_________ ICEBERG_S3_ROOT _________/ \_table_/

-- 3. Optional: have Snowflake refresh Iceberg metadata on a schedule so DuckDB always sees
--    recent DML without anyone calling the function manually (needs a warehouse).
-- CREATE OR REPLACE TASK refresh_iceberg_metadata
--   WAREHOUSE = COMPUTE_WH
--   SCHEDULE  = '15 MINUTE'
-- AS
--   SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('orders'),
--          SYSTEM$GET_ICEBERG_TABLE_INFORMATION('customers'),
--          SYSTEM$GET_ICEBERG_TABLE_INFORMATION('products');
-- ALTER TASK refresh_iceberg_metadata RESUME;

-- 4. Sanity: table list and row counts to compare against ./duck.sh status
SHOW ICEBERG TABLES;
SELECT 'products' t, count(*) n FROM products
UNION ALL SELECT 'customers', count(*) FROM customers
UNION ALL SELECT 'orders',    count(*) FROM orders;
