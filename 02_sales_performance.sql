\set ON_ERROR_STOP on
\connect sales_marketing

BEGIN;
CREATE TABLE IF NOT EXISTS cdm.dm_sales_performance (
    report_dt date NOT NULL,
    campaign_id integer NOT NULL,
    campaign_name text NOT NULL,
    channel_id integer NOT NULL,
    channel_name text NOT NULL,
    orders_count bigint NOT NULL,
    customers_count bigint NOT NULL,
    order_amount numeric(16,2) NOT NULL,
    avg_order_amount numeric(16,2),
    new_customers bigint NOT NULL,
    campaign_budget numeric(14,2) NOT NULL,
    spend numeric(14,2) NOT NULL,
    revenue numeric(16,2) NOT NULL,
    roi numeric(18,6),
    PRIMARY KEY (report_dt, campaign_id)
) DISTRIBUTED BY (campaign_id);

TRUNCATE cdm.dm_sales_performance;

INSERT INTO cdm.dm_sales_performance (
    report_dt, campaign_id, campaign_name, channel_id, channel_name,
    orders_count, customers_count, order_amount, avg_order_amount, new_customers,
    campaign_budget, spend, revenue, roi
)
WITH completed_orders AS (
    SELECT o.*, row_number() OVER (PARTITION BY customer_id ORDER BY order_dt, order_id) AS purchase_number
    FROM dds.fact_orders o
    WHERE order_status = 'completed'
),
daily_sales AS (
    SELECT order_dt AS report_dt, campaign_id,
           count(*) AS orders_count, count(DISTINCT customer_id) AS customers_count,
           sum(order_amount) AS order_amount, avg(order_amount) AS avg_order_amount,
           count(*) FILTER (WHERE purchase_number = 1) AS new_customers
    FROM completed_orders
    GROUP BY order_dt, campaign_id
),
campaign_days AS (
    SELECT c.start_dt + d.day_no AS report_dt, c.campaign_id, c.campaign_name, c.channel_id,
           c.budget, c.end_dt - c.start_dt + 1 AS n_days, d.day_no,
           round(c.budget * (0.8 + 0.1 * c.channel_id), 2) AS modeled_total_spend
    FROM dds.dim_campaigns c
    CROSS JOIN LATERAL generate_series(0, c.end_dt - c.start_dt) AS d(day_no)
),
daily_spend AS (
    -- Разность накопленных затрат распределяет остаток округления между днями.
    SELECT d.*,
           round(modeled_total_spend * (day_no + 1) / n_days, 2)
           - round(modeled_total_spend * day_no / n_days, 2) AS spend
    FROM campaign_days d
)
SELECT d.report_dt, d.campaign_id, d.campaign_name, d.channel_id, c.channel_name,
       coalesce(s.orders_count, 0), coalesce(s.customers_count, 0),
       coalesce(s.order_amount, 0), round(s.avg_order_amount, 2), coalesce(s.new_customers, 0),
       d.budget, d.spend, coalesce(s.order_amount, 0),
       round((coalesce(s.order_amount, 0) - d.spend) / nullif(d.spend, 0), 6)
FROM daily_spend d
JOIN dds.dim_channels c ON c.channel_id = d.channel_id
LEFT JOIN daily_sales s ON s.report_dt = d.report_dt AND s.campaign_id = d.campaign_id;

COMMIT;
ANALYZE cdm.dm_sales_performance;
