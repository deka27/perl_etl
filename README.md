# perl-etl

Loads nginx/Apache access logs (combined format) into Postgres. Parses and
cleans each line, bulk loads with `COPY`, runs some data quality checks, and
only picks up new lines on each run so it can sit in cron.

## Files

- `etl.pl` - the loader
- `gen_logs.pl` - makes fake log data (`perl gen_logs.pl 500`)
- `sql/schema.sql` - tables and reporting views
- `sql/dq_checks.sql` - data quality queries, each should return 0 rows
- `t/etl.t` - test
- `logs/` - input, any `*.log` file
- `rejects/` - lines that couldn't be parsed, one `.rej` file per log

## Setup

```sh
brew install postgresql@17 cpanminus
brew services start postgresql@17
export PATH="$(brew --prefix postgresql@17)/bin:$PATH"
createdb weblogs
cpanm --local-lib=$HOME/perl5 --notest DBI DBD::Pg   # system DBI is missing the XS headers
psql weblogs -f sql/schema.sql
```

## Run

```sh
perl gen_logs.pl 500
perl etl.pl
psql weblogs -c 'SELECT * FROM v_traffic_hourly'
```

It prints how many rows were loaded and rejected per file, then runs the
checks. Exits 1 if any check fails so cron will flag it.

## Incremental loads

`etl_files` keeps a byte offset for each log file. Each run only reads files
that are new or have grown, starting from the saved offset. The `COPY` and the
offset update are in the same transaction, so a crash won't load anything
twice. A half-written last line is left for the next run.

If a file is smaller than its offset (it got rotated or truncated) it's read
from the start again. An advisory lock stops two runs from going at once.

Lines with values Postgres would reject (bad status code, impossible date, bad
IP, invalid UTF-8) go to `rejects/` instead of failing the load.

## Test

```sh
createdb weblogs_test
prove t/
```

Set `ETL_TEST_DSN` to point it at another database. `etl.pl` uses `ETL_DSN`.

## Views

- `v_traffic_hourly` - requests, bytes, 4xx and 5xx per hour
- `v_top_paths` - top 25 paths with hits and error %
- `v_status_summary` - traffic by status class
- `v_load_history` - load stats and reject rate per file

## Data quality checks

In `sql/dq_checks.sql`: reject rate over 5%, duplicate events, future
timestamps, null paths. To add one, add a query under a `-- name: my_check`
line. If it returns any rows the run fails.

## Cron

```cron
*/10 * * * * cd /path/to/perl-etl && /usr/bin/perl etl.pl >> etl_cron.log 2>&1
```
