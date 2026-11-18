-- Deterministic synthetic data: 24 months of bookings for a fictional freight
-- forwarder. All companies and carriers are invented. Known data-quality
-- defects are injected on purpose so the ETL has real work to do.

SELECT setseed(0.2024);

INSERT INTO raw.location VALUES
    ('BASJJ', 'Sarajevo',  'BA', 'Bosnia and Herzegovina', 'Western Balkans', false, false, 43.85630, 18.41310),
    ('BAOMO', 'Mostar',    'BA', 'Bosnia and Herzegovina', 'Western Balkans', false, false, 43.34380, 17.80780),
    ('BATZL', 'Tuzla',     'BA', 'Bosnia and Herzegovina', 'Western Balkans', false, false, 44.53840, 18.66710),
    ('RSBEG', 'Belgrade',  'RS', 'Serbia',                 'Western Balkans', false, false, 44.78660, 20.44890),
    ('HRZAG', 'Zagreb',    'HR', 'Croatia',                'Adriatic',        true,  false, 45.81500, 15.98190),
    ('HRRJK', 'Rijeka',    'HR', 'Croatia',                'Adriatic',        true,  true,  45.32710, 14.44220),
    ('HRPLE', 'Ploce',     'HR', 'Croatia',                'Adriatic',        true,  true,  43.05640, 17.43170),
    ('SIKOP', 'Koper',     'SI', 'Slovenia',               'Adriatic',        true,  true,  45.54810, 13.73020),
    ('SILJU', 'Ljubljana', 'SI', 'Slovenia',               'Adriatic',        true,  false, 46.05690, 14.50580),
    ('ITTRS', 'Trieste',   'IT', 'Italy',                  'Adriatic',        true,  true,  45.64950, 13.77680),
    ('ITMIL', 'Milan',     'IT', 'Italy',                  'Western Europe',  true,  false, 45.46420, 9.19000),
    ('ATVIE', 'Vienna',    'AT', 'Austria',                'Central Europe',  true,  false, 48.20820, 16.37380),
    ('HUBUD', 'Budapest',  'HU', 'Hungary',                'Central Europe',  true,  false, 47.49790, 19.04020),
    ('PLWAW', 'Warsaw',    'PL', 'Poland',                 'Central Europe',  true,  false, 52.22970, 21.01220),
    ('DEMUC', 'Munich',    'DE', 'Germany',                'Western Europe',  true,  false, 48.13510, 11.58200),
    ('DEFRA', 'Frankfurt', 'DE', 'Germany',                'Western Europe',  true,  false, 50.11090, 8.68210),
    ('DEHAM', 'Hamburg',   'DE', 'Germany',                'Western Europe',  true,  true,  53.55110, 9.99370),
    ('NLRTM', 'Rotterdam', 'NL', 'Netherlands',            'Western Europe',  true,  true,  51.92440, 4.47770),
    ('TRIST', 'Istanbul',  'TR', 'Turkiye',                'Overseas',        false, true,  41.00820, 28.97840),
    ('CNSHA', 'Shanghai',  'CN', 'China',                  'Overseas',        false, true,  31.23040, 121.47370),
    ('USNYC', 'New York',  'US', 'United States',          'Overseas',        false, true,  40.71280, -74.00600);

CREATE TEMP TABLE _carrier (carrier_code text, carrier_name text, transport_mode text, delay_factor numeric);
INSERT INTO _carrier VALUES
    ('RD01', 'Dinara Linehaul',       'ROAD', 0.30),
    ('RD02', 'Neretva Haulage',       'ROAD', 0.42),
    ('RD03', 'Sava Corridor Freight', 'ROAD', 0.62),
    ('RD04', 'Alpenpass Transit',     'ROAD', 0.34),
    ('RD05', 'Una Valley Trucking',   'ROAD', 0.85),
    ('RL01', 'Danube Rail Cargo',     'RAIL', 0.38),
    ('RL02', 'Vrbas Intermodal',      'RAIL', 0.72),
    ('SE01', 'Blue Adriatic Lines',   'SEA',  0.24),
    ('SE02', 'Meridian Box Shipping', 'SEA',  0.46),
    ('AR01', 'Skybridge Air Freight', 'AIR',  0.32),
    ('AR02', 'Polar Route Cargo',     'AIR',  0.58);
