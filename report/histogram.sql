-- Latency histograms in detail, one bar per bucket.
--   psql -X -d <db> -f report/histogram.sql [-v run_id=N] [-v test=<regex>]
-- Buckets are logarithmic, four per decade.
\set QUIET on
\if :{?run_id}
\else
    select max(run_id) as run_id from pgmb_results.run \gset
\endif
\if :{?test}
\else
    \set test .
\endif
\pset pager off
\pset footer off

\echo
\echo ==== latency histograms, run :run_id, tests matching :test
select case when lag(h.test_id) over w is distinct from h.test_id then h.test_id else '' end as test,
       to_char(pgmb_results.bucket_ms(h.bucket), 'FM999990.000') || ' - '
           || to_char(pgmb_results.bucket_ms(h.bucket + 1), 'FM999990.000') as ms,
       h.n,
       to_char(100.0 * h.n / sum(h.n) over (partition by h.test_id), 'FM990.0') as pct,
       to_char(100.0 * sum(h.n) over w / sum(h.n) over (partition by h.test_id), 'FM990.0') as cum_pct,
       repeat('█', greatest(1, (50 * h.n / max(h.n) over (partition by h.test_id))::int)) as histogram
from pgmb_results.latency_hist h
where h.run_id = :run_id and h.test_id ~ :'test'
window w as (partition by h.test_id order by h.bucket)
order by h.test_id, h.bucket;
\pset footer on
