--(a) Database and Seed Data [6 marks]
CREATE TABLE members (
    member_id   SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL,
    email       VARCHAR(150) NOT NULL UNIQUE,
    status      VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                CHECK (status IN ('ACTIVE', 'SUSPENDED'))
);

CREATE TABLE books (
    book_id          SERIAL PRIMARY KEY,
    isbn             VARCHAR(20) NOT NULL UNIQUE,
    title            VARCHAR(200) NOT NULL,
    total_copies     INTEGER NOT NULL CHECK (total_copies > 0),
    available_copies INTEGER NOT NULL CHECK (available_copies >= 0),
    CONSTRAINT chk_copies_bounds CHECK (available_copies <= total_copies)
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    member_id     INTEGER NOT NULL REFERENCES members(member_id),
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrowed_on   DATE NOT NULL DEFAULT CURRENT_DATE,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'BORROWED'
                  CHECK (status IN ('BORROWED', 'RETURNED', 'OVERDUE')),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE fines (
    fine_id     SERIAL PRIMARY KEY,
    loan_id     INTEGER NOT NULL UNIQUE REFERENCES loans(loan_id),
    member_id   INTEGER NOT NULL REFERENCES members(member_id),
    days_late   INTEGER NOT NULL CHECK (days_late > 0),
    fine_amount NUMERIC(10, 2) NOT NULL CHECK (fine_amount > 0),
    paid        BOOLEAN NOT NULL DEFAULT FALSE,
    assessed_on DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Seed at least three members
INSERT INTO members (full_name, email, status) VALUES
    ('Bwalya Tembo',     'bwalya.tembo@library.zm',  'ACTIVE'),
    ('Kabwe Lungu',      'kabwe.lungu@library.zm',   'ACTIVE'),
    ('Natasha Zulu',     'natasha.zulu@library.zm',  'ACTIVE');

-- Seed at least four books
INSERT INTO books (isbn, title, total_copies, available_copies) VALUES
    ('978-0134685991', 'Effective Java',                     4, 3),
    ('978-0262033848', 'Introduction to Algorithms',         3, 1),
    ('978-1491950357', 'Designing Data-Intensive Applications', 5, 4),
    ('978-0132350884', 'Clean Code',                         2, 1);

-- Seed loans (mix of active, overdue unreturned, and ready-to-return loans)
INSERT INTO loans (member_id, book_id, borrowed_on, due_on, returned_on, status) VALUES
    (1, 1, CURRENT_DATE - 20, CURRENT_DATE - 6,  NULL, 'OVERDUE'),   -- 6 days late
    (1, 2, CURRENT_DATE - 10, CURRENT_DATE + 4,  NULL, 'BORROWED'),  -- on time, still out
    (2, 2, CURRENT_DATE - 25, CURRENT_DATE - 11, NULL, 'OVERDUE'),   -- 11 days late
    (2, 3, CURRENT_DATE - 5,  CURRENT_DATE + 9,  NULL, 'BORROWED'),  -- on time, still out
    (3, 4, CURRENT_DATE - 18, CURRENT_DATE - 4,  NULL, 'OVERDUE');   -- 4 days late

--(b) Function [6 marks]
	CREATE OR REPLACE FUNCTION fn_calculate_fine(
    p_due_on      DATE,
    p_returned_on DATE DEFAULT CURRENT_DATE,
    p_daily_rate  NUMERIC(10, 2) DEFAULT 5.00
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_days_late INTEGER;
BEGIN
    IF p_due_on IS NULL OR p_returned_on IS NULL THEN
        RAISE EXCEPTION 'p_due_on and p_returned_on cannot be NULL.';
    END IF;

    IF p_daily_rate IS NULL OR p_daily_rate <= 0 THEN
        RAISE EXCEPTION 'p_daily_rate must be positive (got %).', p_daily_rate;
    END IF;

    v_days_late := GREATEST(0, p_returned_on - p_due_on);

    RETURN ROUND(v_days_late * p_daily_rate, 2);
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_return_book(
    p_loan_id     INTEGER,
    p_returned_on DATE DEFAULT CURRENT_DATE,
    p_daily_rate  NUMERIC(10, 2) DEFAULT 5.00
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_member_id   INTEGER;
    v_book_id     INTEGER;
    v_borrowed_on DATE;
    v_due_on      DATE;
    v_status      VARCHAR(20);
    v_days_late   INTEGER;
    v_fine_amt    NUMERIC(10, 2);
BEGIN
    IF p_loan_id IS NULL OR p_returned_on IS NULL THEN
        RAISE EXCEPTION 'p_loan_id and p_returned_on cannot be NULL.';
    END IF;

    -- Lock loan row to prevent duplicate return processing
    SELECT member_id, book_id, borrowed_on, due_on, status
      INTO v_member_id, v_book_id, v_borrowed_on, v_due_on, v_status
      FROM loans
     WHERE loan_id = p_loan_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist.', p_loan_id;
    END IF;

    IF v_status = 'RETURNED' THEN
        RAISE EXCEPTION 'Loan % has already been returned.', p_loan_id;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot precede borrow date (%).',
            p_returned_on, v_borrowed_on;
    END IF;

    -- Mark loan as returned
    UPDATE loans
       SET returned_on = p_returned_on,
           status      = 'RETURNED'
     WHERE loan_id = p_loan_id;

    -- Increment available copies safely
    UPDATE books
       SET available_copies = available_copies + 1
     WHERE book_id = v_book_id;

    -- Assess overdue fine if returned after due date
    v_days_late := GREATEST(0, p_returned_on - v_due_on);

    IF v_days_late > 0 THEN
        v_fine_amt := fn_calculate_fine(v_due_on, p_returned_on, p_daily_rate);

        INSERT INTO fines (loan_id, member_id, days_late, fine_amount, paid, assessed_on)
        VALUES (p_loan_id, v_member_id, v_days_late, v_fine_amt, FALSE, p_returned_on)
        ON CONFLICT (loan_id) DO UPDATE
           SET days_late   = EXCLUDED.days_late,
               fine_amount = EXCLUDED.fine_amount,
               assessed_on = EXCLUDED.assessed_on;
    END IF;
END;
$$;
--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_fines_sync_member_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_member_id    INTEGER;
    v_unpaid_total NUMERIC(12, 2);
BEGIN
    v_member_id := COALESCE(NEW.member_id, OLD.member_id);

    SELECT COALESCE(SUM(fine_amount), 0.00)
      INTO v_unpaid_total
      FROM fines
     WHERE member_id = v_member_id
       AND paid = FALSE;

    UPDATE members
       SET status = CASE
                        WHEN v_unpaid_total > 0 THEN 'SUSPENDED'
                        ELSE 'ACTIVE'
                    END
     WHERE member_id = v_member_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_fines_after_change
AFTER INSERT OR UPDATE OF paid, fine_amount OR DELETE ON fines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_fines_sync_member_status();

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    m.member_id,
    m.full_name AS member_name,
    m.email     AS member_email,
    m.status    AS member_status,
    b.book_id,
    b.isbn,
    b.title     AS book_title,
    l.borrowed_on,
    l.due_on,
    (CURRENT_DATE - l.due_on) AS days_overdue,
    fn_calculate_fine(l.due_on, CURRENT_DATE) AS accrued_fine
FROM loans l
JOIN members m ON m.member_id = l.member_id
JOIN books   b ON b.book_id   = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- Query active overdue items
SELECT *
  FROM v_overdue_loans
 ORDER BY days_overdue DESC, member_name ASC;
--Conversation with Gemini
lets solve these question
This ICT371 Advanced Database exam/assignment document (Last one ICT371.pdf) has 10 questions (50 marks each, 500 marks total), and each question follows a consistent 7-part structure:

(a) Database & Seed Data [6 marks] — Tables, keys, constraints, and sample rows.

(b) Function [6 marks] — Business rule / calculation returning a value with input validation.

(c) Procedure [8 marks] — Transactional workflow enforcing rules and atomic updates.

(d) Trigger [8 marks] — Automated row-level or statement-level validation/auditing.

(e) View [5 marks] — Filtered/joined reporting query.

(f) Index [5 marks] — Performance index + matching query + EXPLAIN plan + justification.

(g) Scheduled Job [6 marks] — Idempotent refresh/batch procedure + scheduling setup.

Because there are 10 full questions, tackling them one or two questions at a time (using PostgreSQL / PL/pgSQL syntax, matching standard relational and pg_cron patterns) will keep the SQL clean, complete, and easy to test.

Complete Solution — Question 1: Pharmacy Stock and Daily Sales
(a) Database and Seed Data [6 marks]
SQL
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
(Valid sales are inserted via pr_record_sale in part (c) after creating the function, procedure, and trigger.)

(b) Function [6 marks]
SQL
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
(c) Procedure [8 marks]
SQL
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
(d) Trigger [8 marks]
SQL
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
Now load at least six valid sales through pr_record_sale to complete the seed data from (a):

SQL
CALL pr_record_sale(1, 5,  CURRENT_DATE - 2);
CALL pr_record_sale(1, 26, CURRENT_DATE - 1); -- drops Amoxicillin from 35 to 9 (< 10)
CALL pr_record_sale(2, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 3,  CURRENT_DATE);
CALL pr_record_sale(3, 2,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 1,  CURRENT_DATE);
(e) View [5 marks]
SQL
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
(f) Index [5 marks]
SQL
CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT sale_id, quantity, unit_price, sold_on
  FROM sales
 WHERE medicine_id = 1
   AND sold_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
Justification: Leading with medicine_id narrows rows to a single medicine via an equality lookup, and sold_on as the second column allows a bounded range scan within that medicine's entries in B-tree order without sorting or scanning unrelated medicines or dates.

(g) Scheduled Job [6 marks]
SQL
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
Idempotency: Using INSERT ... ON CONFLICT (sales_date) DO UPDATE overwrites total_qty and total_amount with the freshly aggregated values for p_day, so rerunning the procedure never duplicates rows or adds to prior totals.

Solve Question 2 University Fee Payments with SQL tables, seed data, function, procedure, trigger, view, index, and scheduled job.
Here is the complete PostgreSQL / PL/pgSQL solution for Question 2: University Fee Payments.

Complete Solution — Question 2: University Fee Payments
(a) Database and Seed Data [6 marks]
SQL
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
(Valid payments are recorded via pr_pay_invoice in part (c) once the procedure and trigger are created.)

(b) Function [6 marks]
SQL
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
(c) Procedure [8 marks]
SQL
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
(d) Trigger [8 marks]
SQL
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
Now record at least five valid payments through pr_pay_invoice so the invoices span UNPAID, PARTIAL, and PAID states:

SQL
CALL pr_pay_invoice(1, 5000.00, 'BANK',         DATE '2026-02-10');
CALL pr_pay_invoice(1, 3500.00, 'MOBILE_MONEY', DATE '2026-03-05'); -- Invoice 1 -> PAID
CALL pr_pay_invoice(3, 4000.00, 'CARD',         DATE '2026-02-14');
CALL pr_pay_invoice(3, 1800.00, 'MOBILE_MONEY', DATE '2026-04-01'); -- Invoice 3 -> PARTIAL
CALL pr_pay_invoice(4, 3000.00, 'CASH',         DATE '2026-03-20'); -- Invoice 4 -> PARTIAL
-- Invoice 2 remains UNPAID
(e) View [5 marks]
SQL
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
(f) Index [5 marks]
SQL
CREATE INDEX idx_invoices_student_status
    ON invoices (student_id, status);

EXPLAIN (ANALYZE, BUFFERS)
SELECT invoice_id, semester, amount_due, amount_paid, status
  FROM invoices
 WHERE student_id = 1
   AND status IN ('UNPAID', 'PARTIAL');
Justification: Placing student_id first filters directly to a single student's invoices via an equality match, and status as the second column allows the B-tree index to locate only open (UNPAID or PARTIAL) invoices for that student without scanning paid invoices or unrelated student rows.

(g) Scheduled Job [6 marks]
SQL
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
Idempotency: The composite unique constraint (invoice_id, reminder_date) paired with ON CONFLICT (invoice_id, reminder_date) DO UPDATE ensures that if the job is manually re-executed on the same day, existing reminder records are updated in place rather than generating duplicate notifications.

Solve Question 3 Library Returns and Overdue Fines with SQL tables, seed data, function, procedure, trigger, view, index, and scheduled job.
Here is the complete PostgreSQL / PL/pgSQL solution for Question 3: Library Returns and Overdue Fines.

Complete Solution — Question 3: Library Returns and Overdue Fines
(a) Database and Seed Data [6 marks]
SQL
CREATE TABLE members (
    member_id   SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL,
    email       VARCHAR(150) NOT NULL UNIQUE,
    status      VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                CHECK (status IN ('ACTIVE', 'SUSPENDED'))
);

CREATE TABLE books (
    book_id          SERIAL PRIMARY KEY,
    isbn             VARCHAR(20) NOT NULL UNIQUE,
    title            VARCHAR(200) NOT NULL,
    total_copies     INTEGER NOT NULL CHECK (total_copies > 0),
    available_copies INTEGER NOT NULL CHECK (available_copies >= 0),
    CONSTRAINT chk_copies_bounds CHECK (available_copies <= total_copies)
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    member_id     INTEGER NOT NULL REFERENCES members(member_id),
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrowed_on   DATE NOT NULL DEFAULT CURRENT_DATE,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'BORROWED'
                  CHECK (status IN ('BORROWED', 'RETURNED', 'OVERDUE')),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE fines (
    fine_id     SERIAL PRIMARY KEY,
    loan_id     INTEGER NOT NULL UNIQUE REFERENCES loans(loan_id),
    member_id   INTEGER NOT NULL REFERENCES members(member_id),
    days_late   INTEGER NOT NULL CHECK (days_late > 0),
    fine_amount NUMERIC(10, 2) NOT NULL CHECK (fine_amount > 0),
    paid        BOOLEAN NOT NULL DEFAULT FALSE,
    assessed_on DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Seed at least three members
INSERT INTO members (full_name, email, status) VALUES
    ('Bwalya Tembo',     'bwalya.tembo@library.zm',  'ACTIVE'),
    ('Kabwe Lungu',      'kabwe.lungu@library.zm',   'ACTIVE'),
    ('Natasha Zulu',     'natasha.zulu@library.zm',  'ACTIVE');

-- Seed at least four books
INSERT INTO books (isbn, title, total_copies, available_copies) VALUES
    ('978-0134685991', 'Effective Java',                     4, 3),
    ('978-0262033848', 'Introduction to Algorithms',         3, 1),
    ('978-1491950357', 'Designing Data-Intensive Applications', 5, 4),
    ('978-0132350884', 'Clean Code',                         2, 1);

-- Seed loans (mix of active, overdue unreturned, and ready-to-return loans)
INSERT INTO loans (member_id, book_id, borrowed_on, due_on, returned_on, status) VALUES
    (1, 1, CURRENT_DATE - 20, CURRENT_DATE - 6,  NULL, 'OVERDUE'),   -- 6 days late
    (1, 2, CURRENT_DATE - 10, CURRENT_DATE + 4,  NULL, 'BORROWED'),  -- on time, still out
    (2, 2, CURRENT_DATE - 25, CURRENT_DATE - 11, NULL, 'OVERDUE'),   -- 11 days late
    (2, 3, CURRENT_DATE - 5,  CURRENT_DATE + 9,  NULL, 'BORROWED'),  -- on time, still out
    (3, 4, CURRENT_DATE - 18, CURRENT_DATE - 4,  NULL, 'OVERDUE');   -- 4 days late
(b) Function [6 marks]
Calculates the overdue fine at a configurable daily rate (defaulting to 5.00 per day) based on the due date and return date (defaulting to CURRENT_DATE if still unreturned):

SQL
CREATE OR REPLACE FUNCTION fn_calculate_fine(
    p_due_on      DATE,
    p_returned_on DATE DEFAULT CURRENT_DATE,
    p_daily_rate  NUMERIC(10, 2) DEFAULT 5.00
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_days_late INTEGER;
BEGIN
    IF p_due_on IS NULL OR p_returned_on IS NULL THEN
        RAISE EXCEPTION 'p_due_on and p_returned_on cannot be NULL.';
    END IF;

    IF p_daily_rate IS NULL OR p_daily_rate <= 0 THEN
        RAISE EXCEPTION 'p_daily_rate must be positive (got %).', p_daily_rate;
    END IF;

    v_days_late := GREATEST(0, p_returned_on - p_due_on);

    RETURN ROUND(v_days_late * p_daily_rate, 2);
END;
$$;
(c) Procedure [8 marks]
Processes a book return atomically: validates that the loan exists and is not already returned, records returned_on, updates loans.status to 'RETURNED', restores books.available_copies (preventing it from exceeding total_copies), and inserts a fine record if returned past due_on:

SQL
CREATE OR REPLACE PROCEDURE pr_return_book(
    p_loan_id     INTEGER,
    p_returned_on DATE DEFAULT CURRENT_DATE,
    p_daily_rate  NUMERIC(10, 2) DEFAULT 5.00
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_member_id   INTEGER;
    v_book_id     INTEGER;
    v_borrowed_on DATE;
    v_due_on      DATE;
    v_status      VARCHAR(20);
    v_days_late   INTEGER;
    v_fine_amt    NUMERIC(10, 2);
BEGIN
    IF p_loan_id IS NULL OR p_returned_on IS NULL THEN
        RAISE EXCEPTION 'p_loan_id and p_returned_on cannot be NULL.';
    END IF;

    -- Lock loan row to prevent duplicate return processing
    SELECT member_id, book_id, borrowed_on, due_on, status
      INTO v_member_id, v_book_id, v_borrowed_on, v_due_on, v_status
      FROM loans
     WHERE loan_id = p_loan_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist.', p_loan_id;
    END IF;

    IF v_status = 'RETURNED' THEN
        RAISE EXCEPTION 'Loan % has already been returned.', p_loan_id;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot precede borrow date (%).',
            p_returned_on, v_borrowed_on;
    END IF;

    -- Mark loan as returned
    UPDATE loans
       SET returned_on = p_returned_on,
           status      = 'RETURNED'
     WHERE loan_id = p_loan_id;

    -- Increment available copies safely
    UPDATE books
       SET available_copies = available_copies + 1
     WHERE book_id = v_book_id;

    -- Assess overdue fine if returned after due date
    v_days_late := GREATEST(0, p_returned_on - v_due_on);

    IF v_days_late > 0 THEN
        v_fine_amt := fn_calculate_fine(v_due_on, p_returned_on, p_daily_rate);

        INSERT INTO fines (loan_id, member_id, days_late, fine_amount, paid, assessed_on)
        VALUES (p_loan_id, v_member_id, v_days_late, v_fine_amt, FALSE, p_returned_on)
        ON CONFLICT (loan_id) DO UPDATE
           SET days_late   = EXCLUDED.days_late,
               fine_amount = EXCLUDED.fine_amount,
               assessed_on = EXCLUDED.assessed_on;
    END IF;
END;
$$;
(d) Trigger [8 marks]
Automatically suspends a member whenever an unpaid fine is inserted or updated on fines (or when total unpaid fines exceed a threshold, e.g., 20.00), and restores 'ACTIVE' status once all fines are paid:

SQL
CREATE OR REPLACE FUNCTION trg_fn_fines_sync_member_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_member_id    INTEGER;
    v_unpaid_total NUMERIC(12, 2);
BEGIN
    v_member_id := COALESCE(NEW.member_id, OLD.member_id);

    SELECT COALESCE(SUM(fine_amount), 0.00)
      INTO v_unpaid_total
      FROM fines
     WHERE member_id = v_member_id
       AND paid = FALSE;

    UPDATE members
       SET status = CASE
                        WHEN v_unpaid_total > 0 THEN 'SUSPENDED'
                        ELSE 'ACTIVE'
                    END
     WHERE member_id = v_member_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_fines_after_change
AFTER INSERT OR UPDATE OF paid, fine_amount OR DELETE ON fines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_fines_sync_member_status();
Now test returning books through pr_return_book (both overdue and on-time):

SQL
CALL pr_return_book(1, CURRENT_DATE); -- 6 days late -> fine assessed, member 1 SUSPENDED
CALL pr_return_book(4, CURRENT_DATE); -- returned early -> no fine, book copy restored
-- Loans 3 and 5 remain unreturned and overdue
(e) View [5 marks]
Lists all currently overdue loans (unreturned past due_on) along with member details, book title, days overdue, and accrued fine:

SQL
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    m.member_id,
    m.full_name AS member_name,
    m.email     AS member_email,
    m.status    AS member_status,
    b.book_id,
    b.isbn,
    b.title     AS book_title,
    l.borrowed_on,
    l.due_on,
    (CURRENT_DATE - l.due_on) AS days_overdue,
    fn_calculate_fine(l.due_on, CURRENT_DATE) AS accrued_fine
FROM loans l
JOIN members m ON m.member_id = l.member_id
JOIN books   b ON b.book_id   = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- Query active overdue items
SELECT *
  FROM v_overdue_loans
 ORDER BY days_overdue DESC, member_name ASC;
--(f) Index [5 marks]
CREATE INDEX idx_loans_active_due_on
    ON loans (due_on, member_id)
 WHERE returned_on IS NULL;

EXPLAIN (ANALYZE, BUFFERS)
SELECT loan_id, member_id, book_id, due_on
  FROM loans
 WHERE returned_on IS NULL
   AND due_on < CURRENT_DATE;
--(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_flag_overdue_loans(
    p_run_date   DATE DEFAULT CURRENT_DATE,
    p_daily_rate NUMERIC(10, 2) DEFAULT 5.00
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_run_date IS NULL THEN
        RAISE EXCEPTION 'p_run_date cannot be NULL.';
    END IF;

    -- Transition newly past-due loans from BORROWED to OVERDUE
    UPDATE loans
       SET status = 'OVERDUE'
     WHERE returned_on IS NULL
       AND due_on < p_run_date
       AND status = 'BORROWED';

    -- Upsert daily fine accruals for all unreturned overdue loans
    INSERT INTO fines (loan_id, member_id, days_late, fine_amount, paid, assessed_on)
    SELECT
        l.loan_id,
        l.member_id,
        (p_run_date - l.due_on) AS days_late,
        fn_calculate_fine(l.due_on, p_run_date, p_daily_rate) AS fine_amount,
        FALSE,
        p_run_date
      FROM loans l
     WHERE l.returned_on IS NULL
       AND l.due_on < p_run_date
    ON CONFLICT (loan_id) DO UPDATE
       SET days_late   = EXCLUDED.days_late,
           fine_amount = EXCLUDED.fine_amount,
           assessed_on = EXCLUDED.assessed_on
     WHERE fines.paid = FALSE;
END;
$$;

-- Schedule daily at 01:00 using pg_cron
SELECT cron.schedule(
    'daily_library_overdue_check',
    '0 1 * * *',
    $$CALL pr_flag_overdue_loans(CURRENT_DATE);$$
);