-- pg_microbenchmark entry point. Run from the repository root:
--
--   psql -X -d <db> -f bench.sql -v preset=micro-benchmark [-v name=value ...]
--
-- See README.md for all variables.
\set ON_ERROR_STOP on
\set QUIET on
\pset pager off
set client_min_messages = warning;

\ir core/args.sql

-- The benchmark creates and drops its own schemas and runs a heavy load: it
-- belongs in a database of its own. On first use in a database that already
-- holds other tables it stops, unless -v shared_db=1 says this is intended.
select to_regnamespace('pgmb_results') is null and :'shared_db' <> '1'
       and exists (select from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where c.relkind in ('r', 'p') and n.nspname !~ '^(pg_|information_schema$|pgmb)') as pgmb_foreign_db \gset
\if :pgmb_foreign_db
    \echo database :DBNAME already contains tables that are not the benchmark's.
    \echo Create a separate database for pg_microbenchmark, or pass -v shared_db=1 to use this one anyway.
    \quit
\endif
\ir core/results.sql
\ir core/schema.sql
\ir presets/presets.sql

select set_config('pgmb.only', :'only', false) \gset pgmb_ignore_
select set_config('pgmb.client_checks', :'client_checks', false) \gset pgmb_ignore_
call pgmb.configure(:'preset', :'label', :'data_scale', :'conn_scale', :'write_ratio', :'scope',
                    :'tags', :'topics', :'mode', :'protocol', :'duration', :'warmup',
                    :'plan_iterations', :'pgbench', :'outdir');

-- Test catalog
\ir data/tables.sql
\ir data/indexes.sql
\ir data/comments.sql
\ir topics/cte.sql
\ir topics/cte_join.sql
\ir topics/cte_scan.sql
\ir topics/cte_where.sql
\ir topics/cte_shape.sql
\ir topics/cte_joinalgo.sql
\ir topics/cte_notify.sql
\ir topics/cte_materialize.sql
\ir topics/cte_recursive.sql
\ir topics/cte_mix.sql
\ir topics/cte_dml.sql
\ir topics/cte_scope.sql
\ir topics/cte_lock.sql
\ir topics/cte_txn.sql
\ir topics/cte_rls.sql
\ir topics/cte_array.sql
\ir topics/cte_intarray.sql
\ir topics/cte_intarray_dml.sql
\ir topics/cte_graph.sql
\ir topics/cte_partial.sql
\ir topics/cte_estimate.sql
\ir topics/cte_plancache.sql
\ir topics/cte_memory.sql
\ir topics/cte_collapse.sql
\ir topics/cte_parallel.sql
\ir topics/cte_alternatives.sql
\ir topics/cte_edge.sql
\ir topics/pcte.sql
\ir topics/materialized.sql
\ir topics/distinct.sql
\ir topics/nulls.sql
\ir topics/sort.sql
\ir topics/seqscan.sql
\ir topics/array.sql
\ir topics/array_int.sql
\ir topics/array_intarray.sql
\ir topics/array_queryint.sql
\ir topics/array_intarray_fn.sql
\ir topics/index.sql
\ir topics/index_intarray.sql
\ir topics/plan.sql
\ir topics/lateral.sql
\ir topics/window.sql
\ir topics/resultsize.sql
\ir topics/funcall.sql
\ir topics/locking.sql
\ir topics/cancel.sql
\ir topics/cancel_cause.sql
\ir topics/raise.sql
\ir topics/notify.sql
\ir topics/exec.sql
\ir topics/storage.sql
\ir topics/types.sql
\ir topics/index_types.sql

set search_path = pgmb_data, pgmb, public;
set client_min_messages = info;

-- extra server settings for this run: -v gucs='name=value,name=value'. They are
-- set in this session (checks) and passed to pgbench, and end up in run.settings.
select coalesce(string_agg(format(' -c %s=%s', m[1], m[2]), '' order by ord), '') as pgmb_gucs_opts,
       count(*) filter (where m is null) as pgmb_gucs_bad
from regexp_split_to_table(nullif(btrim(:'gucs'), ''), '\s*,\s*') with ordinality as g(item, ord)
     left join lateral regexp_match(item, '^([A-Za-z_][A-Za-z0-9_.]*)=([^ ]+)$') m on true \gset
select :pgmb_gucs_bad > 0 as pgmb_gucs_invalid \gset
\if :pgmb_gucs_invalid
    \echo gucs must look like name=value,name=value (no spaces inside a value)
    \quit
\endif
select format('set %s = %L', m[1], m[2])
from regexp_split_to_table(nullif(btrim(:'gucs'), ''), '\s*,\s*') as g(item),
     regexp_match(item, '^([A-Za-z_][A-Za-z0-9_.]*)=([^ ]+)$') m \gexec

