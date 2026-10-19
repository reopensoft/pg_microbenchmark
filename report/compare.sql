-- Compare two runs (baseline a, candidate b). Defaults to the last two runs.
--   psql -X -d <db> -f report/compare.sql [-v a=N -v b=M]
-- ratio > 1 means b is better: more tps, less time.
\if :{?b}
\else
    select max(run_id) as b from pgmb_results.run \gset
\endif
\if :{?a}
\else
    select max(run_id) as a from pgmb_results.run where run_id < :b \gset
\endif
\set QUIET on
\pset pager off
\pset footer off

\echo
\echo ==== runs
select * from pgmb_results.run_overview where run_id in (:a, :b) order by run_id = :b;

-- result checksums are comparable only for the same data and the same way of computing them
select (x.config->>'data_scale') is distinct from (y.config->>'data_scale') as pgmb_scale_differs,
       x.config->>'data_scale' as pgmb_scale_a, y.config->>'data_scale' as pgmb_scale_b
from pgmb_results.run x, pgmb_results.run y where x.run_id = :a and y.run_id = :b \gset
\if :pgmb_scale_differs
    \echo
    \echo *** data_scale differs (a = :pgmb_scale_a, b = :pgmb_scale_b): result checksums of the two runs cannot be compared ***
\endif

\echo
\echo ==== settings that differ
select coalesce(x.key, y.key) as setting, x.value as a, y.value as b
from (select * from jsonb_each_text((select settings from pgmb_results.run where run_id = :a))) x
full join (select * from jsonb_each_text((select settings from pgmb_results.run where run_id = :b))) y using (key)
where x.value is distinct from y.value order by 1;

\echo
\echo ==== DDL steps (ms)
select coalesce(x.test_id, y.test_id) as step, round(x.elapsed_ms::numeric, 1) as a, round(y.elapsed_ms::numeric, 1) as b,
       round((x.elapsed_ms / nullif(y.elapsed_ms, 0))::numeric, 2) as ratio
from (select * from pgmb_results.ddl_step where run_id = :a) x
full join (select * from pgmb_results.ddl_step where run_id = :b) y using (test_id)
where coalesce(x.kind, y.kind) <> 'schema'
order by coalesce(x.ord, y.ord);

\echo
\echo ==== performance (tps; latency in ms)
select coalesce(x.test_id, y.test_id) as test, round(x.tps::numeric, 1) as a, round(y.tps::numeric, 1) as b,
       round((y.tps / nullif(x.tps, 0))::numeric, 2) as ratio,
       round(x.lat_avg_ms::numeric, 3) as avg_a, round(y.lat_avg_ms::numeric, 3) as avg_b,
       round(lx.p99_ms::numeric, 3) as p99_a, round(ly.p99_ms::numeric, 3) as p99_b
from (select * from pgmb_results.perf where run_id = :a) x
full join (select * from pgmb_results.perf where run_id = :b) y using (test_id)
left join pgmb_results.latency lx on lx.run_id = :a and lx.test_id = x.test_id
left join pgmb_results.latency ly on ly.run_id = :b and ly.test_id = y.test_id
order by ratio nulls last, test;

\echo
\echo ==== planning (median ms, distinct plan shapes)
select coalesce(x.test_id, y.test_id) as test, round(x.plan_ms_median::numeric, 3) as a, round(y.plan_ms_median::numeric, 3) as b,
       round((x.plan_ms_median / nullif(y.plan_ms_median, 0))::numeric, 2) as ratio,
       x.distinct_plans as plans_a, y.distinct_plans as plans_b,
       case when x.plan_shape is distinct from y.plan_shape then 'CHANGED' end as shape
from (select * from pgmb_results.planning where run_id = :a) x
full join (select * from pgmb_results.planning where run_id = :b) y using (test_id)
order by ratio nulls last, test;

\echo
\echo ==== row estimates and node memory (q-error; kB in memory / on disk)
select coalesce(x.test_id, y.test_id) as test, round(x.max_qerror::numeric, 1) as q_a, round(y.max_qerror::numeric, 1) as q_b,
       y.worst_node as worst_node_b, x.mem_kb as mem_a, y.mem_kb as mem_b, x.disk_kb as disk_a, y.disk_kb as disk_b,
       case when x.plan_shape is distinct from y.plan_shape then 'CHANGED' end as shape
from (select * from pgmb_results.explain_stats where run_id = :a) x
full join (select * from pgmb_results.explain_stats where run_id = :b) y using (test_id)
order by greatest(x.max_qerror, y.max_qerror) desc nulls last, test;

