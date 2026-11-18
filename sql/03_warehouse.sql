-- Kimball-style star schema. Grain of dw.fact_shipment: one row per booking.

CREATE TABLE dw.dim_date (
    date_key     integer PRIMARY KEY,
    full_date    date NOT NULL UNIQUE,
    year         smallint NOT NULL,
    quarter      smallint NOT NULL,
    month        smallint NOT NULL,
    month_start  date NOT NULL,
    month_name   text NOT NULL,
    iso_week     smallint NOT NULL,
    iso_weekday  smallint NOT NULL,
    weekday_name text NOT NULL,
    is_weekend   boolean NOT NULL
);

INSERT INTO dw.dim_date
SELECT to_char(d, 'YYYYMMDD')::integer, d::date,
       extract(year FROM d), extract(quarter FROM d), extract(month FROM d),
       date_trunc('month', d)::date, trim(to_char(d, 'Month')),
       extract(week FROM d), extract(isodow FROM d), trim(to_char(d, 'Day')),
       extract(isodow FROM d) IN (6, 7)
FROM generate_series(date '2023-01-01', date '2027-12-31', interval '1 day') d;

CREATE TABLE dw.dim_location (
    location_key  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_code text NOT NULL UNIQUE,
    city          text NOT NULL,
    country_code  char(2) NOT NULL,
    country_name  text NOT NULL,
    region        text NOT NULL,
    is_eu         boolean NOT NULL,
    is_seaport    boolean NOT NULL
);

CREATE TABLE dw.dim_carrier (
    carrier_key    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_code   text NOT NULL UNIQUE,
    carrier_name   text NOT NULL,
    transport_mode text NOT NULL CHECK (transport_mode IN ('ROAD', 'RAIL', 'SEA', 'AIR'))
);

-- Type 2 slowly changing dimension. The exclusion constraint makes overlapping
-- versions of one customer impossible; it is deferred so a version can be closed
-- and its successor opened inside a single MERGE.
CREATE TABLE dw.dim_customer (
    customer_key      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_code     text NOT NULL,
    company_name      text NOT NULL,
    country_code      char(2) NOT NULL,
    industry          text NOT NULL,
    tier              char(1) NOT NULL CHECK (tier IN ('A', 'B', 'C')),
    credit_terms_days smallint NOT NULL CHECK (credit_terms_days > 0),
    valid_from        timestamp NOT NULL,
    valid_to          timestamp NOT NULL DEFAULT 'infinity',
    is_current        boolean GENERATED ALWAYS AS (valid_to = 'infinity'::timestamp) STORED,
    UNIQUE (customer_code, valid_from),
    CHECK (valid_from < valid_to),
    CONSTRAINT dim_customer_no_overlap
        EXCLUDE USING gist (customer_code WITH =, tsrange(valid_from, valid_to) WITH &&)
        DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE dw.fact_shipment (
    shipment_key        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_ref        text NOT NULL UNIQUE,
    customer_key        integer NOT NULL REFERENCES dw.dim_customer,
    carrier_key         integer NOT NULL REFERENCES dw.dim_carrier,
    origin_key          integer NOT NULL REFERENCES dw.dim_location,
    destination_key     integer NOT NULL REFERENCES dw.dim_location,
    booked_date_key     integer NOT NULL REFERENCES dw.dim_date,
    delivered_date_key  integer REFERENCES dw.dim_date,
    transport_mode      text NOT NULL,
    incoterm            text NOT NULL,
    status              text NOT NULL CHECK (status IN ('BOOKED', 'IN_TRANSIT', 'DELIVERED', 'CANCELLED')),
    customs_channel     text CHECK (customs_channel IN ('GREEN', 'YELLOW', 'RED')),
    weight_kg           numeric(12, 2) NOT NULL CHECK (weight_kg > 0),
    volume_m3           numeric(12, 2) NOT NULL CHECK (volume_m3 > 0),
    revenue_eur         numeric(14, 2) NOT NULL,
    cost_eur            numeric(14, 2) NOT NULL,
    booked_at           timestamp NOT NULL,
    picked_up_at        timestamp,
    promised_at         timestamp NOT NULL,
    delivered_at        timestamp,
    customs_lodged_at   timestamp,
    customs_released_at timestamp,
    margin_eur    numeric(14, 2) GENERATED ALWAYS AS (revenue_eur - cost_eur) STORED,
    transit_hours numeric(10, 2) GENERATED ALWAYS AS (extract(epoch FROM delivered_at - picked_up_at) / 3600) STORED,
    delay_hours   numeric(10, 2) GENERATED ALWAYS AS (extract(epoch FROM delivered_at - promised_at) / 3600) STORED,
    customs_hours numeric(10, 2) GENERATED ALWAYS AS (extract(epoch FROM customs_released_at - customs_lodged_at) / 3600) STORED,
    is_on_time    boolean GENERATED ALWAYS AS (delivered_at <= promised_at) STORED,
    CHECK (delivered_at IS NULL OR delivered_at >= picked_up_at),
    CHECK (status <> 'DELIVERED' OR delivered_at IS NOT NULL)
);

CREATE INDEX fact_shipment_booked_idx   ON dw.fact_shipment (booked_date_key) INCLUDE (revenue_eur, cost_eur);
CREATE INDEX fact_shipment_customer_idx ON dw.fact_shipment (customer_key, booked_at);
CREATE INDEX fact_shipment_carrier_idx  ON dw.fact_shipment (carrier_key, delivered_date_key) WHERE status = 'DELIVERED';
CREATE INDEX fact_shipment_lane_idx     ON dw.fact_shipment (origin_key, destination_key, transport_mode);
CREATE INDEX fact_shipment_customs_idx  ON dw.fact_shipment (customs_channel, customs_lodged_at) WHERE customs_channel IS NOT NULL;
