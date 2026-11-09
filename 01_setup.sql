\set ON_ERROR_STOP on
SELECT 'CREATE DATABASE sales_marketing'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'sales_marketing')
\gexec
\connect sales_marketing

BEGIN;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dds;
CREATE SCHEMA IF NOT EXISTS cdm;

CREATE TABLE IF NOT EXISTS stg.customers (
    customer_id integer PRIMARY KEY,
    customer_name text NOT NULL,
    signup_dt date NOT NULL,
    region text NOT NULL,
    customer_segment text NOT NULL
) DISTRIBUTED BY (customer_id);

CREATE TABLE IF NOT EXISTS stg.channels (
    channel_id integer PRIMARY KEY,
    channel_name text NOT NULL,
    channel_type text NOT NULL
) DISTRIBUTED REPLICATED;

CREATE TABLE IF NOT EXISTS stg.campaigns (
    campaign_id integer PRIMARY KEY,
    campaign_name text NOT NULL,
    channel_id integer NOT NULL,
    start_dt date NOT NULL,
    end_dt date NOT NULL CHECK (end_dt >= start_dt),
    budget numeric(14,2) NOT NULL CHECK (budget > 0)
) DISTRIBUTED REPLICATED;

CREATE TABLE IF NOT EXISTS stg.orders (
    order_id integer NOT NULL,
    order_dt date NOT NULL,
    customer_id integer NOT NULL,
    campaign_id integer NOT NULL,
    order_amount numeric(14,2) NOT NULL CHECK (order_amount >= 0),
    order_status text NOT NULL CHECK (order_status IN ('completed', 'cancelled', 'returned')),
    PRIMARY KEY (order_id, order_dt)
) DISTRIBUTED BY (order_id)
PARTITION BY RANGE (order_dt);

CREATE TABLE IF NOT EXISTS stg.orders_2025_01 PARTITION OF stg.orders
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE IF NOT EXISTS stg.orders_2025_02 PARTITION OF stg.orders
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE IF NOT EXISTS stg.orders_2025_03 PARTITION OF stg.orders
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');

CREATE TABLE IF NOT EXISTS stg.order_items (
    order_item_id integer NOT NULL,
    order_id integer NOT NULL,
    product_id integer NOT NULL,
    product_name text NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    price numeric(12,2) NOT NULL CHECK (price > 0),
    PRIMARY KEY (order_id, order_item_id)
) DISTRIBUTED BY (order_id);

CREATE TABLE IF NOT EXISTS dds.dim_customers (
    LIKE stg.customers INCLUDING ALL,
    load_dt timestamptz NOT NULL DEFAULT current_timestamp,
    load_src text NOT NULL
) DISTRIBUTED REPLICATED;

CREATE TABLE IF NOT EXISTS dds.dim_channels (
    LIKE stg.channels INCLUDING ALL,
    load_dt timestamptz NOT NULL DEFAULT current_timestamp,
    load_src text NOT NULL
) DISTRIBUTED REPLICATED;

CREATE TABLE IF NOT EXISTS dds.dim_campaigns (
    LIKE stg.campaigns INCLUDING ALL,
    load_dt timestamptz NOT NULL DEFAULT current_timestamp,
    load_src text NOT NULL
) DISTRIBUTED REPLICATED;

CREATE TABLE IF NOT EXISTS dds.fact_orders (
    LIKE stg.orders INCLUDING ALL,
    load_dt timestamptz NOT NULL DEFAULT current_timestamp,
    load_src text NOT NULL
) DISTRIBUTED BY (order_id)
PARTITION BY RANGE (order_dt);

CREATE TABLE IF NOT EXISTS dds.fact_orders_2025_01 PARTITION OF dds.fact_orders
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE IF NOT EXISTS dds.fact_orders_2025_02 PARTITION OF dds.fact_orders
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE IF NOT EXISTS dds.fact_orders_2025_03 PARTITION OF dds.fact_orders
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');

CREATE TABLE IF NOT EXISTS dds.fact_order_items (
    LIKE stg.order_items INCLUDING ALL,
    load_dt timestamptz NOT NULL DEFAULT current_timestamp,
    load_src text NOT NULL
) DISTRIBUTED BY (order_id);