INSERT INTO raw.carrier SELECT carrier_code, carrier_name, transport_mode FROM _carrier;

INSERT INTO raw.exchange_rate
SELECT m::date, c.currency_code,
       CASE c.currency_code
           WHEN 'EUR' THEN 1
           WHEN 'BAM' THEN 1.95583
           ELSE round((1.09 + 0.05 * sin(extract(epoch FROM m) / 8000000))::numeric, 6)
       END
FROM generate_series(date '2024-01-01', date '2025-12-01', interval '1 month') m
CROSS JOIN (VALUES ('EUR'), ('BAM'), ('USD')) c(currency_code);

CREATE TEMP TABLE _customer AS
SELECT n,
       'C' || lpad(n::text, 4, '0') AS customer_code,
       (ARRAY['Adria', 'Bosna', 'Drina', 'Kvarner', 'Lipa', 'Morava', 'Orion', 'Pannon', 'Tara', 'Vardar', 'Zenit', 'Sana'])[1 + n % 12]
           || ' ' || (ARRAY['Trading', 'Foods', 'Metals', 'Textiles', 'Components', 'Timber', 'Pharma'])[1 + n % 7]
           || ' ' || n AS company_name,
       (ARRAY['BA', 'BA', 'BA', 'HR', 'RS', 'SI', 'DE', 'AT', 'IT', 'US'])[1 + floor(random() * 10)::int] AS country_code,
       (ARRAY['Retail', 'Food & Beverage', 'Metal Processing', 'Textiles', 'Automotive', 'Wood Industry', 'Healthcare'])[1 + n % 7] AS industry,
       (ARRAY['A', 'B', 'B', 'C', 'C', 'C'])[1 + floor(random() * 6)::int] AS tier,
       (ARRAY[15, 30, 30, 45, 60])[1 + floor(random() * 5)::int] AS credit_terms_days,
       CASE WHEN n <= 40 THEN timestamp '2024-01-01'
            ELSE timestamp '2024-02-01' + random() * interval '600 days' END AS active_from,
       random() AS r_churn,
       random() AS r_life
FROM generate_series(1, 120) n;

ALTER TABLE _customer ADD COLUMN active_to timestamp;
UPDATE _customer
SET active_to = CASE WHEN r_churn < 0.32
                     THEN active_from + (90 + r_life * 360) * interval '1 day'
                     ELSE timestamp 'infinity' END;

-- Version 1 of every customer, a real attribute change for every 4th customer,
-- and an unchanged re-extract for every 5th (must not create a new SCD2 version).
INSERT INTO raw.customer (customer_code, company_name, country_code, industry, tier, credit_terms_days, updated_at)
SELECT customer_code, company_name, country_code, industry, tier, credit_terms_days::text, timestamp '2023-12-15'
FROM _customer;

INSERT INTO raw.customer (customer_code, company_name, country_code, industry, tier, credit_terms_days, updated_at)
SELECT customer_code, company_name, country_code, industry,
       CASE tier WHEN 'C' THEN 'B' WHEN 'B' THEN 'A' ELSE 'B' END,
       (credit_terms_days + 15)::text,
       timestamp '2024-07-01' + (n % 300) * interval '1 day'
FROM _customer
WHERE n % 4 = 0;

INSERT INTO raw.customer (customer_code, company_name, country_code, industry, tier, credit_terms_days, updated_at)
SELECT customer_code, company_name, country_code, industry, tier, credit_terms_days::text, timestamp '2024-03-01'
FROM _customer
WHERE n % 5 = 0;

