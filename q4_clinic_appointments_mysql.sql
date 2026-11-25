-- Question 4: Clinic Appointment Scheduling (MySQL 8.0.16+)
-- CHECK constraints are only enforced from 8.0.16, so use 8.0.16 or later.
-- Run in MySQL Workbench or the mysql command line (DELIMITER is a client
-- command). In phpMyAdmin, set the Delimiter box to $$ for the routine blocks.

DROP DATABASE IF EXISTS clinic_db;
CREATE DATABASE clinic_db;
USE clinic_db;

-- =====================================================================
-- (a) DATABASE
-- =====================================================================
CREATE TABLE patients (
    patient_id INT AUTO_INCREMENT PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE doctors (
    doctor_id INT AUTO_INCREMENT PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE appointments (
    appointment_id  INT AUTO_INCREMENT PRIMARY KEY,
    patient_id      INT         NOT NULL,
    doctor_id       INT         NOT NULL,
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT fk_appt_patient FOREIGN KEY (patient_id)
        REFERENCES patients(patient_id),
    CONSTRAINT fk_appt_doctor FOREIGN KEY (doctor_id)
        REFERENCES doctors(doctor_id),
    CONSTRAINT ck_appt_slot CHECK (slot_time IN
        (TIME '09:00:00', TIME '10:00:00', TIME '11:00:00', TIME '12:00:00')),
    CONSTRAINT ck_appt_status CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
) ENGINE=InnoDB;

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL DEFAULT 0,
    attended_count  INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0,
    CONSTRAINT ck_sum_booked    CHECK (booked_count    >= 0),
    CONSTRAINT ck_sum_attended  CHECK (attended_count  >= 0),
    CONSTRAINT ck_sum_cancelled CHECK (cancelled_count >= 0)
) ENGINE=InnoDB;

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION fn_daily_load : non-cancelled appointments for a doctor/day
-- =====================================================================
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_load  INT DEFAULT 0;

    IF p_day IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Day is required';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM doctors WHERE doctor_id = p_doctor_id;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown doctor';
    END IF;

    -- COUNT(*) returns 0 (not NULL) when the day has no bookings
    SELECT COUNT(*) INTO v_load
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_load;
END$$

-- =====================================================================
-- (d) TRIGGERS: reject a clash with another non-cancelled appointment
-- MySQL has no "BEFORE INSERT OR UPDATE" in one trigger, so there are two.
-- The doctor row is locked (FOR UPDATE) first, so two sessions booking the
-- same doctor at the same time are processed one after the other and the
-- second one sees the first one's row.
-- On UPDATE the appointment being changed is excluded from the search.
-- =====================================================================
CREATE TRIGGER trg_appt_bi
BEFORE INSERT ON appointments
FOR EACH ROW
BEGIN
    DECLARE v_lock  INT;
    DECLARE v_clash INT DEFAULT 0;

    IF NEW.status <> 'CANCELLED' THEN
        SELECT COUNT(*) INTO v_lock
        FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

        SELECT COUNT(*) INTO v_clash
        FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED';

        IF v_clash > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Slot already booked for this doctor';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_appt_bu
BEFORE UPDATE ON appointments
FOR EACH ROW
BEGIN
    DECLARE v_lock  INT;
    DECLARE v_clash INT DEFAULT 0;

    IF NEW.status <> 'CANCELLED' THEN
        SELECT COUNT(*) INTO v_lock
        FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

        SELECT COUNT(*) INTO v_clash
        FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
          AND appointment_id <> OLD.appointment_id;   -- exclude itself

        IF v_clash > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Slot already booked for this doctor';
        END IF;
    END IF;
END$$

-- =====================================================================
-- (c) PROCEDURE pr_book_appointment
-- The clash rule itself is enforced by the trigger.
-- =====================================================================
CREATE PROCEDURE pr_book_appointment(
    IN p_patient_id INT,
    IN p_doctor_id  INT,
    IN p_day        DATE,
    IN p_slot       TIME
)
BEGIN
    DECLARE v_count INT DEFAULT 0;

    IF p_patient_id IS NULL OR p_doctor_id IS NULL
       OR p_day IS NULL OR p_slot IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'All booking parameters are required';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM patients WHERE patient_id = p_patient_id;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown patient';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM doctors WHERE doctor_id = p_doctor_id;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown doctor';
    END IF;

    IF p_day < CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot book a date in the past';
    END IF;

    IF p_slot NOT IN (TIME '09:00:00', TIME '10:00:00',
                      TIME '11:00:00', TIME '12:00:00') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unsupported slot: use 09:00, 10:00, 11:00 or 12:00';
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END$$

-- =====================================================================
-- (g) PROCEDURE pr_refresh_clinic_summary
-- Counts are recomputed and the date's row is replaced (set, not added),
-- so a rerun gives the same result.
-- =====================================================================
CREATE PROCEDURE pr_refresh_clinic_summary(IN p_day DATE)
BEGIN
    DECLARE v_booked    INT;
    DECLARE v_attended  INT;
    DECLARE v_cancelled INT;

    IF p_day IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'p_day is required';
    END IF;

    -- SUM over no rows is NULL, so COALESCE gives 0 for an empty day
    SELECT COALESCE(SUM(status = 'BOOKED'),    0),
           COALESCE(SUM(status = 'ATTENDED'),  0),
           COALESCE(SUM(status = 'CANCELLED'), 0)
      INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary
        (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON DUPLICATE KEY UPDATE
        booked_count    = v_booked,
        attended_count  = v_attended,
        cancelled_count = v_cancelled;
END$$

DELIMITER ;

-- =====================================================================
-- SEED DATA (loaded AFTER the triggers exist; dates are relative to today)
-- The cancelled appointment (4) and booked appointment (5) share the same
-- doctor, day and slot: allowed, because cancelled ones do not count.
-- =====================================================================
INSERT INTO patients (full_name) VALUES
 ('Alice Mumba'), ('Brian Lungu'), ('Chipo Daka');

INSERT INTO doctors (full_name) VALUES
 ('Dr. Phiri'), ('Dr. Tembo'), ('Dr. Banda');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 1, CURRENT_DATE - INTERVAL 1 DAY, '09:00:00', 'ATTENDED'),  -- 1
 (2, 2, CURRENT_DATE - INTERVAL 1 DAY, '10:00:00', 'ATTENDED'),  -- 2
 (3, 1, CURRENT_DATE,                  '09:00:00', 'BOOKED'),    -- 3
 (1, 2, CURRENT_DATE,                  '10:00:00', 'CANCELLED'), -- 4
 (2, 2, CURRENT_DATE,                  '10:00:00', 'BOOKED'),    -- 5 reuses slot of 4
 (3, 3, CURRENT_DATE + INTERVAL 1 DAY, '11:00:00', 'BOOKED');    -- 6

-- =====================================================================
-- (e) VIEW: today's BOOKED appointments; only names and slot are exposed
-- (no patient ID, no other patient columns)
-- =====================================================================
CREATE VIEW v_today_appointments AS
SELECT a.slot_time,
       p.full_name AS patient_name,
       d.full_name AS doctor_name
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- =====================================================================
-- (f) INDEX
-- Query: one doctor's appointments on one day.
-- Both columns are searched with equality, so a composite index lets
-- MySQL jump straight to those rows instead of scanning the table.
-- appointment_day comes first so the same index also serves "all doctors
-- on a day" and day-range searches (for example the daily summary); the
-- foreign key's automatic index on doctor_id alone cannot do this. The
-- clash check in the triggers and fn_daily_load use this index too.
-- It is deliberately NOT unique: cancelled appointments may repeat the
-- same doctor, day and slot.
-- =====================================================================
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 2;
-- Expected: key = idx_appt_day_doctor, type = ref.
-- On a tiny table the optimizer may choose a full scan; to show the plan
-- it would use on a large table:
EXPLAIN
SELECT appointment_id, slot_time, status
FROM appointments FORCE INDEX (idx_appt_day_doctor)
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 2;

-- =====================================================================
-- (g) SCHEDULED JOB: daily at 01:00 for the previous day
-- =====================================================================
SET GLOBAL event_scheduler = ON;   -- needs SUPER / SYSTEM_VARIABLES_ADMIN;
                                   -- skip if refused and ask for it to be enabled

CREATE EVENT ev_daily_clinic_summary
ON SCHEDULE EVERY 1 DAY
STARTS '2026-11-26 01:00:00'
DO CALL pr_refresh_clinic_summary(DATE_SUB(CURRENT_DATE, INTERVAL 1 DAY));

-- Inspect the job
SHOW EVENTS FROM clinic_db;
SELECT event_name, status, interval_value, interval_field, starts, last_executed
FROM information_schema.EVENTS
WHERE event_schema = 'clinic_db' AND event_name = 'ev_daily_clinic_summary';

-- =====================================================================
-- TEST SCRIPT
-- =====================================================================
-- Function
SELECT fn_daily_load(1, CURRENT_DATE)                  AS dr1_today,     -- 1
       fn_daily_load(2, CURRENT_DATE)                  AS dr2_today,     -- 1 (cancelled not counted)
       fn_daily_load(3, CURRENT_DATE + INTERVAL 30 DAY) AS empty_day;    -- 0
-- SELECT fn_daily_load(99, CURRENT_DATE);   -- ERROR: Unknown doctor

-- Procedure: valid booking, then the same slot again
CALL pr_book_appointment(1, 1, CURRENT_DATE, '10:00:00');   -- OK
-- CALL pr_book_appointment(2, 1, CURRENT_DATE, '10:00:00');   -- ERROR: slot taken
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - INTERVAL 1 DAY, '11:00:00'); -- ERROR: past
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, '13:00:00');   -- ERROR: unsupported slot
-- CALL pr_book_appointment(99, 1, CURRENT_DATE, '11:00:00');  -- ERROR: unknown patient
-- CALL pr_book_appointment(1, 99, CURRENT_DATE, '11:00:00');  -- ERROR: unknown doctor

-- Direct SQL is checked by the trigger too
-- INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time)
-- VALUES (2, 1, CURRENT_DATE, '09:00:00');                    -- ERROR: clash with 3

-- UPDATE: moving onto an occupied slot is rejected; a free slot is fine;
-- an appointment is not treated as clashing with itself
-- UPDATE appointments SET slot_time = '09:00:00' WHERE appointment_id = 7;  -- ERROR (clash with 3)
UPDATE appointments SET slot_time = '11:00:00' WHERE appointment_id = 7;     -- OK
UPDATE appointments SET status = 'ATTENDED'    WHERE appointment_id = 3;     -- OK (no self-clash)
-- Reviving the cancelled appointment onto a slot now taken by 5 is rejected
-- UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 4;       -- ERROR

-- View: today's BOOKED only (appointments 5 and 7)
SELECT * FROM v_today_appointments;

-- Summary: run twice, the row is replaced, not added to
CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary;   -- booked 2, attended 1, cancelled 1
