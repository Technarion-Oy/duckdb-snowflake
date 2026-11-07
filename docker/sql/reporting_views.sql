-- Views created on top of the materialised Iceberg tables (schema "reporting").
-- Column names arrive in UPPER CASE from Snowflake. DuckDB keeps the source casing in
-- SELECT output unless aliased, so every column below is aliased explicitly to give
-- Power BI and pandas lower-case, friendly names.

-- Flat sales fact for Power BI: one row per order line with joined dimensions.
CREATE OR REPLACE VIEW reporting.v_sales AS
SELECT
    o.order_id                          AS order_id,
    o.order_date                        AS order_date,
    CAST(o.order_date AS DATE)          AS order_day,
    c.customer_id                       AS customer_id,
    c.name                              AS customer_name,
    c.region                            AS region,
    p.product_id                        AS product_id,
    p.product_name                      AS product_name,
    p.price                             AS unit_price,
    o.quantity                          AS quantity,
    o.quantity * p.price                AS revenue
FROM reporting.orders o
LEFT JOIN reporting.customers c ON c.customer_id = o.customer_id
LEFT JOIN reporting.products  p ON p.product_id  = o.product_id;

-- Calendar covering the order date range, for a proper date table in the model.
CREATE OR REPLACE VIEW reporting.dim_date AS
WITH bounds AS (
    SELECT CAST(min(order_date) AS DATE) AS d0, CAST(max(order_date) AS DATE) AS d1
    FROM reporting.orders
),
days AS (
    SELECT CAST(unnest(generate_series(d0, d1, INTERVAL 1 DAY)) AS DATE) AS d FROM bounds
)
SELECT
    d                                   AS date,
    year(d)                             AS year,
    quarter(d)                          AS quarter,
    month(d)                            AS month,
    monthname(d)                        AS month_name,
    strftime(d, '%Y-%m')                AS year_month,
    isodow(d)                           AS weekday,
    dayname(d)                          AS weekday_name,
    isodow(d) >= 6                      AS is_weekend
FROM days;

-- Pre-aggregated daily revenue per region (handy for a quick first visual).
CREATE OR REPLACE VIEW reporting.v_daily_revenue AS
SELECT
    order_day,
    region,
    count(*)        AS orders,
    sum(quantity)   AS units,
    sum(revenue)    AS revenue
FROM reporting.v_sales
GROUP BY order_day, region;
