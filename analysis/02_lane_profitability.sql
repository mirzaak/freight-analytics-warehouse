-- Business question: which lanes generate the profit, and which lose money at volume?
-- Techniques: Pareto cumulative share, ranking within a partition, HAVING filters.

WITH lanes AS (
    SELECT origin_code, destination_code, transport_mode,
           sum(shipments)   AS shipments,
           sum(revenue_eur) AS revenue_eur,
           sum(margin_eur)  AS margin_eur,
           sum(on_time_shipments)::numeric / sum(shipments) AS on_time_rate
    FROM mart.monthly_lane_performance
    GROUP BY origin_code, destination_code, transport_mode
    HAVING sum(shipments) >= 30
), ranked AS (
    SELECT l.*,
           round(100 * margin_eur / nullif(revenue_eur, 0), 2) AS margin_pct,
           PERCENT_RANK() OVER (ORDER BY margin_eur / nullif(revenue_eur, 0)) AS margin_rate_percentile,
           RANK() OVER (PARTITION BY transport_mode ORDER BY margin_eur DESC) AS rank_in_mode,
           round(100 * sum(margin_eur) OVER (ORDER BY margin_eur DESC ROWS UNBOUNDED PRECEDING)
                 / sum(margin_eur) OVER (), 2) AS cumulative_margin_share_pct
    FROM lanes l
)
SELECT origin_code || ' -> ' || destination_code AS lane,
       transport_mode, shipments, revenue_eur, margin_eur, margin_pct,
       round(100 * on_time_rate, 1) AS on_time_pct,
       rank_in_mode, cumulative_margin_share_pct,
       CASE WHEN margin_rate_percentile < 0.25 THEN 'REPRICE'
            WHEN cumulative_margin_share_pct <= 80 THEN 'CORE'
            ELSE 'MAINTAIN' END AS recommended_action
FROM ranked
ORDER BY margin_eur DESC;
