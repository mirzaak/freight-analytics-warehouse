-- Business question: which valuable customers are at risk of leaving right now?
-- Techniques: NTILE scoring, LAG inter-arrival gaps, customer-specific churn threshold.

WITH shipments AS (
    SELECT c.customer_code, f.booked_at, f.revenue_eur, f.margin_eur,
           LAG(f.booked_at) OVER (PARTITION BY c.customer_code ORDER BY f.booked_at) AS previous_booking
    FROM dw.fact_shipment f
    JOIN dw.dim_customer c USING (customer_key)
    WHERE f.status <> 'CANCELLED'
), as_of AS (
    SELECT max(booked_at) AS snapshot_at FROM shipments
), metrics AS (
    SELECT s.customer_code,
           extract(epoch FROM a.snapshot_at - max(s.booked_at)) / 86400 AS recency_days,
           count(*) AS frequency,
           sum(s.revenue_eur) AS monetary_eur,
           sum(s.margin_eur) AS margin_eur,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM s.booked_at - s.previous_booking) / 86400)
               AS median_gap_days
    FROM shipments s
    CROSS JOIN as_of a
    GROUP BY s.customer_code, a.snapshot_at
), scored AS (
    SELECT m.*,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
           NTILE(5) OVER (ORDER BY frequency) AS f_score,
           NTILE(5) OVER (ORDER BY monetary_eur) AS m_score
    FROM metrics m
)
SELECT s.customer_code, c.company_name, c.tier,
       round(s.recency_days::numeric, 1) AS recency_days,
       s.frequency, s.monetary_eur, s.margin_eur,
       round(s.median_gap_days::numeric, 1) AS median_gap_days,
       s.r_score || '-' || s.f_score || '-' || s.m_score AS rfm,
       CASE WHEN s.recency_days > 180 THEN 'Lost'
            WHEN s.r_score >= 4 AND s.f_score >= 4 AND s.m_score >= 4 THEN 'Champion'
            WHEN s.r_score <= 2 AND s.m_score >= 3 THEN 'High value at risk'
            WHEN s.r_score >= 4 AND s.f_score <= 2 THEN 'New or occasional'
            ELSE 'Core' END AS segment,
       s.recency_days <= 180
           AND s.recency_days > GREATEST(14, 4 * COALESCE(s.median_gap_days, 14)) AS churn_alert
FROM scored s
JOIN dw.dim_customer c ON c.customer_code = s.customer_code AND c.is_current
ORDER BY churn_alert DESC, s.margin_eur DESC;
