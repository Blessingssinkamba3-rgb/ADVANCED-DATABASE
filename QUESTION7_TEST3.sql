--(a) Database and Seed Data [6 marks]
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10, 2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_customer_reading_month UNIQUE (customer_id, reading_month),
    CONSTRAINT chk_reading_month_start CHECK (
        reading_month = DATE_TRUNC('month', reading_month)::date
    )
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0),
    due_on      DATE NOT NULL,
    CONSTRAINT chk_paid_within_charge CHECK (amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14, 2) NOT NULL DEFAULT 0.00 CHECK (total_due >= 0)
);

-- Seed three customers
INSERT INTO customers (full_name) VALUES
    ('Chanda Mwansa'),
    ('Mutale Banda'),
    ('Thabo Phiri');

--(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_water_charge(
    p_units NUMERIC
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption units (%): must be non-negative and not NULL.', p_units;
    END IF;

    IF p_units = 0 THEN
        v_charge := 0.00;
    ELSIF p_units <= 10 THEN
        v_charge := p_units * 5.00;
    ELSE
        v_charge := (10 * 5.00) + ((p_units - 10) * 8.00);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(10, 2);
    v_curr   NUMERIC(10, 2);
    v_units  NUMERIC(10, 2);
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_reading_id IS NULL OR p_due_on IS NULL THEN
        RAISE EXCEPTION 'p_reading_id and p_due_on cannot be NULL.';
    END IF;

    -- Lock the reading row to prevent duplicate bill generation
    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a generated bill.', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_validate_meter_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Invalid meter reading: current_reading (%) cannot be less than previous_reading (%).',
            NEW.current_reading, NEW.previous_reading;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_before_ins_upd
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_validate_meter_reading();

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-10-01', 100.00, 100.00), -- 0 units  -> K0.00
    (2, DATE '2026-10-01', 250.00, 260.00), -- 10 units -> K50.00
    (3, DATE '2026-10-01', 400.00, 418.00), -- 18 units -> K50 + K64 = K114.00
    (1, DATE '2026-11-01', 100.00, 110.00), -- 10 units -> K50.00
    (2, DATE '2026-11-01', 260.00, 275.00), -- 15 units -> K50 + K40 = K90.00
    (3, DATE '2026-11-01', 418.00, 418.00); -- 0 units  -> K0.00

CALL pr_generate_bill(1, CURRENT_DATE - 15);
CALL pr_generate_bill(2, CURRENT_DATE - 15);
CALL pr_generate_bill(3, CURRENT_DATE - 15);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- Partial payment on bill 2 so it remains overdue with a balance of K20.00
UPDATE bills SET amount_paid = 30.00 WHERE bill_id = 2;

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings  r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- Query overdue bills
SELECT *
  FROM v_overdue_bills
 ORDER BY due_on ASC, outstanding_amount DESC;

--(f) Index [5 marks] 
CREATE INDEX idx_bills_unpaid_due_on
    ON bills (due_on)
 WHERE amount_paid < charge;

EXPLAIN (ANALYZE, BUFFERS)
SELECT bill_id, reading_id, charge, amount_paid, due_on
  FROM bills
 WHERE amount_paid < charge
   AND due_on < CURRENT_DATE;

--(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT
        CURRENT_DATE,
        COALESCE(SUM(charge - amount_paid), 0.00)
      FROM bills
     WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
       SET total_due = EXCLUDED.total_due;
END;
$$;

-- Schedule daily at 00:30 using pg_cron
SELECT cron.schedule(
    'daily_water_receivables_snapshot',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);

CREATE EXTENSION IF NOT EXISTS pg_cron;