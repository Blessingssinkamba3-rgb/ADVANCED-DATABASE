--(a) Database and Seed Data [6 marks]
CREATE TABLE members (
    member_id    SERIAL PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    phone        VARCHAR(30) NOT NULL UNIQUE,
    savings_bal  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (savings_bal >= 0),
    status       VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                 CHECK (status IN ('ACTIVE', 'DEFAULTED', 'SUSPENDED'))
);

CREATE TABLE loans (
    loan_id          SERIAL PRIMARY KEY,
    member_id        INTEGER NOT NULL REFERENCES members(member_id),
    principal        NUMERIC(12, 2) NOT NULL CHECK (principal > 0),
    interest_rate    NUMERIC(5, 2) NOT NULL CHECK (interest_rate >= 0),
    total_repayable  NUMERIC(12, 2) NOT NULL CHECK (total_repayable >= principal),
    amount_repaid    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_repaid >= 0),
    issued_on        DATE NOT NULL DEFAULT CURRENT_DATE,
    due_on           DATE NOT NULL,
    status           VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                     CHECK (status IN ('ACTIVE', 'SETTLED', 'OVERDUE')),
    CONSTRAINT chk_repaid_within_total CHECK (amount_repaid <= total_repayable),
    CONSTRAINT chk_due_after_issue CHECK (due_on > issued_on)
);

