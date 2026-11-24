DROP VIEW IF EXISTS v_room_occupancy CASCADE;
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables & Seed Data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_dates_status CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE UNIQUE INDEX uq_one_active_allocation_per_student
ON allocations (student_id)
WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL DEFAULT 0 CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL DEFAULT 0 CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('S001', 'Chisomo Lungu'),
    ('S002', 'Mapalo Sakala'),
    ('S003', 'Thandiwe Mumba'),
    ('S004', 'Kabwe Simukonda');

INSERT INTO rooms (room_number, capacity) VALUES
    ('H1-101', 2),
    ('H1-102', 2),
    ('H1-103', 2);

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, '2026-09-01', NULL,         'ACTIVE'),
    (2, 1, '2026-09-01', NULL,         'ACTIVE'),
    (3, 2, '2026-09-02', NULL,         'ACTIVE'),
    (4, 2, '2026-08-01', '2026-08-31', 'ENDED');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - COALESCE(v_active, 0);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations
        WHERE student_id = p_student_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    IF v_active >= v_capacity THEN
        RAISE EXCEPTION 'Room % is at full capacity (%)', p_room_id, v_capacity;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_enforce_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF NEW.released_on IS NOT NULL THEN
            RAISE EXCEPTION 'ACTIVE allocation must have released_on IS NULL';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Student % already has another ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT capacity INTO v_capacity
        FROM rooms WHERE room_id = NEW.room_id;

        SELECT COUNT(*) INTO v_active
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_active + 1 > v_capacity THEN
            RAISE EXCEPTION 'Room % capacity (%) exceeded', NEW.room_id, v_capacity;
        END IF;
    ELSE
        IF NEW.released_on IS NULL THEN
            RAISE EXCEPTION 'ENDED allocation must have a released_on date';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_enforce_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_enforce_allocation_rules();

-- (e) View
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;

-- (f) Index & EXPLAIN
CREATE INDEX idx_allocations_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';

EXPLAIN (ANALYZE, BUFFERS)
SELECT allocation_id, student_id, room_id, allocated_on
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';

-- (g) Refresh Procedure & Schedule
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'),
        r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot;

