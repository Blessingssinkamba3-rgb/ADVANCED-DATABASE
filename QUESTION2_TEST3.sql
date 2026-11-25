--(a) Database and Seed Data [6 marks]
CREATE TABLE students (
    student_id   SERIAL PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    programme    VARCHAR(100) NOT NULL,
    email        VARCHAR(150) NOT NULL UNIQUE
);

CREATE TABLE invoices (
    invoice_id   SERIAL PRIMARY KEY,
    student_id   INTEGER NOT NULL REFERENCES students(student_id),
    semester     VARCHAR(30) NOT NULL,
    amount_due   NUMERIC(12, 2) NOT NULL CHECK (amount_due > 0),
    amount_paid  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0),
    status       VARCHAR(20) NOT NULL DEFAULT 'UNPAID'
                 CHECK (status IN ('UNPAID', 'PARTIAL', 'PAID')),
    CONSTRAINT chk_paid_not_exceed_due CHECK (amount_paid <= amount_due),
    CONSTRAINT uq_student_semester UNIQUE (student_id, semester)
);

CREATE TABLE payments (
    payment_id   SERIAL PRIMARY KEY,
    invoice_id   INTEGER NOT NULL REFERENCES invoices(invoice_id),
    amount       NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on      DATE NOT NULL DEFAULT CURRENT_DATE,
    method       VARCHAR(30) NOT NULL
                 CHECK (method IN ('BANK', 'MOBILE_MONEY', 'CARD', 'CASH'))
);

