-- Idempotent raw -> warehouse load: parse, deduplicate, validate, quarantine,
-- apply SCD2, upsert facts, and record an audit row.

CREATE TABLE etl.load_audit (
    load_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at     timestamptz NOT NULL,
    finished_at    timestamptz NOT NULL,
    raw_rows       bigint NOT NULL,
    distinct_refs  bigint NOT NULL,
    rows_inserted  bigint NOT NULL,
    rows_updated   bigint NOT NULL,
    rows_unchanged bigint NOT NULL,
    rows_rejected  bigint NOT NULL
);

CREATE TABLE etl.rejected_shipment (
    shipment_ref   text PRIMARY KEY,
    raw_id         bigint NOT NULL,
    reject_reasons text[] NOT NULL CHECK (cardinality(reject_reasons) > 0),
    rejected_at    timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION etl.try_numeric(p_value text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v text := btrim(p_value);
BEGIN
    IF v IS NULL OR v = '' THEN
        RETURN NULL;
    END IF;
    IF v ~ '^-?\d{1,3}(\.\d{3})*,\d+$' OR v ~ '^-?\d+,\d+$' THEN
        v := replace(replace(v, '.', ''), ',', '.');
    END IF;
    RETURN v::numeric;
EXCEPTION WHEN data_exception THEN
    RETURN NULL;
END $$;

CREATE FUNCTION etl.try_timestamp(p_value text) RETURNS timestamp
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v text := btrim(p_value);
BEGIN
    IF v IS NULL OR v = '' THEN
        RETURN NULL;
    END IF;
    IF v ~ '^\d{2}\.\d{2}\.\d{4}' THEN
        RETURN to_timestamp(v, 'DD.MM.YYYY HH24:MI')::timestamp;
    END IF;
    RETURN v::timestamp;
EXCEPTION WHEN data_exception THEN
    RETURN NULL;
END $$;

CREATE VIEW etl.v_shipment_typed AS
WITH ranked AS (
    SELECT s.*,
           row_number() OVER (
               PARTITION BY upper(btrim(s.shipment_ref))
               ORDER BY s.extracted_at DESC, s.raw_id DESC
           ) AS version_rank
    FROM raw.shipment s
    WHERE nullif(btrim(s.shipment_ref), '') IS NOT NULL
)
SELECT raw_id,
       upper(btrim(shipment_ref))           AS shipment_ref,
       etl.try_timestamp(booked_at)         AS booked_at,
       upper(btrim(customer_code))          AS customer_code,
       upper(btrim(carrier_code))           AS carrier_code,
       upper(btrim(origin_code))            AS origin_code,
       upper(btrim(destination_code))       AS destination_code,
       upper(btrim(transport_mode))         AS transport_mode,
       upper(btrim(incoterm))               AS incoterm,
       upper(btrim(status))                 AS status,
       etl.try_numeric(weight_kg)           AS weight_kg,
       etl.try_numeric(volume_m3)           AS volume_m3,
       etl.try_timestamp(picked_up_at)      AS picked_up_at,
       etl.try_timestamp(promised_at)       AS promised_at,
       etl.try_timestamp(delivered_at)      AS delivered_at,
       upper(btrim(customs_channel))        AS customs_channel,
       etl.try_timestamp(customs_lodged_at)   AS customs_lodged_at,
       etl.try_timestamp(customs_released_at) AS customs_released_at,
       etl.try_numeric(revenue)             AS revenue,
       etl.try_numeric(cost)                AS cost,
       upper(btrim(currency_code))          AS currency_code
FROM ranked
WHERE version_rank = 1;

CREATE VIEW etl.v_shipment_validated AS
SELECT t.*,
       cu.customer_key, ca.carrier_key, o.location_key AS origin_key, d.location_key AS destination_key,
       fx.units_per_eur,
       array_remove(ARRAY[
           CASE WHEN t.booked_at IS NULL THEN 'INVALID_BOOKED_AT' END,
           CASE WHEN t.promised_at IS NULL THEN 'INVALID_PROMISED_AT' END,
           CASE WHEN t.weight_kg IS NULL OR t.weight_kg <= 0 THEN 'INVALID_WEIGHT' END,
           CASE WHEN t.volume_m3 IS NULL OR t.volume_m3 <= 0 THEN 'INVALID_VOLUME' END,
           CASE WHEN t.revenue IS NULL OR t.cost IS NULL THEN 'INVALID_AMOUNT' END,
           CASE WHEN t.booked_at IS NOT NULL AND cu.customer_key IS NULL THEN 'UNKNOWN_CUSTOMER' END,
           CASE WHEN ca.carrier_key IS NULL THEN 'UNKNOWN_CARRIER' END,
           CASE WHEN o.location_key IS NULL THEN 'UNKNOWN_ORIGIN' END,
           CASE WHEN d.location_key IS NULL THEN 'UNKNOWN_DESTINATION' END,
           CASE WHEN t.booked_at IS NOT NULL AND fx.units_per_eur IS NULL THEN 'UNKNOWN_FX_RATE' END,
           CASE WHEN t.status NOT IN ('BOOKED', 'IN_TRANSIT', 'DELIVERED', 'CANCELLED') OR t.status IS NULL THEN 'INVALID_STATUS' END,
           CASE WHEN t.status = 'DELIVERED' AND t.delivered_at IS NULL THEN 'MISSING_DELIVERY_TIME' END,
           CASE WHEN t.delivered_at < t.picked_up_at THEN 'DELIVERED_BEFORE_PICKUP' END
       ], NULL) AS reject_reasons
FROM etl.v_shipment_typed t
LEFT JOIN dw.dim_customer cu
       ON cu.customer_code = t.customer_code AND t.booked_at <@ tsrange(cu.valid_from, cu.valid_to)
LEFT JOIN dw.dim_carrier  ca ON ca.carrier_code = t.carrier_code
LEFT JOIN dw.dim_location o  ON o.location_code = t.origin_code
LEFT JOIN dw.dim_location d  ON d.location_code = t.destination_code
LEFT JOIN raw.exchange_rate fx
       ON fx.currency_code = t.currency_code AND fx.rate_month = date_trunc('month', t.booked_at)::date;

CREATE PROCEDURE etl.load_dimensions()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dw.dim_location (location_code, city, country_code, country_name, region, is_eu, is_seaport)
    SELECT location_code, city, country_code, country_name, region, is_eu, is_seaport
    FROM raw.location
    ON CONFLICT (location_code) DO UPDATE
    SET city = EXCLUDED.city, country_code = EXCLUDED.country_code, country_name = EXCLUDED.country_name,
        region = EXCLUDED.region, is_eu = EXCLUDED.is_eu, is_seaport = EXCLUDED.is_seaport
    WHERE (dw.dim_location.city, dw.dim_location.region, dw.dim_location.is_eu, dw.dim_location.is_seaport)
          IS DISTINCT FROM (EXCLUDED.city, EXCLUDED.region, EXCLUDED.is_eu, EXCLUDED.is_seaport);

    INSERT INTO dw.dim_carrier (carrier_code, carrier_name, transport_mode)
    SELECT carrier_code, carrier_name, transport_mode FROM raw.carrier
    ON CONFLICT (carrier_code) DO UPDATE
    SET carrier_name = EXCLUDED.carrier_name, transport_mode = EXCLUDED.transport_mode
    WHERE (dw.dim_carrier.carrier_name, dw.dim_carrier.transport_mode)
          IS DISTINCT FROM (EXCLUDED.carrier_name, EXCLUDED.transport_mode);

    -- Gaps-and-islands: consecutive extracts with identical attributes collapse
    -- into one version, so a re-extract never produces a spurious SCD2 row.
    MERGE INTO dw.dim_customer AS target
    USING (
        WITH typed AS (
            SELECT upper(btrim(customer_code)) AS customer_code, btrim(company_name) AS company_name,
                   upper(btrim(country_code)) AS country_code, btrim(industry) AS industry,
                   upper(btrim(tier)) AS tier, credit_terms_days::smallint AS credit_terms_days, updated_at
            FROM raw.customer
        ), flagged AS (
            SELECT t.*,
                   (company_name, country_code, industry, tier, credit_terms_days) IS DISTINCT FROM
                   (LAG(company_name) OVER w, LAG(country_code) OVER w, LAG(industry) OVER w,
                    LAG(tier) OVER w, LAG(credit_terms_days) OVER w) AS is_change
            FROM typed t
            WINDOW w AS (PARTITION BY customer_code ORDER BY updated_at)
        ), versions AS (
            SELECT f.*, row_number() OVER (PARTITION BY customer_code ORDER BY updated_at) AS version_no
            FROM flagged f
            WHERE is_change
        )
        SELECT customer_code, company_name, country_code, industry, tier, credit_terms_days,
               CASE WHEN version_no = 1 THEN timestamp '-infinity' ELSE updated_at END AS valid_from,
               COALESCE(LEAD(updated_at) OVER (PARTITION BY customer_code ORDER BY updated_at),
                        timestamp 'infinity') AS valid_to
        FROM versions
    ) AS source
    ON target.customer_code = source.customer_code AND target.valid_from = source.valid_from
    WHEN MATCHED AND (target.company_name, target.country_code, target.industry, target.tier,
                      target.credit_terms_days, target.valid_to)
                     IS DISTINCT FROM
                     (source.company_name, source.country_code::char(2), source.industry, source.tier::char(1),
                      source.credit_terms_days, source.valid_to)
        THEN UPDATE SET company_name = source.company_name, country_code = source.country_code,
                        industry = source.industry, tier = source.tier,
                        credit_terms_days = source.credit_terms_days, valid_to = source.valid_to
    WHEN NOT MATCHED
        THEN INSERT (customer_code, company_name, country_code, industry, tier, credit_terms_days, valid_from, valid_to)
             VALUES (source.customer_code, source.company_name, source.country_code, source.industry,
                     source.tier, source.credit_terms_days, source.valid_from, source.valid_to);

    SET CONSTRAINTS dw.dim_customer_no_overlap IMMEDIATE;
END $$;

CREATE PROCEDURE etl.run_load()
LANGUAGE plpgsql AS $$
DECLARE
    v_started   timestamptz := clock_timestamp();
    v_raw       bigint;
    v_refs      bigint;
    v_inserted  bigint;
    v_updated   bigint;
    v_rejected  bigint;
BEGIN
    CALL etl.load_dimensions();

    CREATE TEMP TABLE _validated ON COMMIT DROP AS
    SELECT * FROM etl.v_shipment_validated;

    SELECT count(*) INTO v_raw FROM raw.shipment;
    SELECT count(*) INTO v_refs FROM _validated;

    DELETE FROM etl.rejected_shipment r
    WHERE NOT EXISTS (
        SELECT 1 FROM _validated v
        WHERE v.shipment_ref = r.shipment_ref AND cardinality(v.reject_reasons) > 0
    );

    INSERT INTO etl.rejected_shipment (shipment_ref, raw_id, reject_reasons)
    SELECT shipment_ref, raw_id, reject_reasons
    FROM _validated
    WHERE cardinality(reject_reasons) > 0
    ON CONFLICT (shipment_ref) DO UPDATE
    SET raw_id = EXCLUDED.raw_id, reject_reasons = EXCLUDED.reject_reasons
    WHERE (etl.rejected_shipment.raw_id, etl.rejected_shipment.reject_reasons)
          IS DISTINCT FROM (EXCLUDED.raw_id, EXCLUDED.reject_reasons);

    DELETE FROM dw.fact_shipment f
    USING etl.rejected_shipment r
    WHERE f.shipment_ref = r.shipment_ref;

    WITH upserted AS (
        INSERT INTO dw.fact_shipment (
            shipment_ref, customer_key, carrier_key, origin_key, destination_key, booked_date_key,
            delivered_date_key, transport_mode, incoterm, status, customs_channel, weight_kg, volume_m3,
            revenue_eur, cost_eur, booked_at, picked_up_at, promised_at, delivered_at,
            customs_lodged_at, customs_released_at)
        SELECT shipment_ref, customer_key, carrier_key, origin_key, destination_key,
               to_char(booked_at, 'YYYYMMDD')::integer,
               to_char(delivered_at, 'YYYYMMDD')::integer,
               transport_mode, incoterm, status, nullif(customs_channel, ''),
               round(weight_kg, 2), round(volume_m3, 2),
               round(revenue / units_per_eur, 2), round(cost / units_per_eur, 2),
               booked_at, picked_up_at, promised_at, delivered_at, customs_lodged_at, customs_released_at
        FROM _validated
        WHERE cardinality(reject_reasons) = 0
        ON CONFLICT (shipment_ref) DO UPDATE
        SET customer_key = EXCLUDED.customer_key, carrier_key = EXCLUDED.carrier_key,
            origin_key = EXCLUDED.origin_key, destination_key = EXCLUDED.destination_key,
            booked_date_key = EXCLUDED.booked_date_key, delivered_date_key = EXCLUDED.delivered_date_key,
            transport_mode = EXCLUDED.transport_mode, incoterm = EXCLUDED.incoterm, status = EXCLUDED.status,
            customs_channel = EXCLUDED.customs_channel, weight_kg = EXCLUDED.weight_kg,
            volume_m3 = EXCLUDED.volume_m3, revenue_eur = EXCLUDED.revenue_eur, cost_eur = EXCLUDED.cost_eur,
            booked_at = EXCLUDED.booked_at, picked_up_at = EXCLUDED.picked_up_at,
            promised_at = EXCLUDED.promised_at, delivered_at = EXCLUDED.delivered_at,
            customs_lodged_at = EXCLUDED.customs_lodged_at, customs_released_at = EXCLUDED.customs_released_at
        WHERE (dw.fact_shipment.customer_key, dw.fact_shipment.carrier_key, dw.fact_shipment.status,
               dw.fact_shipment.revenue_eur, dw.fact_shipment.cost_eur, dw.fact_shipment.weight_kg,
               dw.fact_shipment.volume_m3, dw.fact_shipment.delivered_at, dw.fact_shipment.promised_at,
               dw.fact_shipment.customs_channel, dw.fact_shipment.customs_released_at)
              IS DISTINCT FROM
              (EXCLUDED.customer_key, EXCLUDED.carrier_key, EXCLUDED.status,
               EXCLUDED.revenue_eur, EXCLUDED.cost_eur, EXCLUDED.weight_kg,
               EXCLUDED.volume_m3, EXCLUDED.delivered_at, EXCLUDED.promised_at,
               EXCLUDED.customs_channel, EXCLUDED.customs_released_at)
        RETURNING (xmax = 0) AS was_inserted
    )
    SELECT count(*) FILTER (WHERE was_inserted), count(*) FILTER (WHERE NOT was_inserted)
    INTO v_inserted, v_updated
    FROM upserted;

    SELECT count(*) INTO v_rejected FROM etl.rejected_shipment;

    INSERT INTO etl.load_audit (started_at, finished_at, raw_rows, distinct_refs, rows_inserted,
                                rows_updated, rows_unchanged, rows_rejected)
    VALUES (v_started, clock_timestamp(), v_raw, v_refs, v_inserted, v_updated,
            v_refs - v_rejected - v_inserted - v_updated, v_rejected);

    DROP TABLE _validated;
END $$;
