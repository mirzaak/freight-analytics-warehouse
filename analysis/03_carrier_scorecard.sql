-- Business question: which carriers should win more volume at the next tender?
-- Techniques: ordered-set percentiles, PERCENT_RANK composite score, quarter-over-quarter change.

WITH delivered AS (
    SELECT c.carrier_code, c.carrier_name, c.transport_mode, f.is_on_time, f.delay_hours, f.margin_eur, f.revenue_eur,
           date_trunc('quarter', f.delivered_at)::date AS delivery_quarter
    FROM dw.fact_shipment f
    JOIN dw.dim_carrier c USING (carrier_key)
    WHERE f.status = 'DELIVERED'
), overall AS (
    SELECT carrier_code, carrier_name, transport_mode,
           count(*) AS shipments,
           avg(is_on_time::int)::numeric AS on_time_rate,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY delay_hours) AS median_delay_h,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY delay_hours) AS p95_delay_h,
           sum(margin_eur) / nullif(sum(revenue_eur), 0) AS margin_rate
    FROM delivered
    GROUP BY carrier_code, carrier_name, transport_mode
), quarterly AS (
    SELECT carrier_code, delivery_quarter, avg(is_on_time::int)::numeric AS on_time_rate,
           ROW_NUMBER() OVER (PARTITION BY carrier_code ORDER BY delivery_quarter DESC) AS recency
    FROM delivered
    GROUP BY carrier_code, delivery_quarter
), scored AS (
    SELECT o.*,
           PERCENT_RANK() OVER (PARTITION BY transport_mode ORDER BY on_time_rate) AS on_time_score,
           PERCENT_RANK() OVER (PARTITION BY transport_mode ORDER BY p95_delay_h DESC) AS tail_risk_score,
           PERCENT_RANK() OVER (PARTITION BY transport_mode ORDER BY margin_rate) AS margin_score
    FROM overall o
)
SELECT s.transport_mode, s.carrier_code, s.carrier_name, s.shipments,
       round(100 * s.on_time_rate, 1) AS on_time_pct,
       round(s.median_delay_h::numeric, 1) AS median_delay_h,
       round(s.p95_delay_h::numeric, 1) AS p95_delay_h,
       round(100 * s.margin_rate, 2) AS margin_pct,
       round(100 * (q1.on_time_rate - q2.on_time_rate), 1) AS on_time_change_vs_prior_quarter_pts,
       round((0.5 * s.on_time_score + 0.3 * s.tail_risk_score + 0.2 * s.margin_score)::numeric, 3) AS composite_score,
       RANK() OVER (PARTITION BY s.transport_mode
                    ORDER BY 0.5 * s.on_time_score + 0.3 * s.tail_risk_score + 0.2 * s.margin_score DESC) AS mode_rank
FROM scored s
LEFT JOIN quarterly q1 ON q1.carrier_code = s.carrier_code AND q1.recency = 1
LEFT JOIN quarterly q2 ON q2.carrier_code = s.carrier_code AND q2.recency = 2
ORDER BY s.transport_mode, mode_rank;
