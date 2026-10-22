-- Perl ETL pipeline schema. Run: psql weblogs -f sql/schema.sql

CREATE TABLE IF NOT EXISTS log_events (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts          timestamptz NOT NULL,
    ip          inet,
    method      text,
    path        text,
    status      smallint CHECK (status BETWEEN 100 AND 599),
    bytes       bigint CHECK (bytes >= 0),
    referer     text,
    user_agent  text,
    source_file text NOT NULL
);

CREATE INDEX IF NOT EXISTS log_events_ts_idx ON log_events (ts);

-- Incremental-load bookkeeping: one row per source file, offset of bytes loaded.
CREATE TABLE IF NOT EXISTS etl_files (
    filename      text PRIMARY KEY,
    bytes_done    bigint NOT NULL DEFAULT 0,
    loaded_at     timestamptz NOT NULL DEFAULT now(),
    rows_loaded   bigint NOT NULL DEFAULT 0,
    rows_rejected bigint NOT NULL DEFAULT 0
);

-- Reporting views ------------------------------------------------------------

CREATE OR REPLACE VIEW v_traffic_hourly AS
SELECT date_trunc('hour', ts)          AS hour,
       count(*)                        AS requests,
       sum(bytes)                      AS bytes_sent,
       count(*) FILTER (WHERE status >= 500) AS server_errors,
       count(*) FILTER (WHERE status BETWEEN 400 AND 499) AS client_errors
FROM log_events
GROUP BY 1
ORDER BY 1 DESC;

CREATE OR REPLACE VIEW v_top_paths AS
SELECT path,
       count(*)   AS hits,
       sum(bytes) AS bytes_sent,
       round(100.0 * count(*) FILTER (WHERE status >= 400) / count(*), 1) AS error_pct
FROM log_events
GROUP BY path
ORDER BY hits DESC
LIMIT 25;

CREATE OR REPLACE VIEW v_status_summary AS
SELECT (status / 100) || 'xx' AS status_class,
       count(*)               AS requests,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM log_events
GROUP BY 1
ORDER BY 1;

CREATE OR REPLACE VIEW v_load_history AS
SELECT filename,
       loaded_at,
       bytes_done,
       rows_loaded,
       rows_rejected,
       round(100.0 * rows_rejected / nullif(rows_loaded + rows_rejected, 0), 1) AS reject_pct
FROM etl_files
ORDER BY loaded_at DESC;