-- Полное обновление сгенерированного учебного набора.
TRUNCATE stg.customers, stg.channels, stg.campaigns, stg.orders, stg.order_items;
TRUNCATE dds.dim_customers, dds.dim_channels, dds.dim_campaigns, dds.fact_orders, dds.fact_order_items;

INSERT INTO stg.customers
SELECT id, 'Клиент ' || id, DATE '2024-01-01' + (id * 7 % 366),
       CASE id % 4 WHEN 0 THEN 'Север' WHEN 1 THEN 'Юг'
                   WHEN 2 THEN 'Запад' ELSE 'Восток' END,
       CASE id % 3 WHEN 0 THEN 'Стандарт' WHEN 1 THEN 'Плюс' ELSE 'Премиум' END
FROM generate_series(1, 120) AS ids(id);

INSERT INTO stg.channels VALUES
    (1, 'Поиск', 'paid_search'),
    (2, 'Социальные сети', 'paid_social'),
    (3, 'Email', 'email'),
    (4, 'Партнёры', 'affiliate');

INSERT INTO stg.campaigns
SELECT id, 'Кампания ' || id, (id - 1) % 4 + 1,
       DATE '2025-01-01', DATE '2025-03-31', 48000 + id * 3000
FROM generate_series(1, 10) AS ids(id);

INSERT INTO stg.order_items
WITH lines AS (
    SELECT id AS order_id, line_no, ((id * 7 + line_no * 11) % 80) + 1 AS product_id
    FROM generate_series(1, 1200) AS ids(id)
    CROSS JOIN generate_series(1, 4) AS lines(line_no)
)
SELECT (order_id - 1) * 4 + line_no, order_id, product_id, 'Товар ' || product_id,
       1 + floor(random() * 3)::integer,
       round((100 + random() * 1900)::numeric, 2)
FROM lines;

-- Первые 900 заказов дают по одному завершённому заказу на день и кампанию.
-- Сумма заказа равна сумме позиций с генерируемыми ценами и количеством.
INSERT INTO stg.orders
SELECT order_id, DATE '2025-01-01' + ((order_id - 1) / 10) % 90,
       1 + floor(random() * 120)::integer, (order_id - 1) % 10 + 1,
       sum(quantity * price),
       CASE WHEN order_id <= 900 THEN 'completed'
            WHEN order_id % 5 = 0 THEN 'cancelled'
            WHEN order_id % 5 = 1 THEN 'returned'
            ELSE 'completed' END
FROM stg.order_items
GROUP BY order_id;

INSERT INTO dds.dim_customers (customer_id, customer_name, signup_dt, region, customer_segment, load_src)
SELECT customer_id, customer_name, signup_dt, region, customer_segment, 'stg.customers'
FROM stg.customers;

INSERT INTO dds.dim_channels (channel_id, channel_name, channel_type, load_src)
SELECT channel_id, channel_name, channel_type, 'stg.channels'
FROM stg.channels;

INSERT INTO dds.dim_campaigns (campaign_id, campaign_name, channel_id, start_dt, end_dt, budget, load_src)
SELECT campaign_id, campaign_name, channel_id, start_dt, end_dt, budget, 'stg.campaigns'
FROM stg.campaigns;

INSERT INTO dds.fact_orders (order_id, order_dt, customer_id, campaign_id, order_amount, order_status, load_src)
SELECT order_id, order_dt, customer_id, campaign_id, order_amount, order_status, 'stg.orders'
FROM stg.orders;

INSERT INTO dds.fact_order_items (order_item_id, order_id, product_id, product_name, quantity, price, load_src)
SELECT order_item_id, order_id, product_id, product_name, quantity, price, 'stg.order_items'
FROM stg.order_items;
COMMIT;

ANALYZE stg.customers;
ANALYZE stg.channels;
ANALYZE stg.campaigns;
ANALYZE stg.orders;
ANALYZE stg.order_items;
ANALYZE dds.dim_customers;
ANALYZE dds.dim_channels;
ANALYZE dds.dim_campaigns;
ANALYZE dds.fact_orders;
ANALYZE dds.fact_order_items;
