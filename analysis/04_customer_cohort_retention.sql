-- Business question: do newly won customers keep shipping with us?
-- Techniques: cohort assignment, age-in-months calculation, conditional-aggregate pivot.
-- A cell is NULL when the youngest customer in the cohort has not reached that age yet,
-- so right-censored periods are never reported as 0% retention.

WITH first_month AS (
    SELECT customer_code, min(month_start) AS cohort_month
    FROM mart.customer_monthly_activity
    GROUP BY customer_code
), bounds AS (
    SELECT max(month_start) AS last_month FROM mart.customer_monthly_activity
), activity AS (
    SELECT date_trunc('quarter', f.cohort_month)::date AS cohort_quarter,
           a.customer_code,
           (extract(year FROM age(a.month_start, f.cohort_month)) * 12
            + extract(month FROM age(a.month_start, f.cohort_month)))::int AS months_since_first
    FROM mart.customer_monthly_activity a
    JOIN first_month f USING (customer_code)
), sizes AS (
    SELECT cohort_quarter, count(DISTINCT customer_code) AS cohort_size
    FROM activity
    GROUP BY cohort_quarter
), retention AS (
    SELECT a.cohort_quarter, s.cohort_size, p.age_months,
           count(DISTINCT a.customer_code) FILTER (WHERE a.months_since_first = p.age_months) AS retained
    FROM activity a
    JOIN sizes s USING (cohort_quarter)
    CROSS JOIN (VALUES (1), (3), (6), (9), (12)) p(age_months)
    GROUP BY a.cohort_quarter, s.cohort_size, p.age_months
), observable AS (
    SELECT r.*,
           CASE WHEN r.cohort_quarter + interval '2 months' + r.age_months * interval '1 month' <= b.last_month
                THEN round(100.0 * r.retained / r.cohort_size, 1) END AS retention_pct
    FROM retention r
    CROSS JOIN bounds b
)
SELECT cohort_quarter,
       cohort_size,
       max(retention_pct) FILTER (WHERE age_months = 1)  AS m01_pct,
       max(retention_pct) FILTER (WHERE age_months = 3)  AS m03_pct,
       max(retention_pct) FILTER (WHERE age_months = 6)  AS m06_pct,
       max(retention_pct) FILTER (WHERE age_months = 9)  AS m09_pct,
       max(retention_pct) FILTER (WHERE age_months = 12) AS m12_pct
FROM observable
GROUP BY cohort_quarter, cohort_size
ORDER BY cohort_quarter;
