-- Report for one run. Standalone use:
--   psql -X -d <db> -f report/summary.sql [-v run_id=N] [-v outdir=out]
\if :{?run_id}
\else
    select max(run_id) as run_id from pgmb_results.run \gset
\endif
\if :{?outdir}
\else
    \set outdir out
\endif
\pset pager off
\pset format aligned
\pset tuples_only off
\pset footer off

\echo
\echo ==== run :run_id
\pset expanded on
select * from pgmb_results.run_overview where run_id = :run_id;
\pset expanded off

\echo
\echo ==== DDL phase by stage
select kind as stage, count(*) as steps, round(sum(elapsed_ms)::numeric, 1) as ms,
       pg_size_pretty(sum(wal_bytes)) as wal
from pgmb_results.ddl_step where run_id = :run_id
group by kind
order by array_position(array['schema', 'load', 'index', 'constraint', 'maintenance'], kind);

\echo
\echo ==== data loading
select test_id as step, n_rows as rows, round(elapsed_ms::numeric, 1) as ms,
       round((n_rows / nullif(elapsed_ms, 0) * 1000)::numeric) as rows_per_s,
       pg_size_pretty(rel_bytes) as size, pg_size_pretty(wal_bytes) as wal
from pgmb_results.ddl_step where run_id = :run_id and kind = 'load' order by ord;

\echo
\echo ==== index and constraint builds
select test_id as step, round(elapsed_ms::numeric, 1) as ms,
       pg_size_pretty(rel_bytes) as size, pg_size_pretty(wal_bytes) as wal
from pgmb_results.ddl_step where run_id = :run_id and kind in ('index', 'constraint') order by ord;

\echo
\echo ==== performance (pgbench); latency in ms
\echo ==== histogram: 24 log-scale buckets, 4 per decade: |0.01-0.1|0.1-1|1-10|10-100|100-1000|1000-10000| ms
select p.test_id as test, p.transactions as tx, p.failed,
       round(p.tps::numeric, 1) as tps, round(p.lat_avg_ms::numeric, 3) as avg,
       round(l.p50_ms::numeric, 3) as p50, round(l.p95_ms::numeric, 3) as p95,
       round(l.p99_ms::numeric, 3) as p99, round(l.max_ms::numeric, 1) as max,
       pgmb_results.sparkline(p.run_id, p.test_id) as histogram
from pgmb_results.perf p
left join pgmb_results.latency l using (run_id, test_id)
where p.run_id = :run_id order by p.test_id;

\echo
\echo ==== planning (time in ms; plans = distinct plan shapes over varying parameters)
select test_id as test, iterations as n, round(plan_ms_min::numeric, 3) as min,
       round(plan_ms_median::numeric, 3) as median, round(plan_ms_max::numeric, 3) as max,
       mem_kb_max as mem_kb, distinct_plans as plans
from pgmb_results.planning where run_id = :run_id order by plan_ms_median desc;

\echo
\echo ==== temporary files and WAL per transaction (tests that wrote any temporary file, or the 15 largest WAL writers)
select r.test_id as test, p.transactions as tx, r.temp_files as files,
       pg_size_pretty(r.temp_bytes) as temp_total,
       pg_size_pretty((r.temp_bytes / nullif(p.transactions, 0))::bigint) as temp_per_tx,
       pg_size_pretty((r.wal_bytes / nullif(p.transactions, 0))::bigint) as wal_per_tx
from pgmb_results.resource r join pgmb_results.perf p using (run_id, test_id)
where r.run_id = :run_id
  and (r.temp_bytes > 0
       or r.test_id in (select test_id from pgmb_results.resource where run_id = :run_id order by wal_bytes desc limit 15))
order by r.temp_bytes desc, r.wal_bytes desc;

\echo
\echo ==== row estimates and node memory (one EXPLAIN ANALYZE; q-error = worst est/actual ratio over the plan nodes)
select test_id as test, nodes, round(max_qerror::numeric, 1) as q_error, worst_node,
       round(worst_est::numeric) as est, round(worst_actual::numeric) as actual,
       round(root_est::numeric) as root_est, round(root_actual::numeric) as root_actual,
       mem_kb, disk_kb
from pgmb_results.explain_stats where run_id = :run_id order by max_qerror desc nulls last, test_id;

\echo
\echo ==== checks
select check_type, count(*) as tests, count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
from pgmb_results.checks where run_id = :run_id group by check_type order by check_type;

select count(*) > 0 as pgmb_has_failures from pgmb_results.checks where run_id = :run_id and not ok \gset
\if :pgmb_has_failures
    \echo
    \echo ==== FAILED checks
    select check_type, test_id as test, detail from pgmb_results.checks
    where run_id = :run_id and not ok order by check_type, test_id;
\endif

select count(*) > 0 as pgmb_has_failures from pgmb_results.perf where run_id = :run_id and tps is null \gset
\if :pgmb_has_failures
    \echo
    \echo ==== pgbench runs without a result (see pgmb_results.pgbench_raw.output)
    select test_id as test from pgmb_results.perf where run_id = :run_id and tps is null order by test_id;
\endif

-- CSV export, one file per result table
\pset format csv
\set pgmb_f :outdir /run_ :run_id _ddl.csv
select * from pgmb_results.ddl_step where run_id = :run_id order by ord \g :pgmb_f
\set pgmb_f :outdir /run_ :run_id _perf.csv
select * from pgmb_results.perf where run_id = :run_id order by test_id \g :pgmb_f
\set pgmb_f :outdir /run_ :run_id _latency.csv
select l.*, pgmb_results.sparkline(l.run_id, l.test_id) as histogram
from pgmb_results.latency l where run_id = :run_id order by test_id \g :pgmb_f
\set pgmb_f :outdir /run_ :run_id _latency_hist.csv
select run_id, test_id, bucket, pgmb_results.bucket_ms(bucket) as from_ms,
       pgmb_results.bucket_ms(bucket + 1) as to_ms, n
from pgmb_results.latency_hist where run_id = :run_id order by test_id, bucket \g :pgmb_f
\set pgmb_f :outdir /run_ :run_id _planning.csv
select * from pgmb_results.planning where run_id = :run_id order by test_id \g :pgmb_f
\set pgmb_f :outdir /run_ :run_id _explain_stats.csv
select * from pgmb_results.explain_stats where run_id = :run_id order by test_id \g :pgmb_f
\set pgmb_f :outdir /run_ :run_id _resource.csv
select * from pgmb_results.resource where run_id = :run_id order by test_id \g :pgmb_f
\set pgmb_f :outdir /run_ :run_id _checks.csv
select * from pgmb_results.checks where run_id = :run_id order by check_type, test_id \g :pgmb_f
\pset format aligned
\pset footer on
\echo
\set pgmb_f :outdir /run_ :run_id _*.csv
\echo CSV written to :pgmb_f