CREATE TABLE payment_audit (
    audit_id     SERIAL PRIMARY KEY,
    payment_id   INTEGER NOT NULL REFERENCES payments(payment_id),
    invoice_id   INTEGER NOT NULL REFERENCES invoices(invoice_id),
    amount       NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    logged_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed at least three students
INSERT INTO students (full_name, programme, email) VALUES
    ('Chanda Mwansa',   'BSc Computer Science', 'chanda.mwansa@mu.ac.zm'),
    ('Mutale Banda',    'BSc Information Tech', 'mutale.banda@mu.ac.zm'),
    ('Thabo Phiri',     'BSc Data Science',     'thabo.phiri@mu.ac.zm');

-- Seed at least four invoices
INSERT INTO invoices (student_id, semester, amount_due, amount_paid, status) VALUES
    (1, '2026-S1', 8500.00, 0.00, 'UNPAID'),
    (1, '2026-S2', 8500.00, 0.00, 'UNPAID'),
    (2, '2026-S1', 7800.00, 0.00, 'UNPAID'),
    (3, '2026-S1', 9200.00, 0.00, 'UNPAID');
--(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_invoice_balance(
    p_invoice_id INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due  NUMERIC(12, 2);
    v_paid NUMERIC(12, 2);
BEGIN
    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION 'p_invoice_id cannot be NULL.';
    END IF;

    SELECT amount_due, amount_paid
      INTO v_due, v_paid
      FROM invoices
     WHERE invoice_id = p_invoice_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown invoice_id: %', p_invoice_id;
    END IF;

    RETURN ROUND(v_due - v_paid, 2);
END;
$$;
--(c) Procedure [8 marks]	
CREATE OR REPLACE PROCEDURE pr_pay_invoice(
    p_invoice_id INTEGER,
    p_amount     NUMERIC(12, 2),
    p_method     VARCHAR(30),
    p_paid_on    DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due       NUMERIC(12, 2);
    v_paid      NUMERIC(12, 2);
    v_balance   NUMERIC(12, 2);
    v_new_paid  NUMERIC(12, 2);
    v_status    VARCHAR(20);
BEGIN
    IF p_invoice_id IS NULL OR p_amount IS NULL OR p_amount <= 0
       OR p_method IS NULL OR p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Invalid payment parameters: invoice_id=%, amount=%, method=%, paid_on=%',
            p_invoice_id, p_amount, p_method, p_paid_on;
    END IF;

    -- Lock invoice row to prevent concurrent overpayments
    SELECT amount_due, amount_paid
      INTO v_due, v_paid
      FROM invoices
     WHERE invoice_id = p_invoice_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % does not exist.', p_invoice_id;
    END IF;

    v_balance := v_due - v_paid;

    IF v_balance <= 0 THEN
        RAISE EXCEPTION 'Invoice % is already fully PAID.', p_invoice_id;
    END IF;

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Overpayment rejected on invoice %: payment % exceeds remaining balance %.',
            p_invoice_id, p_amount, v_balance;
    END IF;

    v_new_paid := v_paid + p_amount;

    IF v_new_paid = v_due THEN
        v_status := 'PAID';
    ELSE
        v_status := 'PARTIAL';
    END IF;

    -- Insert payment (fires AFTER INSERT trigger on payments)
    INSERT INTO payments (invoice_id, amount, paid_on, method)
    VALUES (p_invoice_id, p_amount, p_paid_on, UPPER(TRIM(p_method)));

    -- Update invoice cumulative total and status
    UPDATE invoices
       SET amount_paid = v_new_paid,
           status      = v_status
     WHERE invoice_id = p_invoice_id;
END;
$$;
--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, invoice_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.invoice_id, NEW.amount, CURRENT_TIMESTAMP);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payments_audit();

CALL pr_pay_invoice(1, 5000.00, 'BANK',         DATE '2026-02-10');
CALL pr_pay_invoice(1, 3500.00, 'MOBILE_MONEY', DATE '2026-03-05'); -- Invoice 1 -> PAID
CALL pr_pay_invoice(3, 4000.00, 'CARD',         DATE '2026-02-14');
CALL pr_pay_invoice(3, 1800.00, 'MOBILE_MONEY', DATE '2026-04-01'); -- Invoice 3 -> PARTIAL
CALL pr_pay_invoice(4, 3000.00, 'CASH',         DATE '2026-03-20'); -- Invoice 4 -> PARTIAL
-- Invoice 2 remains UNPAID

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_unpaid_invoices AS
SELECT
    s.student_id,
    s.full_name,
    s.programme,
    i.invoice_id,
    i.semester,
    i.amount_due,
    i.amount_paid,
    (i.amount_due - i.amount_paid) AS balance_remaining,
    i.status
FROM invoices i
JOIN students s
  ON s.student_id = i.student_id
WHERE i.status IN ('UNPAID', 'PARTIAL');

-- Query showing outstanding student balances
SELECT *
  FROM v_unpaid_invoices
 ORDER BY balance_remaining DESC, full_name ASC;
--(f) Index [5 marks]
CREATE INDEX idx_invoices_student_status
    ON invoices (student_id, status);

EXPLAIN (ANALYZE, BUFFERS)
SELECT invoice_id, semester, amount_due, amount_paid, status
  FROM invoices
 WHERE student_id = 1
   AND status IN ('UNPAID', 'PARTIAL');
--(g) Scheduled Job [6 marks]
CREATE TABLE IF NOT EXISTS overdue_fee_reminders (
    reminder_id   SERIAL PRIMARY KEY,
    invoice_id    INTEGER NOT NULL REFERENCES invoices(invoice_id),
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    balance_due   NUMERIC(12, 2) NOT NULL,
    reminder_date DATE NOT NULL DEFAULT CURRENT_DATE,
    message       TEXT NOT NULL,
    CONSTRAINT uq_invoice_reminder_day UNIQUE (invoice_id, reminder_date)
);

CREATE OR REPLACE PROCEDURE pr_flag_unpaid_reminders(
    p_run_date DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_run_date IS NULL THEN
        RAISE EXCEPTION 'p_run_date cannot be NULL.';
    END IF;

    INSERT INTO overdue_fee_reminders (
        invoice_id, student_id, balance_due, reminder_date, message
    )
    SELECT
        i.invoice_id,
        i.student_id,
        (i.amount_due - i.amount_paid) AS balance_due,
        p_run_date,
        FORMAT(
            'Reminder for %s (%s): Invoice #%s (%s) has an outstanding balance of ZMW %s.',
            s.full_name,
            s.email,
            i.invoice_id,
            i.semester,
            TO_CHAR(i.amount_due - i.amount_paid, 'FM999,999,990.00')
        )
      FROM invoices i
      JOIN students s
        ON s.student_id = i.student_id
     WHERE i.status IN ('UNPAID', 'PARTIAL')
    ON CONFLICT (invoice_id, reminder_date) DO UPDATE
       SET balance_due = EXCLUDED.balance_due,
           message     = EXCLUDED.message;
END;
$$;

-- Schedule weekly every Monday at 08:00 using pg_cron
SELECT cron.schedule(
    'weekly_unpaid_fee_reminders',
    '0 8 * * 1',
    $$CALL pr_flag_unpaid_reminders(CURRENT_DATE);$$
);