select pgmb.start_run() as run_id \gset
select set_config('pgmb.run_id', :'run_id', false), set_config('pgmb.cat', :'cat', false) as cat \gset pgmb_
-- staging table for pgbench's per-transaction log
-- staging table for the rows of one statement, read back as lines of text
create temp table pgmb_rows (line text);
create temp table pgmb_log (client int, txno bigint, us text, script int,
                            epoch bigint, epoch_us bigint, retries int);
select scope = 'createonly' as createonly, outdir from pgmb.config \gset

\echo
\echo pg_microbenchmark run :run_id
\pset expanded on
select preset, label, data_scale, clients, write_ratio, scope, mode, protocol, duration,
       array_to_string(sel_tags || exec_tags, ',') as tags, array_to_string(topics, ',') as topics,
       (select count(*) from pgmb.test where phase = 'ddl') as ddl_steps,
       (select count(*) from pgmb.selected) as dml_tests
from pgmb.config;
\pset expanded off

------------------------------------------------------------------------------
-- Phase 1: DDL (schema, load, indexes, constraints, maintenance)
------------------------------------------------------------------------------
\if :skip_ddl
    do $$
    begin
        if to_regclass('pgmb_data.pgmb_meta') is null
           or (select data_scale from pgmb_data.pgmb_meta) is distinct from (select data_scale from pgmb.config)
           or (select count(*) from pgmb_data.g_intarr where cardinality(arr_n) <> pgmb.n('g_intarr_len')) > 0
           or (select max(v) from (select unnest(arr_n) as v from pgmb_data.g_intarr limit 100000) s) >= pgmb.n('g_intarr_distinct') then
            raise exception 'skip_ddl=1 needs existing data loaded with the same data_scale, arr_len and arr_distinct';
        end if;
    end $$;
    \if :pgmb_has_intarray
        do $$
        begin
            if to_regclass('pgmb_data.g_intarr_arr5_gin_int') is null or to_regclass('pgmb_data.g_intarr_v17') is null or to_regclass('pgmb_data.g_ia_dml') is null then
                raise exception 'skip_ddl=1 with intarray=1 needs data loaded with intarray=1';
            end if;
        end $$;
    \endif
    \echo ddl  skipped, reusing existing data
\else
    drop schema if exists pgmb_data cascade;
    create schema pgmb_data;
    select format('call pgmb.step_begin(%L)', id), sql, format('call pgmb.step_end(%L)', id)
    from pgmb.ddl_plan order by stage, ord \gexec
    create table pgmb_data.pgmb_meta as select data_scale from pgmb.config;
    comment on table pgmb_data.pgmb_meta is 'One row: the data_scale the data in this schema was loaded with (checked by skip_ddl=1).';
    comment on column pgmb_data.pgmb_meta.data_scale is 'data_scale of the run that loaded the data';
\endif

-- the role of the row level security tests may read and update g_rls, nothing else
\if :pgmb_has_rls
    grant usage on schema pgmb_data to :"rls_role";
    grant select, update on pgmb_data.g_rls to :"rls_role";
    grant select on pgmb_data.g_dim to :"rls_role";
\endif

------------------------------------------------------------------------------
-- Phase 2: DML
------------------------------------------------------------------------------
\if :createonly
\else
    -- in-database checks: planning, errors, consistency
    -- a runaway query (e.g. a recursive CTE that never ends) must not hang the run
    set statement_timeout = :'stmt_timeout';
    \echo check planning, errors, consistency
    call pgmb.run_checks(:run_id);

    -- consistency and checksums on the client side: every statement is sent as
    -- it is, and what comes back is hashed (see pgmb.check_commands)
    \pset format unaligned
    \pset tuples_only on
    \set pgmb_chk :outdir /_checks.psql
    select pgmb.check_commands() \g :pgmb_chk
    \pset format aligned
    \pset tuples_only off
    \set ON_ERROR_STOP off
    \i :pgmb_chk
    \set ON_ERROR_STOP on
    call pgmb.finish_consistency(:run_id);

    -- pgbench: write one script per test, then a driver script, then run it
    \pset format unaligned
    \pset tuples_only on
    \set pgmb_emit :outdir /_emit.psql
    \set pgmb_run :outdir /_run.psql
    select pgmb.emit_commands() \g :pgmb_emit
    select pgmb.run_commands() \g :pgmb_run
    \i :pgmb_emit

    \setenv PGDATABASE :DBNAME
    \setenv PGHOST :HOST
    \setenv PGPORT :PORT
    \setenv PGUSER :USER
    \set pgmb_opts '-c search_path=pgmb_data,pgmb,public -c statement_timeout=' :stmt_timeout :pgmb_gucs_opts
    \setenv PGOPTIONS :pgmb_opts
    \i :pgmb_run

    \pset format aligned
    \pset tuples_only off
    call pgmb.parse_pgbench(:run_id);
    reset statement_timeout;
\endif

update pgmb_results.run set finished_at = clock_timestamp() where run_id = :run_id;

\ir report/summary.sql
