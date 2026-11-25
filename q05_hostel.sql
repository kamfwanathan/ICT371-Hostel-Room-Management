-- ICT371 Q5: Hostel Room Allocation  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
  CONSTRAINT ck_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL,
  free_beds     INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

-- Concurrency backstop: one ACTIVE allocation per student
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

-- (d) Trigger: capacity and one-active-per-student for direct SQL too
CREATE OR REPLACE FUNCTION trg_check_allocation() RETURNS TRIGGER AS $$
DECLARE
  v_capacity INT;
  v_taken    INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    -- lock the room row to serialise concurrent allocations
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown room_id %', NEW.room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                 AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_taken FROM allocations
    WHERE room_id = NEW.room_id AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM NEW.allocation_id;   -- exclude the row being updated
    IF v_taken >= v_capacity THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocations_check
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_check_allocation();

INSERT INTO students (student_number, full_name) VALUES
  ('S2023001','Mwansa Banda'), ('S2023002','Chanda Phiri'), ('S2023003','Temwani Zulu'),
  ('S2023004','Natasha Mumba'), ('S2023005','Peter Lungu');
INSERT INTO rooms (room_number, capacity) VALUES ('R101',2), ('R102',3), ('R103',2);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT) RETURNS INT AS $$
DECLARE v_capacity INT;
BEGIN
  SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room_id %', p_room_id;
  END IF;
  RETURN v_capacity - (SELECT COUNT(*) FROM allocations
                       WHERE room_id = p_room_id AND status = 'ACTIVE');
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
    RAISE EXCEPTION 'Unknown room_id %', p_room_id;
  END IF;
  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % has no free beds', p_room_id;
  END IF;
  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), NULL, 'ACTIVE');
END;
$$;

-- Seed: R101 full (2/2), R102 partly occupied (1/3), R103 empty (history only)
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 20);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 10);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');   -- history, student 5 unallocated

-- Tests:
-- CALL pr_allocate_room(5, 1, CURRENT_DATE);   -- error: room full
-- CALL pr_allocate_room(1, 2, CURRENT_DATE);   -- error: already active
-- SELECT fn_free_beds(3);                      -- 2 (ended allocation ignored)

-- (e) View: includes rooms with no allocations
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

-- (f) Partial index on ACTIVE rows by room
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
-- Justification: capacity checks and occupancy counts only look at ACTIVE rows; the
-- partial index is small (ENDED history is excluded) and gives a direct lookup by room.
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Snapshot procedure
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, r.room_id,
         COUNT(a.allocation_id)::INT,
         (r.capacity - COUNT(a.allocation_id))::INT
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule('refresh_occupancy_daily', '55 23 * * *',
  $cron$CALL pr_refresh_occupancy()$cron$);

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun replaces values
SELECT * FROM occupancy_snapshot ORDER BY room_id;
