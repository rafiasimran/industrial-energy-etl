-- =====================================================================
--  Athena analysis queries
--
--  Queries over the curated table: CTEs, window functions, HAVING
--  and per-machine baselines.
--
--  Run them in the Athena console, workgroup: industrial-energy-etl-<id>
--  Filter on reading_date where you can. Athena charges per byte
--  scanned, and the partition means a date filter skips whole files.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Sanity check. Does the table see the data at all?
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS rows_total,
       MIN(reading_date) AS first_day,
       MAX(reading_date) AS last_day
FROM energy_readings;


-- ---------------------------------------------------------------------
-- 1. Daily energy per plant.
-- ---------------------------------------------------------------------
SELECT reading_date,
       plant,
       ROUND(SUM(energy_kwh), 1) AS total_kwh,
       COUNT(*)                  AS readings
FROM energy_readings
GROUP BY reading_date, plant
ORDER BY reading_date, plant;


-- ---------------------------------------------------------------------
-- 2. 7-day moving average per plant.
--    Read it as: for each row, look at the current row and the 6 rows
--    before it (within the same plant, ordered by date) and average those.
-- ---------------------------------------------------------------------
WITH daily AS (
    SELECT reading_date,
           plant,
           SUM(energy_kwh) AS total_kwh
    FROM energy_readings
    GROUP BY reading_date, plant
)
SELECT reading_date,
       plant,
       ROUND(total_kwh, 1) AS total_kwh,
       ROUND(AVG(total_kwh) OVER (
           PARTITION BY plant
           ORDER BY reading_date
           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
       ), 1) AS moving_avg_7d
FROM daily
ORDER BY plant, reading_date;


-- ---------------------------------------------------------------------
-- 3. Which machines consume the most, ranked within their own plant?
--    RANK() OVER (PARTITION BY ...) gives the top N per group.
-- ---------------------------------------------------------------------
WITH machine_totals AS (
    SELECT plant,
           machine_id,
           SUM(energy_kwh) AS total_kwh
    FROM energy_readings
    GROUP BY plant, machine_id
),
ranked AS (
    SELECT plant,
           machine_id,
           total_kwh,
           RANK() OVER (PARTITION BY plant ORDER BY total_kwh DESC) AS rank_in_plant
    FROM machine_totals
)
SELECT *
FROM ranked
WHERE rank_in_plant <= 3
ORDER BY plant, rank_in_plant;


-- ---------------------------------------------------------------------
-- 4. Load profile by hour of day (shifts show up clearly).
-- ---------------------------------------------------------------------
SELECT reading_hour,
       ROUND(AVG(energy_kwh), 2) AS avg_kwh,
       COUNT(*)                  AS readings
FROM energy_readings
GROUP BY reading_hour
ORDER BY reading_hour;


-- ---------------------------------------------------------------------
-- 5. Anomaly detection: readings more than 3 standard deviations from
--    their own machine's mean. A simple outlier rule.
--
--    Note we compute the mean and stddev per machine with a window
--    function, so each row is compared to its OWN baseline, not a
--    global one. Comparing a small machine to a plant-wide average
--    is how you generate false alarms.
-- ---------------------------------------------------------------------
WITH stats AS (
    SELECT reading_id,
           machine_id,
           plant,
           reading_ts,
           energy_kwh,
           AVG(energy_kwh)    OVER (PARTITION BY machine_id) AS machine_mean,
           STDDEV(energy_kwh) OVER (PARTITION BY machine_id) AS machine_stddev
    FROM energy_readings
)
SELECT reading_id,
       plant,
       machine_id,
       reading_ts,
       ROUND(energy_kwh, 2)  AS energy_kwh,
       ROUND(machine_mean, 2) AS machine_mean,
       ROUND(ABS(energy_kwh - machine_mean) / NULLIF(machine_stddev, 0), 2) AS z_score
FROM stats
WHERE ABS(energy_kwh - machine_mean) > 3 * NULLIF(machine_stddev, 0)
ORDER BY z_score DESC
LIMIT 50;


-- ---------------------------------------------------------------------
-- 6. Peak vs off-peak split per plant, as a percentage.
--    Done with conditional sums, no PIVOT needed.
-- ---------------------------------------------------------------------
SELECT plant,
       ROUND(SUM(CASE WHEN is_peak_hour THEN energy_kwh ELSE 0 END), 1) AS peak_kwh,
       ROUND(SUM(CASE WHEN NOT is_peak_hour THEN energy_kwh ELSE 0 END), 1) AS offpeak_kwh,
       ROUND(100.0 * SUM(CASE WHEN is_peak_hour THEN energy_kwh ELSE 0 END)
             / SUM(energy_kwh), 1) AS peak_share_pct
FROM energy_readings
GROUP BY plant
ORDER BY peak_share_pct DESC;


-- ---------------------------------------------------------------------
-- 7. Machines idling hot: status 'idle' but temperature above average.
--    Possible wasted energy: machines that are idle but still hot.
-- ---------------------------------------------------------------------
SELECT machine_id,
       plant,
       COUNT(*)                       AS idle_readings,
       ROUND(AVG(temperature_c), 1)   AS avg_temp_when_idle,
       ROUND(AVG(energy_kwh), 2)      AS avg_kwh_when_idle
FROM energy_readings
WHERE status = 'idle'
  AND temperature_c IS NOT NULL
GROUP BY machine_id, plant
HAVING AVG(temperature_c) > 55
ORDER BY avg_kwh_when_idle DESC;
