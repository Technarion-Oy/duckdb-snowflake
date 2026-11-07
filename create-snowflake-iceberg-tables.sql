-- 1. Create the Iceberg Products table (Static lookup data)
CREATE OR REPLACE ICEBERG TABLE products (
    product_id INT,
    product_name VARCHAR,
    price NUMBER(10,2)
)
CATALOG = 'SNOWFLAKE'
EXTERNAL_VOLUME = 'your_external_volume_name' -- REPLACE WITH YOUR EXTERNAL VOLUME
BASE_LOCATION = 'mock_data/products/';

INSERT INTO products VALUES
    (1, 'Laptop', 1299.99),
    (2, 'Wireless Mouse', 45.00),
    (3, 'Keyboard', 85.50),
    (4, 'Monitor', 350.00),
    (5, 'Office Chair', 200.00);

-- 2. Generate 100 Customers into an Iceberg table
CREATE OR REPLACE ICEBERG TABLE customers
CATALOG = 'SNOWFLAKE'
EXTERNAL_VOLUME = 'your_external_volume_name' -- REPLACE WITH YOUR EXTERNAL VOLUME
BASE_LOCATION = 'mock_data/customers/'
AS
SELECT
    SEQ4() + 1 AS customer_id,
    'Customer_' || (SEQ4() + 1)::VARCHAR AS name,
    DECODE(ABS(RANDOM()) % 4, 0, 'North', 1, 'South', 2, 'East', 3, 'West') AS region
FROM TABLE(GENERATOR(ROWCOUNT => 100));

-- 3. Generate 1,000 Orders into an Iceberg table
CREATE OR REPLACE ICEBERG TABLE orders
CATALOG = 'SNOWFLAKE'
EXTERNAL_VOLUME = 'your_external_volume_name' -- REPLACE WITH YOUR EXTERNAL VOLUME
BASE_LOCATION = 'mock_data/orders/'
AS
SELECT
    SEQ8() + 1 AS order_id,
    UNIFORM(1, 100, RANDOM()) AS customer_id, 
    UNIFORM(1, 5, RANDOM()) AS product_id,    
    UNIFORM(1, 5, RANDOM()) AS quantity,      
    DATEADD(hour, -UNIFORM(1, 8760, RANDOM()), CURRENT_TIMESTAMP()) AS order_date
FROM TABLE(GENERATOR(ROWCOUNT => 1000));