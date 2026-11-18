-- Pre-aggregated marts for dashboards. Unique indexes allow
-- REFRESH MATERIALIZED VIEW CONCURRENTLY.

CREATE MATERIALIZED VIEW mart.monthly_lane_performance AS
SELECT d.month_start,
       o.location_code AS origin_code,
       ds.location_code AS destination_code,
       f.transport_mode,
       count(*)                                   AS shipments,
       sum(f.weight_kg)                           AS weight_kg,
       sum(f.revenue_eur)                         AS revenue_eur,
       sum(f.cost_eur)                            AS cost_eur,
       sum(f.margin_eur)                          AS margin_eur,
       count(*) FILTER (WHERE f.is_on_time)       AS on_time_shipments
FROM dw.fact_shipment f
JOIN dw.dim_date d      ON d.date_key = f.booked_date_key
JOIN dw.dim_location o  ON o.location_key = f.origin_key
JOIN dw.dim_location ds ON ds.location_key = f.destination_key
WHERE f.status = 'DELIVERED'
GROUP BY d.month_start, o.location_code, ds.location_code, f.transport_mode;

CREATE UNIQUE INDEX monthly_lane_performance_pk
    ON mart.monthly_lane_performance (month_start, origin_code, destination_code, transport_mode);

CREATE MATERIALIZED VIEW mart.customer_monthly_activity AS
SELECT c.customer_code,
       d.month_start,
       count(*)           AS shipments,
       sum(f.revenue_eur) AS revenue_eur,
       sum(f.margin_eur)  AS margin_eur
FROM dw.fact_shipment f
JOIN dw.dim_customer c ON c.customer_key = f.customer_key
JOIN dw.dim_date d     ON d.date_key = f.booked_date_key
WHERE f.status = 'DELIVERED'
GROUP BY c.customer_code, d.month_start;

CREATE UNIQUE INDEX customer_monthly_activity_pk
    ON mart.customer_monthly_activity (customer_code, month_start);

CREATE PROCEDURE etl.refresh_marts()
LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW mart.monthly_lane_performance;
    REFRESH MATERIALIZED VIEW mart.customer_monthly_activity;
END $$;
