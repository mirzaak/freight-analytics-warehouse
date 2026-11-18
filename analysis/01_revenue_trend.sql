-- Business question: how are revenue and margin trending once seasonality is smoothed?
-- Techniques: LAG, rolling window frames, year-over-year comparison.

WITH monthly AS (
    SELECT month_start,
           sum(shipments)   AS shipments,
           sum(revenue_eur) AS revenue_eur,
           sum(margin_eur)  AS margin_eur
    FROM mart.monthly_lane_performance
    GROUP BY month_start
)
SELECT month_start,
       shipments,
       revenue_eur,
       round(100 * margin_eur / nullif(revenue_eur, 0), 2) AS margin_pct,
       round(100 * (revenue_eur / nullif(LAG(revenue_eur) OVER w, 0) - 1), 2) AS revenue_mom_pct,
       round(100 * (revenue_eur / nullif(LAG(revenue_eur, 12) OVER w, 0) - 1), 2) AS revenue_yoy_pct,
       round(AVG(revenue_eur) OVER (w ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS revenue_3m_avg,
       sum(revenue_eur) OVER (PARTITION BY date_trunc('year', month_start) ORDER BY month_start) AS revenue_ytd
FROM monthly
WINDOW w AS (ORDER BY month_start)
ORDER BY month_start;