\echo
\echo ==== EXPLAIN ANALYZE: what changed (time = median ms of the TIMING OFF executions, ratio > 1: b faster;
\echo ====   counters from one execution, comparable only for the same data; "changed" lists the counters that moved by more than 10 %)
select coalesce(x.test_id, y.test_id) as test,
       round(x.exec_ms_med::numeric, 3) as ms_a, round(y.exec_ms_med::numeric, 3) as ms_b,
       round((x.exec_ms_med / nullif(y.exec_ms_med, 0))::numeric, 2) as ratio,
       nullif(concat_ws(', ',
           case when x.test_id is null then 'only in b' when y.test_id is null then 'only in a' end,
           case when sx.plan_shape <> sy.plan_shape then 'PLAN' end,
           case when pgmb_results.differs(x.rows_processed, y.rows_processed) then 'rows' end,
           case when pgmb_results.differs(x.rows_removed, y.rows_removed) then 'filtered' end,
           case when pgmb_results.differs(x.blocks_hit + x.blocks_read, y.blocks_hit + y.blocks_read) then 'blocks' end,
           case when pgmb_results.differs(x.blocks_read, y.blocks_read) then 'reads' end,
           case when pgmb_results.differs(x.temp_blocks, y.temp_blocks) then 'spill' end,
           case when pgmb_results.differs(x.wal_bytes, y.wal_bytes) then 'wal' end,
           case when x.workers_launched <> y.workers_launched then 'workers' end,
           case when pgmb_results.differs(x.heap_fetches, y.heap_fetches) then 'heap_fetches' end,
           case when pgmb_results.differs(x.lossy_blocks, y.lossy_blocks) then 'lossy' end,
           case when pgmb_results.differs(x.output_kb, y.output_kb) then 'output' end,
           case when pgmb_results.differs(x.plan_ms, y.plan_ms, 0.5) then 'planning' end), '') as changed,
       round(x.rows_processed::numeric) as rows_a, round(y.rows_processed::numeric) as rows_b,
       x.blocks_hit + x.blocks_read as blocks_a, y.blocks_hit + y.blocks_read as blocks_b,
       x.temp_blocks as temp_a, y.temp_blocks as temp_b,
       x.workers_launched as wrk_a, y.workers_launched as wrk_b
from (select * from pgmb_results.explain_metrics where run_id = :a) x
full join (select * from pgmb_results.explain_metrics where run_id = :b) y using (test_id)
left join pgmb_results.explain_stats sx on sx.run_id = :a and sx.test_id = x.test_id
left join pgmb_results.explain_stats sy on sy.run_id = :b and sy.test_id = y.test_id
where x.test_id is null or y.test_id is null
   or pgmb_results.differs(x.exec_ms_med, y.exec_ms_med, 0.1, 0.01)
   or sx.plan_shape <> sy.plan_shape
   or pgmb_results.differs(x.rows_processed, y.rows_processed)
   or pgmb_results.differs(x.blocks_hit + x.blocks_read, y.blocks_hit + y.blocks_read)
   or pgmb_results.differs(x.temp_blocks, y.temp_blocks)
   or pgmb_results.differs(x.wal_bytes, y.wal_bytes)
   or x.workers_launched <> y.workers_launched
order by ratio nulls last, test;

\echo
\echo ==== temporary files per transaction
select coalesce(x.test_id, y.test_id) as test,
       pg_size_pretty((x.temp_bytes / nullif(px.transactions, 0))::bigint) as temp_per_tx_a,
       pg_size_pretty((y.temp_bytes / nullif(py.transactions, 0))::bigint) as temp_per_tx_b
from (select * from pgmb_results.resource where run_id = :a) x
full join (select * from pgmb_results.resource where run_id = :b) y using (test_id)
left join pgmb_results.perf px on px.run_id = :a and px.test_id = x.test_id
left join pgmb_results.perf py on py.run_id = :b and py.test_id = y.test_id
where coalesce(x.temp_bytes, 0) > 0 or coalesce(y.temp_bytes, 0) > 0
order by coalesce(y.temp_bytes, x.temp_bytes) desc;

\echo
\echo ==== result checksums (same test, same parameters, both runs)
select count(*) filter (where x.detail = y.detail) as same_result,
       count(*) filter (where x.detail <> y.detail) as "DIFFERENT RESULT",
       count(*) filter (where x.test_id is null or y.test_id is null) as only_in_one_run
from (select * from pgmb_results.checks where run_id = :a and check_type in ('checksum', 'consistency') and ok) x
full join (select * from pgmb_results.checks where run_id = :b and check_type in ('checksum', 'consistency') and ok) y
     using (test_id, check_type);

select coalesce(x.test_id, y.test_id) as test,
       case when x.test_id is null then 'only in b' when y.test_id is null then 'only in a' else '*** DIFFERENT ***' end as result,
       x.detail as checksum_a, y.detail as checksum_b
from (select * from pgmb_results.checks where run_id = :a and check_type in ('checksum', 'consistency') and ok) x
full join (select * from pgmb_results.checks where run_id = :b and check_type in ('checksum', 'consistency') and ok) y
     using (test_id, check_type)
where x.detail is distinct from y.detail
order by (x.test_id is not null and y.test_id is not null) desc, 1;

\echo
\echo ==== checks whose outcome differs
select coalesce(x.test_id, y.test_id) as test, coalesce(x.check_type, y.check_type) as check_type,
       x.ok as ok_a, y.ok as ok_b, y.detail as detail_b
from (select * from pgmb_results.checks where run_id = :a) x
full join (select * from pgmb_results.checks where run_id = :b) y using (test_id, check_type)
where x.ok is distinct from y.ok order by 1;
\pset footer on
