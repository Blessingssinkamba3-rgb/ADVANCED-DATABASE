--(a) Database and Seed Data [6 marks]
CREATE TABLE guests (
    guest_id   SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL,
    email      VARCHAR(150) NOT NULL UNIQUE,
    phone      VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE rooms (
    room_id      SERIAL PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    room_type    VARCHAR(30) NOT NULL
                 CHECK (room_type IN ('STANDARD', 'DELUXE', 'SUITE')),
    nightly_rate NUMERIC(10, 2) NOT NULL CHECK (nightly_rate > 0),
    status       VARCHAR(20) NOT NULL DEFAULT 'AVAILABLE'
                 CHECK (status IN ('AVAILABLE', 'OCCUPIED', 'MAINTENANCE'))
);

CREATE TABLE reservations (
    reservation_id SERIAL PRIMARY KEY,
    guest_id       INTEGER NOT NULL REFERENCES guests(guest_id),
    room_id        INTEGER NOT NULL REFERENCES rooms(room_id),
    check_in       DATE NOT NULL,
    check_out      DATE NOT NULL,
    total_charge   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_charge >= 0),
    status         VARCHAR(20) NOT NULL DEFAULT 'CONFIRMED'
                   CHECK (status IN ('CONFIRMED', 'CHECKED_IN', 'CHECKED_OUT', 'CANCELLED', 'NO_SHOW')),
    CONSTRAINT chk_checkout_after_checkin CHECK (check_out > check_in)
);

