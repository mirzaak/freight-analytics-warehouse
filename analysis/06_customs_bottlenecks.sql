-- Business question: where does customs clearance break the delivery promise?
-- Techniques: GROUPING SETS, percentiles, conditional aggregation.

WITH cleared AS (
    SELECT f.customs_channel,
           d.weekday_name AS lodged_weekday,
           extract(isodow FROM f.customs_lodged_at)::int AS weekday_no,
           f.customs_hours, f.is_on_time
    FROM dw.fact_shipment f
    JOIN dw.dim_date d ON d.full_date = f.customs_lodged_at::date
    WHERE f.status = 'DELIVERED' AND f.customs_channel IS NOT NULL
)
SELECT COALESCE(customs_channel, 'ALL CHANNELS') AS customs_channel,
       COALESCE(lodged_weekday, 'ALL DAYS') AS lodged_weekday,
       count(*) AS declarations,
       round(avg(customs_hours), 1) AS avg_hours,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY customs_hours))::numeric, 1) AS median_hours,
       round((percentile_cont(0.9) WITHIN GROUP (ORDER BY customs_hours))::numeric, 1) AS p90_hours,
       round(100.0 * count(*) FILTER (WHERE customs_hours > 48) / count(*), 1) AS over_48h_pct,
       round(100.0 * count(*) FILTER (WHERE is_on_time) / count(*), 1) AS on_time_pct
FROM cleared
GROUP BY GROUPING SETS ((customs_channel), (lodged_weekday, weekday_no), ())
ORDER BY GROUPING(customs_channel), customs_channel, weekday_no NULLS LAST;
