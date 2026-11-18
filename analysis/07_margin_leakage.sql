-- Business question: how much margin is lost to shipments priced below the tier target?
-- Techniques: point-in-time SCD2 attributes, ROLLUP, opportunity sizing.

WITH targets(tier, target_margin_rate) AS (
    VALUES ('A'::char(1), 0.08), ('B', 0.13), ('C', 0.18)
), priced AS (
    SELECT c.tier, c.industry, f.revenue_eur, f.cost_eur, f.margin_eur, t.target_margin_rate,
           f.cost_eur / (1 - t.target_margin_rate) AS target_revenue_eur
    FROM dw.fact_shipment f
    JOIN dw.dim_customer c USING (customer_key)
    JOIN targets t USING (tier)
    WHERE f.status = 'DELIVERED'
)
SELECT COALESCE(tier::text, 'ALL TIERS') AS tier_at_booking,
       COALESCE(industry, 'ALL INDUSTRIES') AS industry,
       count(*) AS shipments,
       count(*) FILTER (WHERE revenue_eur < target_revenue_eur) AS below_target,
       round(100.0 * count(*) FILTER (WHERE revenue_eur < target_revenue_eur) / count(*), 1) AS below_target_pct,
       count(*) FILTER (WHERE margin_eur < 0) AS loss_making,
       round(sum(GREATEST(target_revenue_eur - revenue_eur, 0)), 2) AS margin_opportunity_eur
FROM priced
GROUP BY ROLLUP (tier, industry)
ORDER BY GROUPING(tier), tier, GROUPING(industry), margin_opportunity_eur DESC;
