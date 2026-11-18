-- Assertion suite. Any failed check raises an exception and fails the build.

\o /dev/null

CREATE TEMP TABLE test_result (test_name text PRIMARY KEY, passed boolean NOT NULL, detail text);

CREATE FUNCTION pg_temp.check_zero(p_name text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_count bigint;
BEGIN
    EXECUTE p_sql INTO v_count;
    INSERT INTO test_result VALUES (p_name, v_count = 0, 'violations: ' || v_count);
END $$;

SELECT pg_temp.check_zero('every source booking is loaded or quarantined', $q$
    SELECT abs((SELECT count(DISTINCT upper(btrim(shipment_ref))) FROM raw.shipment)
             - (SELECT count(*) FROM dw.fact_shipment)
             - (SELECT count(*) FROM etl.rejected_shipment))
$q$);

SELECT pg_temp.check_zero('no booking is both loaded and quarantined', $q$
    SELECT count(*) FROM dw.fact_shipment f JOIN etl.rejected_shipment r USING (shipment_ref)
$q$);

SELECT pg_temp.check_zero('latest extract wins over stale duplicates', $q$
    WITH latest AS (
        SELECT DISTINCT ON (shipment_ref) shipment_ref, status
        FROM raw.shipment ORDER BY shipment_ref, extracted_at DESC, raw_id DESC
    )
    SELECT count(*) FROM dw.fact_shipment f JOIN latest l USING (shipment_ref) WHERE f.status <> l.status
$q$);

SELECT pg_temp.check_zero('revenue reconciles to source within rounding', $q$
    WITH source AS (
        SELECT v.shipment_ref, v.revenue / v.units_per_eur AS revenue_eur
        FROM etl.v_shipment_validated v WHERE cardinality(v.reject_reasons) = 0
    )
    SELECT count(*) FROM dw.fact_shipment f JOIN source s USING (shipment_ref)
    WHERE abs(f.revenue_eur - s.revenue_eur) > 0.01
$q$);

SELECT pg_temp.check_zero('injected defects are all quarantined', $q$
    SELECT count(*) FROM dw.fact_shipment
    WHERE weight_kg <= 0 OR delivered_at < picked_up_at
$q$);

SELECT pg_temp.check_zero('each expected reject reason occurs', $q$
    SELECT count(*) FROM unnest(ARRAY['INVALID_WEIGHT', 'UNKNOWN_CUSTOMER', 'UNKNOWN_FX_RATE',
                                      'INVALID_BOOKED_AT', 'DELIVERED_BEFORE_PICKUP']) e(reason)
    WHERE NOT EXISTS (SELECT 1 FROM etl.rejected_shipment r WHERE e.reason = ANY (r.reject_reasons))
$q$);

SELECT pg_temp.check_zero('each customer has exactly one current version', $q$
    SELECT count(*) FROM (
        SELECT customer_code FROM dw.dim_customer GROUP BY customer_code
        HAVING count(*) FILTER (WHERE is_current) <> 1
    ) x
$q$);

SELECT pg_temp.check_zero('SCD2 versions are contiguous', $q$
    SELECT count(*) FROM (
        SELECT valid_to, LEAD(valid_from) OVER (PARTITION BY customer_code ORDER BY valid_from) AS next_from
        FROM dw.dim_customer
    ) x WHERE next_from IS NOT NULL AND next_from <> valid_to
$q$);

SELECT pg_temp.check_zero('unchanged re-extracts create no SCD2 version', $q$
    SELECT abs((SELECT count(*) FROM dw.dim_customer)
             - (SELECT count(DISTINCT customer_code) + count(DISTINCT customer_code) FILTER (WHERE right(customer_code, 4)::int % 4 = 0)
                FROM raw.customer))
$q$);

SELECT pg_temp.check_zero('facts join the customer version valid at booking time', $q$
    SELECT count(*) FROM dw.fact_shipment f JOIN dw.dim_customer c USING (customer_key)
    WHERE NOT f.booked_at <@ tsrange(c.valid_from, c.valid_to)
$q$);

SELECT pg_temp.check_zero('delivered shipments have a delivery date key', $q$
    SELECT count(*) FROM dw.fact_shipment WHERE status = 'DELIVERED' AND delivered_date_key IS NULL
$q$);

SELECT pg_temp.check_zero('lane mart reconciles to the fact table', $q$
    SELECT count(*) FROM (
        SELECT (SELECT sum(revenue_eur) FROM mart.monthly_lane_performance) AS mart_total,
               (SELECT sum(revenue_eur) FROM dw.fact_shipment WHERE status = 'DELIVERED') AS fact_total
    ) x WHERE mart_total IS DISTINCT FROM fact_total
$q$);

SELECT pg_temp.check_zero('parsers accept regional formats and reject garbage', $q$
    SELECT count(*) FROM (VALUES
        (etl.try_numeric('1.234,50') = 1234.50),
        (etl.try_numeric('1234,5') = 1234.5),
        (etl.try_numeric(' 88.20 ') = 88.20),
        (etl.try_numeric('abc') IS NULL),
        (etl.try_timestamp('31.12.2024 18:30') = timestamp '2024-12-31 18:30'),
        (etl.try_timestamp('2024-12-31 18:30:00') = timestamp '2024-12-31 18:30'),
        (etl.try_timestamp('N/A') IS NULL)
    ) t(ok) WHERE ok IS NOT TRUE
$q$);

-- Replaying the load must change nothing.
CALL etl.run_load();

SELECT pg_temp.check_zero('second load is a no-op', $q$
    SELECT rows_inserted + rows_updated FROM etl.load_audit ORDER BY load_id DESC LIMIT 1
$q$);

-- A genuine attribute change must close the current version and open a new one.
-- The change is rolled back so the suite leaves the warehouse untouched.
BEGIN;
INSERT INTO raw.customer (customer_code, company_name, country_code, industry, tier, credit_terms_days, updated_at)
SELECT customer_code, company_name, country_code, industry, 'A', '90', timestamp '2026-02-01'
FROM dw.dim_customer WHERE customer_code = 'C0001' AND is_current;
CALL etl.run_load();
SELECT count(*) AS scd_versions,
       count(*) FILTER (WHERE is_current AND credit_terms_days = 90 AND valid_from = timestamp '2026-02-01') AS scd_new_current,
       count(*) FILTER (WHERE valid_to = timestamp '2026-02-01') AS scd_closed
FROM dw.dim_customer WHERE customer_code = 'C0001' \gset
ROLLBACK;

SELECT pg_temp.check_zero('attribute change closes old version and opens new one',
    format('SELECT %s', CASE WHEN :scd_new_current = 1 AND :scd_closed = 1 AND :scd_versions >= 2 THEN 0 ELSE 1 END));

\o
\pset format aligned
\pset footer off
SELECT CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, test_name, detail
FROM test_result ORDER BY passed, test_name;

DO $$
DECLARE
    v_failed bigint;
    v_total  bigint;
BEGIN
    SELECT count(*) FILTER (WHERE NOT passed), count(*) INTO v_failed, v_total FROM test_result;
    IF v_failed > 0 THEN
        RAISE EXCEPTION '% of % tests failed', v_failed, v_total;
    END IF;
    RAISE NOTICE 'All % tests passed', v_total;
END $$;
