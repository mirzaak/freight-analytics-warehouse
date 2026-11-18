-- Landing zone. Operational columns stay as TEXT because the source extracts
-- are inconsistent; typing and validation happen in the ETL layer.

CREATE EXTENSION IF NOT EXISTS btree_gist;

DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS dw CASCADE;
DROP SCHEMA IF EXISTS etl CASCADE;
DROP SCHEMA IF EXISTS raw CASCADE;

CREATE SCHEMA raw;
CREATE SCHEMA etl;
CREATE SCHEMA dw;
CREATE SCHEMA mart;

CREATE TABLE raw.location (
    location_code text PRIMARY KEY,
    city          text NOT NULL,
    country_code  text NOT NULL,
    country_name  text NOT NULL,
    region        text NOT NULL,
    is_eu         boolean NOT NULL,
    is_seaport    boolean NOT NULL,
    latitude      numeric(8, 5) NOT NULL,
    longitude     numeric(8, 5) NOT NULL
);

CREATE TABLE raw.carrier (
    carrier_code   text PRIMARY KEY,
    carrier_name   text NOT NULL,
    transport_mode text NOT NULL
);

CREATE TABLE raw.customer (
    raw_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_code     text NOT NULL,
    company_name      text NOT NULL,
    country_code      text NOT NULL,
    industry          text NOT NULL,
    tier              text NOT NULL,
    credit_terms_days text NOT NULL,
    updated_at        timestamp NOT NULL
);

CREATE TABLE raw.exchange_rate (
    rate_month    date NOT NULL,
    currency_code text NOT NULL,
    units_per_eur numeric(12, 6) NOT NULL,
    PRIMARY KEY (rate_month, currency_code)
);

CREATE TABLE raw.shipment (
    raw_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_ref        text,
    booked_at           text,
    customer_code       text,
    carrier_code        text,
    origin_code         text,
    destination_code    text,
    transport_mode      text,
    incoterm            text,
    status              text,
    weight_kg           text,
    volume_m3           text,
    picked_up_at        text,
    promised_at         text,
    delivered_at        text,
    customs_channel     text,
    customs_lodged_at   text,
    customs_released_at text,
    revenue             text,
    cost                text,
    currency_code       text,
    extracted_at        timestamp NOT NULL
);

CREATE INDEX raw_shipment_ref_idx ON raw.shipment (shipment_ref, extracted_at DESC);