CREATE TABLE repayments (
    repayment_id SERIAL PRIMARY KEY,
    loan_id      INTEGER NOT NULL REFERENCES loans(loan_id),
    amount       NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on      DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE loan_audit (
    audit_id   SERIAL PRIMARY KEY,
    loan_id    INTEGER NOT NULL REFERENCES loans(loan_id),
    old_status VARCHAR(20) NOT NULL,
    new_status VARCHAR(20) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed three savings group members
INSERT INTO members (full_name, phone, savings_bal, status) VALUES
    ('Chanda Mwansa',   '+260977300101', 4000.00, 'ACTIVE'),
    ('Mutale Banda',    '+260977300102', 2500.00, 'ACTIVE'),
    ('Thabo Phiri',     '+260977300103', 6000.00, 'ACTIVE');

-- Seed four loans across active, settled, and overdue states
INSERT INTO loans (
    member_id, principal, interest_rate, total_repayable, amount_repaid, issued_on, due_on, status
) VALUES
    (1, 3000.00, 10.00, 3300.00, 0.00, CURRENT_DATE - 30, CURRENT_DATE + 30, 'ACTIVE'),
    (2, 2000.00, 10.00, 2200.00, 0.00, CURRENT_DATE - 75, CURRENT_DATE - 15, 'OVERDUE'),
    (3, 5000.00, 10.00, 5500.00, 0.00, CURRENT_DATE - 20, CURRENT_DATE + 40, 'ACTIVE'),
    (1, 1500.00, 10.00, 1650.00, 0.00, CURRENT_DATE - 90, CURRENT_DATE - 30, 'ACTIVE');


--(b) Function [6 marks]
	CREATE OR REPLACE FUNCTION fn_loan_balance(
    p_loan_id INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total  NUMERIC(12, 2);
    v_repaid NUMERIC(12, 2);
BEGIN
    IF p_loan_id IS NULL THEN
        RAISE EXCEPTION 'p_loan_id cannot be NULL.';
    END IF;

    SELECT total_repayable, amount_repaid
      INTO v_total, v_repaid
      FROM loans
     WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    RETURN ROUND(v_total - v_repaid, 2);
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_record_repayment(
    p_loan_id INTEGER,
    p_amount  NUMERIC(12, 2),
    p_paid_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total      NUMERIC(12, 2);
    v_repaid     NUMERIC(12, 2);
    v_status     VARCHAR(20);
    v_balance    NUMERIC(12, 2);
    v_new_repaid NUMERIC(12, 2);
    v_new_status VARCHAR(20);
BEGIN
    IF p_loan_id IS NULL OR p_amount IS NULL OR p_amount <= 0 OR p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Invalid repayment parameters: loan_id=%, amount=%, paid_on=%',
            p_loan_id, p_amount, p_paid_on;
    END IF;

    -- Lock loan row to serialize concurrent repayments
    SELECT total_repayable, amount_repaid, status
      INTO v_total, v_repaid, v_status
      FROM loans
     WHERE loan_id = p_loan_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist.', p_loan_id;
    END IF;

    IF v_status = 'SETTLED' THEN
        RAISE EXCEPTION 'Loan % is already SETTLED.', p_loan_id;
    END IF;

    v_balance := v_total - v_repaid;

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Overpayment rejected on loan %: repayment % exceeds remaining balance %.',
            p_loan_id, p_amount, v_balance;
    END IF;

    v_new_repaid := v_repaid + p_amount;

    IF v_new_repaid = v_total THEN
        v_new_status := 'SETTLED';
    ELSE
        v_new_status := v_status;
    END IF;

    INSERT INTO repayments (loan_id, amount, paid_on)
    VALUES (p_loan_id, p_amount, p_paid_on);

    UPDATE loans
       SET amount_repaid = v_new_repaid,
           status        = v_new_status
     WHERE loan_id = p_loan_id;
END;
$$;

--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_loans_status_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_has_overdue BOOLEAN;
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO loan_audit (loan_id, old_status, new_status, changed_at)
        VALUES (NEW.loan_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);

        SELECT EXISTS (
            SELECT 1
              FROM loans
             WHERE member_id = NEW.member_id
               AND status = 'OVERDUE'
        ) INTO v_has_overdue;

        UPDATE members
           SET status = CASE
                            WHEN v_has_overdue THEN 'DEFAULTED'
                            ELSE 'ACTIVE'
                        END
         WHERE member_id = NEW.member_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_after_update_status
AFTER UPDATE OF status ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loans_status_audit();

CALL pr_record_repayment(1, 1300.00, CURRENT_DATE - 10); -- partial repayment on Loan 1
CALL pr_record_repayment(2, 700.00,  CURRENT_DATE - 5);  -- partial repayment on overdue Loan 2
CALL pr_record_repayment(3, 5500.00, CURRENT_DATE - 2);  -- settles Loan 3 -> triggers loan_audit
CALL pr_record_repayment(4, 1650.00, CURRENT_DATE - 32); -- settles Loan 4 -> triggers loan_audit

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_open_loans AS
SELECT
    l.loan_id,
    m.member_id,
    m.full_name AS member_name,
    m.phone     AS member_phone,
    m.status    AS member_status,
    l.principal,
    l.interest_rate,
    l.total_repayable,
    l.amount_repaid,
    (l.total_repayable - l.amount_repaid) AS balance_remaining,
    l.issued_on,
    l.due_on,
    l.status    AS loan_status
FROM loans l
JOIN members m
  ON m.member_id = l.member_id
WHERE l.status IN ('ACTIVE', 'OVERDUE');

-- Query open loans ordered by due date
SELECT *
  FROM v_open_loans
 ORDER BY due_on ASC, balance_remaining DESC;


--(f) Index [5 marks]
CREATE INDEX idx_loans_open_due_on
    ON loans (due_on, member_id)
 WHERE status IN ('ACTIVE', 'OVERDUE');

EXPLAIN (ANALYZE, BUFFERS)
SELECT loan_id, member_id, total_repayable, amount_repaid, due_on, status
  FROM loans
 WHERE status IN ('ACTIVE', 'OVERDUE')
   AND due_on < CURRENT_DATE;

--(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_flag_overdue_group_loans(
    p_run_date DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_run_date IS NULL THEN
        RAISE EXCEPTION 'p_run_date cannot be NULL.';
    END IF;

    UPDATE loans
       SET status = 'OVERDUE'
     WHERE status = 'ACTIVE'
       AND due_on < p_run_date
       AND amount_repaid < total_repayable;
END;
$$;

-- Test directly in pgAdmin / psql:
CALL pr_flag_overdue_group_loans(CURRENT_DATE);

-- Schedule daily at 00:15 (requires pg_cron extension):
-- SELECT cron.schedule(
--     'daily_flag_overdue_group_loans',
--     '15 0 * * *',
--     $$CALL pr_flag_overdue_group_loans(CURRENT_DATE);$$
-- );