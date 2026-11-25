--(a) Database and Seed Data [6 marks]
CREATE TABLE farmers (
    farmer_id   SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL,
    nrc_number  VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE deliveries (
    delivery_id   SERIAL PRIMARY KEY,
    farmer_id     INTEGER NOT NULL REFERENCES farmers(farmer_id),
    delivered_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    gross_kg      NUMERIC(10, 2) NOT NULL CHECK (gross_kg > 0),
    moisture_pct  NUMERIC(5, 2) NOT NULL CHECK (moisture_pct >= 0 AND moisture_pct <= 100),
    grade         CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    net_kg        NUMERIC(10, 2) NOT NULL CHECK (net_kg >= 0),
    payout_amount NUMERIC(12, 2) NOT NULL CHECK (payout_amount >= 0)
);

CREATE TABLE daily_intake_summary (
    intake_date     DATE PRIMARY KEY,
    total_deliveries INTEGER NOT NULL DEFAULT 0 CHECK (total_deliveries >= 0),
    total_net_kg     NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_net_kg >= 0),
    total_payout     NUMERIC(14, 2) NOT NULL DEFAULT 0.00 CHECK (total_payout >= 0)
);

-- Seed three farmers
INSERT INTO farmers (full_name, nrc_number) VALUES
    ('Mumba Sichone',   '214589/52/1'),
    ('Chilufya Kabwe',  '309812/11/1'),
    ('Zikomo Phiri',    '187643/31/1');


