-- Import a run exported by report/export.sql into this database's results.
--   psql -X -d <db> -f report/import.sql [-v dir=out]
-- The run gets a new run_id here (printed at the end); its label says where it
-- came from. Then: psql -f report/compare.sql -v a=<this run> -v b=<a local run>
-- The result schema must exist: run bench.sql once in this database first.
\set ON_ERROR_STOP on
\set QUIET on
\if :{?dir}
\else
    \set dir out
\endif
begin;
create temp table i_run (like pgmb_results.run) on commit drop;
create temp table i_ddl_step (like pgmb_results.ddl_step) on commit drop;
create temp table i_pgbench_raw (run_id bigint, test_id text, clients int, cmd text, output text) on commit drop;
create temp table i_perf (like pgmb_results.perf) on commit drop;
create temp table i_planning (like pgmb_results.planning) on commit drop;
create temp table i_checks (like pgmb_results.checks) on commit drop;
create temp table i_latency (like pgmb_results.latency) on commit drop;
create temp table i_latency_hist (like pgmb_results.latency_hist) on commit drop;
create temp table i_explain_stats (like pgmb_results.explain_stats) on commit drop;
create temp table i_resource (like pgmb_results.resource) on commit drop;
create temp table i_explain_plan (like pgmb_results.explain_plan) on commit drop;

-- exports made before explain_plan existed have no file for it
\set pgmb_plan_file :dir /export_explain_plan.csv
\set pgmb_has_plans `test -f :'pgmb_plan_file' && echo t || echo f`

-- \copy does not expand psql variables, so the commands are generated
\pset format unaligned
\pset tuples_only on
\set pgmb_imp :dir /_import.psql
select format('\copy i_%s from ''%s/export_%s.csv'' with (format csv, header)', t, :'dir', t)
from unnest(array['run', 'ddl_step', 'pgbench_raw', 'perf', 'planning', 'checks', 'latency', 'latency_hist',
                  'explain_stats', 'resource']
            || case when :'pgmb_has_plans' = 't' then array['explain_plan'] else '{}'::text[] end) t \g :pgmb_imp
\pset format aligned
\pset tuples_only off
\i :pgmb_imp

select count(*) = 1 as pgmb_one_run from i_run \gset
\if :pgmb_one_run
\else
    \echo expected exactly one run in :dir /export_run.csv
    rollback;
    \quit
\endif

-- the run row gets a new id; everything else follows it
insert into pgmb_results.run (label, started_at, finished_at, preset, config, server_version, version_num, settings)
select coalesce(label || ' ', '') || format('[imported run %s, PostgreSQL %s]', run_id, server_version),
       started_at, finished_at, preset, config, server_version, version_num, settings
from i_run
returning run_id as new_run_id \gset

update i_ddl_step set run_id = :new_run_id;
update i_perf set run_id = :new_run_id;
update i_planning set run_id = :new_run_id;
update i_checks set run_id = :new_run_id;
update i_latency set run_id = :new_run_id;
update i_latency_hist set run_id = :new_run_id;
update i_explain_stats set run_id = :new_run_id;
update i_resource set run_id = :new_run_id;
update i_explain_plan set run_id = :new_run_id;
insert into pgmb_results.ddl_step select * from i_ddl_step;
insert into pgmb_results.pgbench_raw (run_id, test_id, clients, cmd, output)
select :new_run_id, test_id, clients, cmd, output from i_pgbench_raw;
insert into pgmb_results.perf select * from i_perf;
insert into pgmb_results.planning select * from i_planning;
insert into pgmb_results.checks select * from i_checks;
insert into pgmb_results.latency select * from i_latency;
insert into pgmb_results.latency_hist select * from i_latency_hist;
insert into pgmb_results.explain_stats select * from i_explain_stats;
insert into pgmb_results.resource select * from i_resource;
insert into pgmb_results.explain_plan select * from i_explain_plan;
commit;
\echo imported as run :new_run_id