CREATE TEMP TABLE _lane AS
WITH pairs AS (
    SELECT o.location_code AS origin_code, d.location_code AS destination_code,
           o.region AS origin_region, d.region AS destination_region, d.is_seaport AS dest_seaport,
           o.is_eu AS origin_eu, d.is_eu AS dest_eu,
           6371 * 2 * asin(sqrt(
               power(sin(radians(d.latitude - o.latitude)::float8 / 2), 2)
               + cos(radians(o.latitude)::float8) * cos(radians(d.latitude)::float8)
               * power(sin(radians(d.longitude - o.longitude)::float8 / 2), 2))) AS km
    FROM raw.location o
    JOIN raw.location d ON o.location_code <> d.location_code
), moded AS (
    SELECT p.*, m.transport_mode
    FROM pairs p
    CROSS JOIN LATERAL (VALUES ('ROAD'), ('RAIL'), ('SEA'), ('AIR')) m(transport_mode)
    WHERE (p.origin_region <> 'Overseas' AND p.destination_region <> 'Overseas'
           AND (m.transport_mode = 'ROAD' OR (m.transport_mode = 'RAIL' AND p.km > 450)))
       OR (p.origin_region = 'Overseas' AND p.destination_region <> 'Overseas'
           AND ((m.transport_mode = 'SEA' AND p.dest_seaport) OR m.transport_mode = 'AIR'))
       OR (p.origin_code = 'TRIST' AND p.destination_region <> 'Overseas' AND m.transport_mode = 'ROAD')
)
SELECT row_number() OVER (ORDER BY random()) AS lane_n, moded.*
FROM (SELECT * FROM moded ORDER BY origin_code, destination_code, transport_mode) moded;

CREATE TEMP TABLE _shipment AS
WITH candidate AS MATERIALIZED (
    SELECT g AS n,
           timestamp '2024-01-01' + random() * interval '730 days' AS booked_at,
           1 + floor(120 * power(random(), 2.3))::int AS customer_n,
           1 + floor((SELECT count(*) FROM _lane) * power(random(), 2.2))::int AS lane_n,
           random() r_carrier, random() r_weight, random() r_volume, random() r_delay,
           random() r_channel, random() r_customs, random() r_margin, random() r_status,
           random() r_incoterm, random() r_pickup, random() r_season, random() r_format
    FROM generate_series(1, 90000) g
), active AS (
    SELECT c.*, cu.customer_code, cu.tier, cu.country_code AS customer_country, l.origin_code, l.destination_code,
           l.transport_mode, l.km, l.origin_eu, l.dest_eu
    FROM candidate c
    JOIN _customer cu ON cu.n = c.customer_n AND c.booked_at BETWEEN cu.active_from AND cu.active_to
    JOIN _lane l ON l.lane_n = c.lane_n
    WHERE c.r_season < 0.78 + 0.22 * sin(2 * pi() * (extract(month FROM c.booked_at)::float8 - 2) / 6)
), carrier_pick AS (
    SELECT a.*, cr.carrier_code, cr.delay_factor
    FROM active a
    JOIN LATERAL (
        SELECT c.carrier_code, c.delay_factor,
               row_number() OVER (ORDER BY c.carrier_code) AS rn,
               count(*) OVER () AS total
        FROM _carrier c WHERE c.transport_mode = a.transport_mode
    ) cr ON cr.rn = 1 + floor(a.r_carrier * cr.total)::int
), shaped AS (
    SELECT p.*,
           CASE p.transport_mode
               WHEN 'ROAD' THEN p.km * 1.25 / 58 + 14
               WHEN 'RAIL' THEN p.km * 1.25 / 34 + 40
               WHEN 'SEA'  THEN p.km * 1.55 / 30 + 260
               ELSE p.km / 620 + 40
           END AS planned_hours,
           CASE p.transport_mode
               WHEN 'AIR' THEN 40 + power(p.r_weight, 3) * 1800
               ELSE 180 + power(p.r_weight, 3) * 21000
           END AS weight_kg,
           NOT (p.origin_eu AND p.dest_eu) AS customs_required
    FROM carrier_pick p
), timed AS (
    SELECT s.*,
           s.booked_at + (10 + s.r_pickup * 50) * interval '1 hour' AS picked_up_at,
           CASE WHEN NOT s.customs_required THEN NULL
                WHEN s.r_channel < 0.68 THEN 'GREEN'
                WHEN s.r_channel < 0.91 THEN 'YELLOW'
                ELSE 'RED' END AS customs_channel
    FROM shaped s
), customs AS (
    SELECT t.*,
           t.picked_up_at + t.planned_hours * 0.45 * interval '1 hour' AS customs_lodged_at,
           CASE t.customs_channel
               WHEN 'GREEN'  THEN 2 + t.r_customs * 8
               WHEN 'YELLOW' THEN 10 + t.r_customs * 30
               WHEN 'RED'    THEN 40 + t.r_customs * 90
               ELSE 0
           END AS base_customs_hours
    FROM timed t
), finished AS (
    SELECT c.*,
           c.base_customs_hours
             + CASE WHEN c.customs_required AND extract(isodow FROM c.customs_lodged_at) IN (5, 6) THEN 30 ELSE 0 END
             AS customs_hours,
           c.planned_hours * (0.93 + power(c.r_delay, 3) * c.delay_factor
             + CASE WHEN extract(month FROM c.booked_at) IN (12, 1, 2) THEN 0.06 ELSE 0 END) AS actual_hours
    FROM customs c
), priced AS (
    SELECT f.*,
           45 + f.weight_kg * f.km * CASE f.transport_mode
               WHEN 'ROAD' THEN 0.00016 WHEN 'RAIL' THEN 0.00011 WHEN 'SEA' THEN 0.000018 ELSE 0.00062 END AS cost_eur,
           CASE f.tier WHEN 'A' THEN 0.09 WHEN 'B' THEN 0.15 ELSE 0.21 END + (f.r_margin - 0.45) * 0.34 AS margin_rate
    FROM finished f
)
SELECT row_number() OVER (ORDER BY booked_at, n) AS rn,
       p.*,
       p.picked_up_at + (p.actual_hours + p.customs_hours) * interval '1 hour' AS delivered_at,
       p.picked_up_at + (p.planned_hours * 1.14 + CASE WHEN p.customs_required THEN 36 ELSE 0 END) * interval '1 hour' AS promised_at,
       CASE p.customer_country WHEN 'BA' THEN 'BAM' WHEN 'US' THEN 'USD' ELSE 'EUR' END AS currency_code