--(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_maize_payout(
    p_net_kg NUMERIC,
    p_grade  CHAR(1)
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate NUMERIC(10, 2);
BEGIN
    IF p_net_kg IS NULL OR p_net_kg < 0 THEN
        RAISE EXCEPTION 'Invalid net_kg (%): must be non-negative and not NULL.', p_net_kg;
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN v_rate := 6.50;
        WHEN 'B' THEN v_rate := 5.80;
        WHEN 'C' THEN v_rate := 5.00;
        ELSE
            RAISE EXCEPTION 'Invalid maize grade (%): must be A, B, or C.', p_grade;
    END CASE;

    RETURN ROUND(p_net_kg * v_rate, 2);
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_record_delivery(
    p_farmer_id    INTEGER,
    p_gross_kg     NUMERIC(10, 2),
    p_moisture_pct NUMERIC(5, 2),
    p_grade        CHAR(1),
    p_delivered_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_excess_moisture NUMERIC(5, 2);
    v_net_kg          NUMERIC(10, 2);
    v_payout          NUMERIC(12, 2);
BEGIN
    IF p_farmer_id IS NULL OR p_gross_kg IS NULL OR p_moisture_pct IS NULL
       OR p_grade IS NULL OR p_delivered_on IS NULL THEN
        RAISE EXCEPTION 'All delivery parameters (farmer_id, gross_kg, moisture_pct, grade, delivered_on) are required.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_gross_kg <= 0 THEN
        RAISE EXCEPTION 'gross_kg (%) must be positive.', p_gross_kg;
    END IF;

    IF p_moisture_pct < 0 OR p_moisture_pct > 15.00 THEN
        RAISE EXCEPTION 'Delivery rejected: moisture % exceeds maximum allowable 15.00%%.', p_moisture_pct;
    END IF;

    -- Deduct 2% weight per percentage point above 12.5% standard moisture
    v_excess_moisture := GREATEST(0.00, p_moisture_pct - 12.50);
    v_net_kg := ROUND(p_gross_kg * (1 - (v_excess_moisture * 0.02)), 2);

    v_payout := fn_maize_payout(v_net_kg, p_grade);

    INSERT INTO deliveries (
        farmer_id, delivered_on, gross_kg, moisture_pct, grade, net_kg, payout_amount
    )
    VALUES (
        p_farmer_id, p_delivered_on, p_gross_kg, p_moisture_pct, UPPER(TRIM(p_grade)), v_net_kg, v_payout
    );
END;
$$;
--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_deliveries_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.moisture_pct > 15.00 THEN
        RAISE EXCEPTION 'Trigger violation: moisture_pct (%) exceeds maximum 15.00%% threshold.',
            NEW.moisture_pct;
    END IF;

    IF NEW.net_kg > NEW.gross_kg THEN
        RAISE EXCEPTION 'Trigger violation: net_kg (%) cannot exceed gross_kg (%).',
            NEW.net_kg, NEW.gross_kg;
    END IF;

    NEW.grade := UPPER(TRIM(NEW.grade));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_before_ins_upd
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_deliveries_validate();

CALL pr_record_delivery(1, 1000.00, 12.00, 'A', CURRENT_DATE - 2); -- 0% shrinkage -> 1000.00 kg @ K6.50 = K6,500.00
CALL pr_record_delivery(2, 800.00,  13.50, 'A', CURRENT_DATE - 2); -- 2% shrinkage -> 784.00 kg  @ K6.50 = K5,096.00
CALL pr_record_delivery(3, 1200.00, 14.50, 'B', CURRENT_DATE - 1); -- 4% shrinkage -> 1152.00 kg @ K5.80 = K6,681.60
CALL pr_record_delivery(1, 650.00,  11.80, 'B', CURRENT_DATE - 1); -- 0% shrinkage -> 650.00 kg  @ K5.80 = K3,770.00
CALL pr_record_delivery(2, 950.00,  15.00, 'C', CURRENT_DATE);     -- 5% shrinkage -> 902.50 kg  @ K5.00 = K4,512.50
CALL pr_record_delivery(3, 500.00,  12.50, 'A', CURRENT_DATE);     -- 0% shrinkage -> 500.00 kg  @ K6.50 = K3,250.00

--(e) View [5 marks]

CREATE OR REPLACE VIEW v_farmer_payouts AS
SELECT
    f.farmer_id,
    f.full_name,
    f.nrc_number,
    COUNT(d.delivery_id)           AS delivery_count,
    COALESCE(SUM(d.gross_kg), 0)   AS total_gross_kg,
    COALESCE(SUM(d.net_kg), 0)     AS total_net_kg,
    COALESCE(SUM(d.payout_amount), 0.00) AS total_payout
FROM farmers f
LEFT JOIN deliveries d
  ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.full_name, f.nrc_number;

-- Query farmer payout totals
SELECT *
  FROM v_farmer_payouts
 ORDER BY total_payout DESC, full_name ASC;

--(f) Index [5 marks]
CREATE INDEX idx_deliveries_farmer_delivered_on
    ON deliveries (farmer_id, delivered_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT delivery_id, delivered_on, gross_kg, moisture_pct, grade, net_kg, payout_amount
  FROM deliveries
 WHERE farmer_id = 1
   AND delivered_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

--(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_daily_intake(
    p_day DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day cannot be NULL.';
    END IF;

    INSERT INTO daily_intake_summary (
        intake_date, total_deliveries, total_net_kg, total_payout
    )
    SELECT
        p_day,
        COUNT(*)::integer,
        COALESCE(SUM(net_kg), 0.00),
        COALESCE(SUM(payout_amount), 0.00)
      FROM deliveries
     WHERE delivered_on = p_day
    ON CONFLICT (intake_date) DO UPDATE
       SET total_deliveries = EXCLUDED.total_deliveries,
           total_net_kg     = EXCLUDED.total_net_kg,
           total_payout     = EXCLUDED.total_payout;
END;
$$;

-- Test directly in pgAdmin / psql:
CALL pr_refresh_daily_intake(CURRENT_DATE);

-- Schedule daily at 18:30 after depot closing (requires pg_cron extension):
-- SELECT cron.schedule(
--     'daily_maize_intake_summary',
--     '30 18 * * *',
--     $$CALL pr_refresh_daily_intake(CURRENT_DATE);$$
-- );