CREATE TABLE reservation_audit (
    audit_id       SERIAL PRIMARY KEY,
    reservation_id INTEGER NOT NULL REFERENCES reservations(reservation_id),
    old_status     VARCHAR(20) NOT NULL,
    new_status     VARCHAR(20) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed at least three guests
INSERT INTO guests (full_name, email, phone) VALUES
    ('Mwape Chanda',    'mwape.chanda@hotel.zm',   '+260966200101'),
    ('Sibusiso Dube',   'sibusiso.dube@hotel.zm',  '+260966200102'),
    ('Kunda Musonda',   'kunda.musonda@hotel.zm',  '+260966200103');

-- Seed at least four rooms
INSERT INTO rooms (room_number, room_type, nightly_rate, status) VALUES
    ('101', 'STANDARD', 950.00,  'AVAILABLE'),
    ('102', 'STANDARD', 950.00,  'AVAILABLE'),
    ('201', 'DELUXE',   1650.00, 'AVAILABLE'),
    ('301', 'SUITE',    2900.00, 'AVAILABLE');


--(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_calculate_stay_charge(
    p_room_id   INTEGER,
    p_check_in  DATE,
    p_check_out DATE
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate   NUMERIC(10, 2);
    v_nights INTEGER;
BEGIN
    IF p_room_id IS NULL OR p_check_in IS NULL OR p_check_out IS NULL THEN
        RAISE EXCEPTION 'p_room_id, p_check_in, and p_check_out cannot be NULL.';
    END IF;

    v_nights := p_check_out - p_check_in;
    IF v_nights <= 0 THEN
        RAISE EXCEPTION 'check_out (%) must be strictly after check_in (%).',
            p_check_out, p_check_in;
    END IF;

    SELECT nightly_rate
      INTO v_rate
      FROM rooms
     WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    -- Base stay cost plus 16% tax
    RETURN ROUND(v_nights * v_rate * 1.16, 2);
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_book_room(
    p_guest_id  INTEGER,
    p_room_id   INTEGER,
    p_check_in  DATE,
    p_check_out DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_room_status VARCHAR(20);
    v_overlap     BOOLEAN;
    v_total       NUMERIC(12, 2);
BEGIN
    IF p_guest_id IS NULL OR p_room_id IS NULL
       OR p_check_in IS NULL OR p_check_out IS NULL THEN
        RAISE EXCEPTION 'All reservation fields (guest_id, room_id, check_in, check_out) are required.';
    END IF;

    IF p_check_out <= p_check_in THEN
        RAISE EXCEPTION 'Invalid stay dates: check_out (%) must be after check_in (%).',
            p_check_out, p_check_in;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM guests WHERE guest_id = p_guest_id) THEN
        RAISE EXCEPTION 'Guest % does not exist.', p_guest_id;
    END IF;

    -- Lock room row to serialize overlapping date checks
    SELECT status
      INTO v_room_status
      FROM rooms
     WHERE room_id = p_room_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist.', p_room_id;
    END IF;

    IF v_room_status = 'MAINTENANCE' THEN
        RAISE EXCEPTION 'Room % is currently under MAINTENANCE and cannot be booked.', p_room_id;
    END IF;

    -- Detect overlapping active reservations: [check_in, check_out) overlaps [p_check_in, p_check_out)
    SELECT EXISTS (
        SELECT 1
          FROM reservations
         WHERE room_id = p_room_id
           AND status IN ('CONFIRMED', 'CHECKED_IN')
           AND check_in  < p_check_out
           AND check_out > p_check_in
    ) INTO v_overlap;

    IF v_overlap THEN
        RAISE EXCEPTION 'Room % is already reserved between % and %.',
            p_room_id, p_check_in, p_check_out;
    END IF;

    v_total := fn_calculate_stay_charge(p_room_id, p_check_in, p_check_out);

    INSERT INTO reservations (guest_id, room_id, check_in, check_out, total_charge, status)
    VALUES (p_guest_id, p_room_id, p_check_in, p_check_out, v_total, 'CONFIRMED');
END;
$$;

--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_reservations_status_sync()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO reservation_audit (reservation_id, old_status, new_status, changed_at)
        VALUES (NEW.reservation_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);

        IF NEW.status = 'CHECKED_IN' THEN
            UPDATE rooms
               SET status = 'OCCUPIED'
             WHERE room_id = NEW.room_id
               AND status <> 'MAINTENANCE';
        ELSIF OLD.status = 'CHECKED_IN' AND NEW.status IN ('CHECKED_OUT', 'CANCELLED') THEN
            UPDATE rooms
               SET status = 'AVAILABLE'
             WHERE room_id = NEW.room_id
               AND status <> 'MAINTENANCE';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reservations_after_update_status
AFTER UPDATE OF status ON reservations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reservations_status_sync();

CALL pr_book_room(1, 1, CURRENT_DATE,     CURRENT_DATE + 3);
CALL pr_book_room(2, 3, CURRENT_DATE,     CURRENT_DATE + 2);
CALL pr_book_room(3, 4, CURRENT_DATE + 1, CURRENT_DATE + 5);
CALL pr_book_room(1, 2, CURRENT_DATE - 2, CURRENT_DATE + 1);
CALL pr_book_room(2, 1, CURRENT_DATE + 4, CURRENT_DATE + 6);

-- Check in reservations 1 and 4 (triggers audit + sets rooms 101 and 102 to OCCUPIED)
UPDATE reservations SET status = 'CHECKED_IN' WHERE reservation_id IN (1, 4);

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_current_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.room_type,
    r.nightly_rate,
    res.reservation_id,
    g.guest_id,
    g.full_name AS guest_name,
    g.phone     AS guest_phone,
    res.check_in,
    res.check_out,
    (res.check_out - CURRENT_DATE) AS nights_remaining,
    res.total_charge
FROM reservations res
JOIN rooms  r ON r.room_id  = res.room_id
JOIN guests g ON g.guest_id = res.guest_id
WHERE res.status = 'CHECKED_IN';

-- Query active in-house guests
SELECT *
  FROM v_current_occupancy
 ORDER BY check_out ASC, room_number ASC;

--(f) Index [5 marks]
CREATE INDEX idx_reservations_room_dates_active
    ON reservations (room_id, check_in, check_out)
 WHERE status IN ('CONFIRMED', 'CHECKED_IN');

EXPLAIN (ANALYZE, BUFFERS)
SELECT reservation_id, guest_id, check_in, check_out, status
  FROM reservations
 WHERE room_id = 1
   AND status IN ('CONFIRMED', 'CHECKED_IN')
   AND check_in  < DATE '2026-12-05'
   AND check_out > DATE '2026-12-01';

--(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_release_no_show_reservations(
    p_run_date DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_run_date IS NULL THEN
        RAISE EXCEPTION 'p_run_date cannot be NULL.';
    END IF;

    UPDATE reservations
       SET status = 'NO_SHOW'
     WHERE status = 'CONFIRMED'
       AND check_in < p_run_date;
END;
$$;

-- Schedule daily at 12:00 noon (after standard check-in cutoff) using pg_cron
SELECT cron.schedule(
    'daily_release_hotel_no_shows',
    '0 12 * * *',
    $$CALL pr_release_no_show_reservations(CURRENT_DATE);$$
);