FROM priced p;

CREATE TEMP TABLE _raw_shipment AS
SELECT s.rn,
       'SHP-' || lpad(s.rn::text, 7, '0') AS shipment_ref,
       s.booked_at, s.customer_code, s.carrier_code, s.origin_code, s.destination_code, s.transport_mode,
       (ARRAY['EXW', 'FCA', 'CPT', 'DAP', 'DAP', 'DDP'])[1 + floor(s.r_incoterm * 6)::int] AS incoterm,
       CASE WHEN s.r_status < 0.025 THEN 'CANCELLED'
            WHEN s.picked_up_at > timestamp '2026-01-01' THEN 'BOOKED'
            WHEN s.picked_up_at + (s.actual_hours + s.customs_hours) * interval '1 hour' > timestamp '2026-01-01' THEN 'IN_TRANSIT'
            ELSE 'DELIVERED' END AS status,
       s.weight_kg, s.weight_kg / (160 + s.r_volume * 240) AS volume_m3,
       s.picked_up_at, s.promised_at, s.delivered_at, s.customs_channel, s.customs_required,
       s.customs_lodged_at, s.customs_lodged_at + s.customs_hours * interval '1 hour' AS customs_released_at,
       s.cost_eur * (1 + s.margin_rate) * fx.units_per_eur AS revenue,
       s.cost_eur * fx.units_per_eur AS cost,
       s.currency_code, s.r_format
FROM _shipment s
JOIN raw.exchange_rate fx
  ON fx.rate_month = date_trunc('month', s.booked_at)::date AND fx.currency_code = s.currency_code;

