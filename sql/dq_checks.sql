-- Data-quality checks. Each statement must return ZERO rows when healthy.
-- etl.pl runs these after every load; any returned row is printed and the
-- run exits non-zero. Statements separated by semicolons; -- name: labels them.

-- name: reject_rate_over_5pct
SELECT filename, rows_loaded, rows_rejected
FROM etl_files
WHERE rows_rejected > 0.05 * (rows_loaded + rows_rejected);

-- name: duplicate_events
SELECT ts, ip, path, count(*) AS dupes
FROM log_events
GROUP BY ts, ip, path
HAVING count(*) > 1
LIMIT 10;

-- name: future_timestamps
SELECT id, ts, source_file
FROM log_events
WHERE ts > now() + interval '5 minutes'
LIMIT 10;

-- name: null_paths
SELECT id, ts, source_file
FROM log_events
WHERE path IS NULL
LIMIT 10;
