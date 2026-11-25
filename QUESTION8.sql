---(a) Database and Seed Data [6 marks]
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      NUMERIC(12, 2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12, 2) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_odo_not_exceed_current CHECK (
        last_service_odometer <= current_odometer
    )
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(12, 2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12, 2) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 2) NOT NULL CHECK (km_since_service >= 5000),
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Seed three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ALC 4102', 44200.00, 40000.00), -- 4,200 km since service (will cross 5,000 km after trips)
    ('BBD 8819', 15600.00, 10000.00), -- 5,600 km since service (already due)
    ('CAE 2094', 20500.00, 20000.00); -- 500 km since service (well below threshold)
--(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_service_due(
    p_vehicle_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(12, 2);
    v_last    NUMERIC(12, 2);
BEGIN
    IF p_vehicle_id IS NULL THEN
        RAISE EXCEPTION 'p_vehicle_id cannot be NULL.';
    END IF;

    SELECT current_odometer, last_service_odometer
      INTO v_current, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC(12, 2),
    p_end        NUMERIC(12, 2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_vehicle_id IS NULL OR p_trip_on IS NULL
       OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'All trip parameters (vehicle_id, trip_on, start, end) are required.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must be greater than start_odometer (%).',
            p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_trips_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_odo NUMERIC(12, 2);
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid trip mileage: end_odometer (%) must exceed start_odometer (%).',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    -- Lock vehicle row to serialize sequential odometer updates
    SELECT current_odometer
      INTO v_current_odo
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current_odo THEN
        RAISE EXCEPTION 'Odometer mismatch for vehicle %: trip start (%) does not match current odometer (%).',
            NEW.vehicle_id, NEW.start_odometer, v_current_odo;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_before_insert();

CALL pr_record_trip(1, CURRENT_DATE - 10, 44200.00, 44750.00); -- +550 km -> 44,750 (4,750 since service)
CALL pr_record_trip(1, CURRENT_DATE - 4,  44750.00, 45150.00); -- +400 km -> 45,150 (5,150 since service -> DUE)
CALL pr_record_trip(2, CURRENT_DATE - 7,  15600.00, 15920.00); -- +320 km -> 15,920 (5,920 since service -> DUE)
CALL pr_record_trip(2, CURRENT_DATE - 2,  15920.00, 16180.00); -- +260 km -> 16,180 (6,180 since service -> DUE)
CALL pr_record_trip(3, CURRENT_DATE - 5,  20500.00, 21100.00); -- +600 km -> 21,100 (1,100 since service)
CALL pr_record_trip(3, CURRENT_DATE - 1,  21100.00, 21850.00); -- +750 km -> 21,850 (1,850 since service)

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

-- Query vehicles currently due for service
SELECT *
  FROM v_service_due
 ORDER BY km_since_service DESC;

--(f) Index [5 marks]
CREATE INDEX idx_trips_vehicle_trip_on
    ON trips (vehicle_id, trip_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT trip_id, trip_on, start_odometer, end_odometer
  FROM trips
 WHERE vehicle_id = 1
   AND trip_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

--(g) Scheduled Job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Remove alerts for vehicles that have been serviced and are no longer due
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (
         SELECT 1
           FROM vehicles v
          WHERE v.vehicle_id = sa.vehicle_id
            AND fn_service_due(v.vehicle_id)
     );

    -- Insert or update one alert per currently due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        v.vehicle_id,
        (v.current_odometer - v.last_service_odometer) AS km_since_service,
        CURRENT_DATE
      FROM vehicles v
     WHERE fn_service_due(v.vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service,
           flagged_on       = EXCLUDED.flagged_on;
END;
$$;

-- Test directly in pgAdmin / psql:
CALL pr_refresh_service_alerts();

-- Schedule every Monday at 06:00 (requires pg_cron extension):
-- SELECT cron.schedule(
--     'weekly_fleet_service_alerts',
--     '0 6 * * 1',
--     $$CALL pr_refresh_service_alerts();$$
-- );