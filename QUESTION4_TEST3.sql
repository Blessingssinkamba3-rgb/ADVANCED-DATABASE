--(a) Database and Seed Data [6 marks]
CREATE TABLE doctors (
    doctor_id   SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL,
    specialty   VARCHAR(100) NOT NULL,
    room_no     VARCHAR(20) NOT NULL
);

CREATE TABLE patients (
    patient_id  SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL,
    phone       VARCHAR(30) NOT NULL UNIQUE,
    birth_date  DATE NOT NULL
);

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    doctor_id      INTEGER NOT NULL REFERENCES doctors(doctor_id),
    patient_id     INTEGER NOT NULL REFERENCES patients(patient_id),
    appt_date      DATE NOT NULL,
    slot_time      TIME NOT NULL,
    status         VARCHAR(20) NOT NULL DEFAULT 'BOOKED'
                   CHECK (status IN ('BOOKED', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    CONSTRAINT uq_doctor_date_slot UNIQUE (doctor_id, appt_date, slot_time)
);

CREATE TABLE appointment_audit (
    audit_id       SERIAL PRIMARY KEY,
    appointment_id INTEGER NOT NULL REFERENCES appointments(appointment_id),
    old_status     VARCHAR(20) NOT NULL,
    new_status     VARCHAR(20) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed at least three doctors
INSERT INTO doctors (full_name, specialty, room_no) VALUES
    ('Dr. Mwewa Sakala',   'General Medicine', 'OPD-101'),
    ('Dr. Luyando Chileshe', 'Pediatrics',     'OPD-104'),
    ('Dr. Kondwani Ngoma', 'Cardiology',       'OPD-202');

-- Seed at least four patients
INSERT INTO patients (full_name, phone, birth_date) VALUES
    ('Chisomo Banda',   '+260977111001', DATE '1994-05-12'),
    ('Mapalo Phiri',    '+260977111002', DATE '2016-09-23'),
    ('Bupe Mulenga',    '+260977111003', DATE '1981-02-19'),
    ('Tawanda Moyo',    '+260977111004', DATE '1968-11-30');

--(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_is_slot_available(
    p_doctor_id INTEGER,
    p_appt_date DATE,
    p_slot_time TIME
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_doctor_exists BOOLEAN;
    v_slot_taken    BOOLEAN;
BEGIN
    IF p_doctor_id IS NULL OR p_appt_date IS NULL OR p_slot_time IS NULL THEN
        RAISE EXCEPTION 'p_doctor_id, p_appt_date, and p_slot_time cannot be NULL.';
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM doctors
         WHERE doctor_id = p_doctor_id
    ) INTO v_doctor_exists;

    IF NOT v_doctor_exists THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM appointments
         WHERE doctor_id = p_doctor_id
           AND appt_date = p_appt_date
           AND slot_time = p_slot_time
           AND status IN ('BOOKED', 'COMPLETED')
    ) INTO v_slot_taken;

    RETURN NOT v_slot_taken;
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_doctor_id  INTEGER,
    p_patient_id INTEGER,
    p_appt_date  DATE,
    p_slot_time  TIME
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_patient_exists BOOLEAN;
    v_existing_id    INTEGER;
BEGIN
    IF p_doctor_id IS NULL OR p_patient_id IS NULL
       OR p_appt_date IS NULL OR p_slot_time IS NULL THEN
        RAISE EXCEPTION 'All booking parameters (doctor_id, patient_id, appt_date, slot_time) are required.';
    END IF;

    -- Lock doctor row to serialize concurrent bookings for this doctor
    PERFORM 1
       FROM doctors
      WHERE doctor_id = p_doctor_id
      FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor % does not exist.', p_doctor_id;
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM patients
         WHERE patient_id = p_patient_id
    ) INTO v_patient_exists;

    IF NOT v_patient_exists THEN
        RAISE EXCEPTION 'Patient % does not exist.', p_patient_id;
    END IF;

    IF NOT fn_is_slot_available(p_doctor_id, p_appt_date, p_slot_time) THEN
        RAISE EXCEPTION 'Slot % on % is already booked for doctor %.',
            p_slot_time, p_appt_date, p_doctor_id;
    END IF;

    -- Prevent the same patient from holding two active bookings at the exact same date & time
    IF EXISTS (
        SELECT 1
          FROM appointments
         WHERE patient_id = p_patient_id
           AND appt_date  = p_appt_date
           AND slot_time  = p_slot_time
           AND status IN ('BOOKED', 'COMPLETED')
    ) THEN
        RAISE EXCEPTION 'Patient % already has an appointment at % on %.',
            p_patient_id, p_slot_time, p_appt_date;
    END IF;

    -- If a prior cancelled appointment exists for this exact doctor/date/slot, reuse it; otherwise insert
    SELECT appointment_id
      INTO v_existing_id
      FROM appointments
     WHERE doctor_id = p_doctor_id
       AND appt_date = p_appt_date
       AND slot_time = p_slot_time
       AND status = 'CANCELLED'
     FOR UPDATE;

    IF FOUND THEN
        UPDATE appointments
           SET patient_id = p_patient_id,
               status     = 'BOOKED'
         WHERE appointment_id = v_existing_id;
    ELSE
        INSERT INTO appointments (doctor_id, patient_id, appt_date, slot_time, status)
        VALUES (p_doctor_id, p_patient_id, p_appt_date, p_slot_time, 'BOOKED');
    END IF;
END;
$$;

--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_appointments_status_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO appointment_audit (appointment_id, old_status, new_status, changed_at)
        VALUES (NEW.appointment_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_after_update_status
AFTER UPDATE OF status ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointments_status_audit();

CALL pr_book_appointment(1, 1, CURRENT_DATE,     TIME '09:00');
CALL pr_book_appointment(1, 3, CURRENT_DATE,     TIME '10:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE,     TIME '09:30');
CALL pr_book_appointment(3, 4, CURRENT_DATE,     TIME '11:00');
CALL pr_book_appointment(1, 4, CURRENT_DATE + 1, TIME '09:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE - 1, TIME '14:00');

-- Trigger status changes (fires trg_appointments_after_update_status)
UPDATE appointments SET status = 'COMPLETED' WHERE appointment_id = 1;

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_todays_schedule AS
SELECT
    a.appointment_id,
    a.appt_date,
    a.slot_time,
    a.status,
    d.doctor_id,
    d.full_name AS doctor_name,
    d.specialty,
    d.room_no,
    p.patient_id,
    p.full_name AS patient_name,
    p.phone     AS patient_phone
FROM appointments a
JOIN doctors  d ON d.doctor_id  = a.doctor_id
JOIN patients p ON p.patient_id = a.patient_id
WHERE a.appt_date = CURRENT_DATE
  AND a.status IN ('BOOKED', 'COMPLETED');

-- Query today's outpatient schedule ordered chronologically
SELECT *
  FROM v_todays_schedule
 ORDER BY slot_time ASC, doctor_name ASC;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 2;

--(f) Index [5 marks]
CREATE INDEX idx_appointments_appt_date_status_slot
    ON appointments (appt_date, status, slot_time);

EXPLAIN (ANALYZE, BUFFERS)
SELECT appointment_id, doctor_id, patient_id, slot_time, status
  FROM appointments
 WHERE appt_date = CURRENT_DATE
   AND status IN ('BOOKED', 'COMPLETED')
 ORDER BY slot_time ASC;

--(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_mark_no_shows(
    p_run_date DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_run_date IS NULL THEN
        RAISE EXCEPTION 'p_run_date cannot be NULL.';
    END IF;

    UPDATE appointments
       SET status = 'NO_SHOW'
     WHERE appt_date < p_run_date
       AND status = 'BOOKED';
END;
$$;

-- Schedule daily at 23:30 using pg_cron
SELECT cron.schedule(
    'daily_mark_outpatient_no_shows',
    '30 23 * * *',
    $$CALL pr_mark_no_shows(CURRENT_DATE);$$
);