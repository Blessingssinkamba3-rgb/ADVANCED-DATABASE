--question (a). Database and seed data [6 marks]. 
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL UNIQUE,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL CHECK (old_qty >= 0),
    new_qty     INTEGER NOT NULL CHECK (new_qty >= 0),
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

-- Seed at least three medicines
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg', 25.00, 40),
    ('Paracetamol 500mg', 10.00, 14),
    ('Ibuprofen 400mg',   18.50, 8);

	
--(b)(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity    INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_medicine_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid medicine_id (%) or quantity (%). Quantity must be positive.',
            p_medicine_id, p_quantity;
    END IF;

    SELECT unit_price
      INTO v_price
      FROM medicines
     WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_stock INTEGER;
BEGIN
    IF p_medicine_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 OR p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Invalid sale parameters: medicine_id=%, quantity=%, sold_on=%',
            p_medicine_id, p_quantity, p_sold_on;
    END IF;

    -- Lock the medicine row to prevent race conditions / overselling
    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM medicines
     WHERE medicine_id = p_medicine_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine % does not exist.', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %.',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    -- Deduct stock once (triggers stock_audit if trigger is active)
    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;

    -- Record sale locking in the current unit price
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
END;
$$;

--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_after_update_stock
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_medicines_stock_audit();

CALL pr_record_sale(1, 5,  CURRENT_DATE - 2);
CALL pr_record_sale(1, 26, CURRENT_DATE - 1); -- drops Amoxicillin from 35 to 9 (< 10)
CALL pr_record_sale(2, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 3,  CURRENT_DATE);
CALL pr_record_sale(3, 2,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 1,  CURRENT_DATE);

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query after sales
SELECT * FROM v_low_stock ORDER BY remaining_stock ASC;

--(f) Index [5 marks]
CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT sale_id, quantity, unit_price, sold_on
  FROM sales
 WHERE medicine_id = 1
   AND sold_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
   --(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day cannot be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT
        p_day AS sales_date,
        COALESCE(SUM(quantity), 0) AS total_qty,
        COALESCE(SUM(quantity * unit_price), 0.00) AS total_amount
      FROM sales
     WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
       SET total_qty    = EXCLUDED.total_qty,
           total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 00:15 for the previous day using pg_cron
SELECT cron.schedule(
    'refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales((CURRENT_DATE - INTERVAL '1 day')::date);$$
);