CREATE FUNCTION pg_temp.ts_text(p timestamp, r float8) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p IS NULL THEN NULL
                WHEN r < 0.06 THEN to_char(p, 'DD.MM.YYYY HH24:MI')
                ELSE to_char(p, 'YYYY-MM-DD HH24:MI:SS') END
$$;

CREATE FUNCTION pg_temp.num_text(p float8, r float8) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p IS NULL THEN NULL
                WHEN r > 0.95 THEN replace(round(p::numeric, 2)::text, '.', ',')
                ELSE round(p::numeric, 2)::text END
$$;

INSERT INTO raw.shipment (
    shipment_ref, booked_at, customer_code, carrier_code, origin_code, destination_code, transport_mode,
    incoterm, status, weight_kg, volume_m3, picked_up_at, promised_at, delivered_at, customs_channel,
    customs_lodged_at, customs_released_at, revenue, cost, currency_code, extracted_at)
SELECT r.shipment_ref,
       CASE WHEN r.rn % 1801 = 0 THEN 'N/A' ELSE pg_temp.ts_text(r.booked_at, r.r_format) END,
       CASE WHEN r.rn % 907 = 0 THEN 'C9999'
            WHEN r.r_format BETWEEN 0.20 AND 0.23 THEN '  ' || lower(r.customer_code) || ' '
            ELSE r.customer_code END,
       r.carrier_code, r.origin_code, r.destination_code, r.transport_mode, r.incoterm, r.status,
       CASE WHEN r.rn % 701 = 0 THEN '-' || round(r.weight_kg::numeric, 2)::text
            ELSE pg_temp.num_text(r.weight_kg, r.r_format) END,
       pg_temp.num_text(r.volume_m3, r.r_format),
       CASE WHEN r.status IN ('CANCELLED', 'BOOKED') THEN NULL ELSE pg_temp.ts_text(r.picked_up_at, r.r_format) END,
       pg_temp.ts_text(r.promised_at, r.r_format),
       CASE WHEN r.status <> 'DELIVERED' THEN NULL
            WHEN r.rn % 1009 = 0 THEN pg_temp.ts_text(r.picked_up_at - interval '6 hours', r.r_format)
            ELSE pg_temp.ts_text(r.delivered_at, r.r_format) END,
       CASE WHEN r.status = 'DELIVERED' THEN r.customs_channel END,
       CASE WHEN r.status = 'DELIVERED' AND r.customs_required THEN pg_temp.ts_text(r.customs_lodged_at, r.r_format) END,
       CASE WHEN r.status = 'DELIVERED' AND r.customs_required THEN pg_temp.ts_text(r.customs_released_at, r.r_format) END,
       CASE WHEN r.status = 'CANCELLED' THEN '0' ELSE pg_temp.num_text(r.revenue, r.r_format) END,
       CASE WHEN r.status = 'CANCELLED' THEN '0' ELSE pg_temp.num_text(r.cost, r.r_format) END,
       CASE WHEN r.rn % 1511 = 0 THEN 'XXX' ELSE r.currency_code END,
       r.booked_at + interval '2 days'
FROM _raw_shipment r;

-- Stale earlier extracts of the same booking. The ETL must keep only the latest.
INSERT INTO raw.shipment (
    shipment_ref, booked_at, customer_code, carrier_code, origin_code, destination_code, transport_mode,
    incoterm, status, weight_kg, volume_m3, promised_at, revenue, cost, currency_code, extracted_at)
SELECT r.shipment_ref, to_char(r.booked_at, 'YYYY-MM-DD HH24:MI:SS'), r.customer_code, r.carrier_code,
       r.origin_code, r.destination_code, r.transport_mode, r.incoterm, 'BOOKED',
       round(r.weight_kg::numeric, 2)::text, round(r.volume_m3::numeric, 2)::text,
       to_char(r.promised_at, 'YYYY-MM-DD HH24:MI:SS'),
       round((r.revenue * 0.9)::numeric, 2)::text, round(r.cost::numeric, 2)::text, r.currency_code,
       r.booked_at + interval '1 hour'
FROM _raw_shipment r
WHERE r.rn % 67 = 0;
