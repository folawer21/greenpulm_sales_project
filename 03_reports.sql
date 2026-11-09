\set ON_ERROR_STOP on
\connect sales_marketing

-- 1. Топ кампаний по ROI за период. Дневные ROI не усредняются.
SELECT campaign_id, campaign_name, sum(revenue) AS revenue, sum(spend) AS spend,
       round((sum(revenue) - sum(spend)) / nullif(sum(spend), 0), 4) AS roi
FROM cdm.dm_sales_performance
GROUP BY campaign_id, campaign_name
ORDER BY roi DESC NULLS LAST, campaign_id
LIMIT 10;

-- 2. Затраты и бюджет за полный срок кампании.
SELECT campaign_id, campaign_name, max(campaign_budget) AS budget, sum(spend) AS spend,
       sum(spend) - max(campaign_budget) AS spend_minus_budget
FROM cdm.dm_sales_performance
GROUP BY campaign_id, campaign_name
ORDER BY campaign_id;

-- 3. Новые клиенты по кампаниям и месяцам.
SELECT date_trunc('month', report_dt)::date AS report_month, campaign_id, campaign_name,
       sum(new_customers) AS new_customers, sum(orders_count) AS orders_count
FROM cdm.dm_sales_performance
GROUP BY 1, campaign_id, campaign_name
ORDER BY 1, new_customers DESC, campaign_id;

-- 4. Сравнение каналов.
SELECT channel_id, channel_name, sum(orders_count) AS orders_count,
       sum(new_customers) AS new_customers, sum(revenue) AS revenue, sum(spend) AS spend,
       round((sum(revenue) - sum(spend)) / nullif(sum(spend), 0), 4) AS roi
FROM cdm.dm_sales_performance
GROUP BY channel_id, channel_name
ORDER BY roi DESC NULLS LAST, channel_id;

-- Планы соединения фактов с фильтром и без фильтра по ключу партиции.
EXPLAIN
SELECT sum(i.quantity * i.price)
FROM dds.fact_orders o
JOIN dds.fact_order_items i ON i.order_id = o.order_id
WHERE o.order_status = 'completed';

EXPLAIN ANALYZE
SELECT sum(i.quantity * i.price)
FROM dds.fact_orders o
JOIN dds.fact_order_items i ON i.order_id = o.order_id
WHERE o.order_status = 'completed'
  AND o.order_dt >= DATE '2025-02-01' AND o.order_dt < DATE '2025-03-01';

-- Отчёт по уже агрегированной витрине.
EXPLAIN ANALYZE
SELECT campaign_id, sum(revenue), sum(spend)
FROM cdm.dm_sales_performance
WHERE report_dt >= DATE '2025-02-01' AND report_dt < DATE '2025-03-01'
GROUP BY campaign_id;
