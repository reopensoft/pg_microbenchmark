-- Topic: cte (part 8) - materialization, inlining and laziness in detail.
-- Function volatility, repeated evaluation, partition pruning, join reordering,
-- row width, temp files, parallelism, LIMIT/OFFSET/EXISTS readers, side effects.

call pgmb.reg_ddl('cte.create_noop_plpgsql_stable', 'schema', $q$
create function noop_plpgsql_stable(int) returns int language plpgsql stable as 'begin return $1; end'$q$);
call pgmb.reg_ddl('cte.create_raise_if', 'schema', $q$
create function raise_if(cond boolean) returns int language plpgsql as
'begin if cond then raise exception ''pgmb forced error''; end if; return 1; end'$q$);
call pgmb.reg_ddl('cte.create_g_cte_seq', 'schema', $q$create sequence g_cte_seq$q$);

------------------------------------------------------------------------------
-- STABLE functions: NOT MATERIALIZED is honoured (unlike VOLATILE)
------------------------------------------------------------------------------
call pgmb.reg('cte.stable_not_materialized_two_readers', '{perf,planning,consistency}', $q$
with c as not materialized (select id, noop_plpgsql_stable(grp) as g from g_parent where id between :id and :id + 300)
select (select count(*) from c where g < 50) as low, (select count(*) from c where g >= 50) as high$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.stable');

call pgmb.reg('cte.stable_default_two_readers', '{perf,planning,consistency}', $q$
with c as (select id, noop_plpgsql_stable(grp) as g from g_parent where id between :id and :id + 300)
select (select count(*) from c where g < 50) as low, (select count(*) from c where g >= 50) as high$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.stable');

call pgmb.reg('cte.stable_as_index_condition', '{perf,planning,oltp}', $q$
with c as not materialized (select id, grp, val from g_parent)
select * from c where id = noop_plpgsql_stable(:id)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.stable_now_single_reader', '{perf,planning}', $q$
with c as (select id, updated_at from g_parent where updated_at < now() - interval '1 day')
select count(*) from c where id between :id and :id + 300 and updated_at < statement_timestamp()$q$,
    setup => '\set id random(1, :n_g_parent)');

-- NOT MATERIALIZED on a recursive CTE is silently ignored
call pgmb.reg('cte.recursive_not_materialized_ignored', '{perf,planning}', $q$
with recursive r(n) as not materialized (select 1 union all select n + 1 from r where n < 2000)
select (select count(*) from r), (select max(n) from r), (select sum(n) from r where n % 2 = 0)$q$);

------------------------------------------------------------------------------
-- how often is the CTE body evaluated
------------------------------------------------------------------------------
-- an expensive expression with two readers: once when materialized, twice when inlined
call pgmb.reg('cte.eval_expensive_default', '{perf,planning,consistency}', $q$
with c as (select id, md5(md5(md5(md5(pad)))) as h from g_narrow where id between :id and :id + 3000)
select (select count(*) from c where h < '8'), (select max(h) from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.eval_expensive');

call pgmb.reg('cte.eval_expensive_not_materialized', '{perf,planning,consistency}', $q$
with c as not materialized (select id, md5(md5(md5(md5(pad)))) as h from g_narrow where id between :id and :id + 3000)
select (select count(*) from c where h < '8'), (select max(h) from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.eval_expensive');

-- four readers over a scan without an index: one base-table pass or four
call pgmb.reg('cte.eval_base_reads_materialized', '{perf,planning,consistency,olap}', $q$
with c as materialized (select id, k_100, k_10k from g_narrow where k_corr % 50 = :m)
select (select count(*) from c), (select max(k_10k) from c), (select min(k_100) from c), (select sum(k_10k) from c)$q$,
    setup => '\set m random(0, 49)', equiv => 'cte.eval_base_reads');

call pgmb.reg('cte.eval_base_reads_not_materialized', '{perf,planning,consistency,olap}', $q$
with c as not materialized (select id, k_100, k_10k from g_narrow where k_corr % 50 = :m)
select (select count(*) from c), (select max(k_10k) from c), (select min(k_100) from c), (select sum(k_10k) from c)$q$,
    setup => '\set m random(0, 49)', equiv => 'cte.eval_base_reads');

------------------------------------------------------------------------------
-- partition pruning (g_part, 16 partitions by bucket)
------------------------------------------------------------------------------
call pgmb.reg('cte.partition_pruned_when_inlined', '{perf,planning,consistency}', $q$
with c as (select id, bucket, val from g_part)
select count(*), sum(val::numeric) from c where bucket = :b$q$,
    setup => '\set b random(0, 15)', equiv => 'cte.partition');

call pgmb.reg('cte.partition_not_pruned_when_materialized', '{perf,planning,consistency,olap}', $q$
with c as materialized (select id, bucket, val from g_part)
select count(*), sum(val::numeric) from c where bucket = :b$q$,
    setup => '\set b random(0, 15)', equiv => 'cte.partition');

call pgmb.reg('cte.partition_pruned_inside_materialized', '{perf,planning,consistency}', $q$
with c as materialized (select id, bucket, val from g_part where bucket = :b)
select count(*), sum(val::numeric) from c$q$,
    setup => '\set b random(0, 15)', equiv => 'cte.partition');

-- pruning decided at executor start (stable function) and at run time (value from another CTE)
call pgmb.reg('cte.partition_pruned_by_stable_function', '{perf,planning}', $q$
with c as (select id, bucket, val from g_part)
select count(*), sum(val) from c where bucket = noop_plpgsql_stable(:b)$q$,
    setup => '\set b random(0, 15)');

call pgmb.reg('cte.partition_pruned_by_scalar_from_cte', '{perf,planning}', $q$
with pick as (select (count(*) % 16)::int as b from g_dim where id <= :d),
     c as (select id, bucket, val from g_part)
select count(*), sum(val) from c where bucket = (select b from pick)$q$,
    setup => '\set d random(1, :n_g_dim)');

call pgmb.reg('cte.partition_pruned_per_join_row', '{perf,planning}', $q$
with keys as (select :b as bucket union all select (:b + 5) % 16 union all select (:b + 11) % 16)
select k.bucket, count(*), sum(p.val)
from keys k join g_part p on p.bucket = k.bucket and p.id between :id and :id + 5000
group by k.bucket$q$,
    setup => E'\\set b random(0, 15)\n\\set id random(1, :n_g_part)');

-- two readers that want different partitions
call pgmb.reg('cte.partition_two_readers_default', '{perf,planning,consistency,olap}', $q$
with c as (select id, bucket, val from g_part)
select (select count(*) from c where bucket = :b), (select count(*) from c where bucket = (:b + 1) % 16)$q$,
    setup => '\set b random(0, 15)', equiv => 'cte.partition_two');

call pgmb.reg('cte.partition_two_readers_not_materialized', '{perf,planning,consistency}', $q$
with c as not materialized (select id, bucket, val from g_part)
select (select count(*) from c where bucket = :b), (select count(*) from c where bucket = (:b + 1) % 16)$q$,
    setup => '\set b random(0, 15)', equiv => 'cte.partition_two');

call pgmb.reg('cte.partition_lookup_without_key', '{perf,planning,oltp}', $q$
with c as (select id, bucket, val from g_part)
select * from c where id = :id$q$,
    setup => '\set id random(1, :n_g_part)');

call pgmb.reg('cte.partition_update_through_cte', '{perf,planning,oltp}', $q$
with t as (select id, bucket from g_part where bucket = :b and id between :id and :id + 2000 order by id limit 3)
update g_part p set val = p.val + 1 from t where p.bucket = t.bucket and p.id = t.id$q$,
    kind => 'write', setup => E'\\set b random(0, 15)\n\\set id random(1, :n_g_part)');

------------------------------------------------------------------------------
-- join reordering across the CTE boundary
------------------------------------------------------------------------------
-- the selective table is outside the CTE; only an inlined CTE can start from it
call pgmb.reg('cte.reorder_inlined', '{perf,planning,consistency,oltp}', $q$
with pc as (select p.id, p.dim_id, c.kind, c.amount from g_parent p join g_child c on c.parent_id = p.id)
select count(*), sum(pc.amount) from g_dim d join pc on pc.dim_id = d.id where d.id = :d and pc.kind = 0$q$,
    setup => '\set d random(1, :n_g_dim)', equiv => 'cte.reorder');

call pgmb.reg('cte.reorder_blocked_by_materialized', '{perf,planning,consistency,olap}', $q$
with pc as materialized (select p.id, p.dim_id, c.kind, c.amount from g_parent p join g_child c on c.parent_id = p.id)
select count(*), sum(pc.amount) from g_dim d join pc on pc.dim_id = d.id where d.id = :d and pc.kind = 0$q$,
    setup => '\set d random(1, :n_g_dim)', equiv => 'cte.reorder');

call pgmb.reg('cte.reorder_two_cte_joins_interleaved', '{perf,planning}', $q$
with pc as (select p.id, p.dim_id, c.kind from g_parent p join g_child c on c.parent_id = p.id),
     dt as (select d.id as dim_id, d.category, t.depth from g_dim d join g_tree t on t.id = d.id)
select count(*) from pc join dt using (dim_id) where dt.category = :c and pc.kind = :k and pc.id between :id and :id + 2000$q$,
    setup => E'\\set c random(0, 9)\n\\set k random(0, 7)\n\\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- what is stored: narrow vs wide rows, memory vs temp files
------------------------------------------------------------------------------
call pgmb.reg('cte.width_narrow_materialized', '{perf,planning}', $q$
with c as materialized (select id from g_wide where id between :id and :id + 5000)
select (select count(*) from c), (select max(id) from c)$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('cte.width_wide_materialized', '{perf,planning}', $q$
with c as materialized (select * from g_wide where id between :id and :id + 5000)
select (select count(*) from c), (select max(id) from c)$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('cte.width_wide_inlined', '{perf,planning}', $q$
with c as not materialized (select * from g_wide where id between :id and :id + 5000)
select (select count(*) from c), (select max(id) from c)$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('cte.spill_fits_in_memory', '{perf}', $q$
begin;
set local work_mem = '256MB';
with c as materialized (select id, pad from g_narrow where id between :id and :id + 30000)
select (select count(*) from c), (select max(pad) from c);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.spill_to_temp_files', '{perf}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, pad from g_narrow where id between :id and :id + 30000)
select (select count(*) from c), (select max(pad) from c);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- parallel plans
------------------------------------------------------------------------------
call pgmb.reg('cte.parallel_serial_baseline', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 0;
with c as (select cat, val from g_events where val > 1)
select cat, count(*), avg(val) from c group by cat;
commit;$q$);

call pgmb.reg('cte.parallel_inlined', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with c as (select cat, val from g_events where val > 1)
select cat, count(*), avg(val) from c group by cat;
commit;$q$);

call pgmb.reg('cte.parallel_materialized', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with c as materialized (select cat, val from g_events where val > 1)
select cat, count(*), avg(val) from c group by cat;
commit;$q$);

call pgmb.reg('cte.parallel_with_modifying_cte', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with touch as (update g_parent set updated_at = now() where id = :id returning id),
     c as (select cat, val from g_events where val > 1)
select cat, count(*), avg(val), (select count(*) from touch) from c group by cat;
commit;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- LIMIT, OFFSET, ORDER BY and EXISTS as readers
------------------------------------------------------------------------------
-- one row out of a result that would have n^2 rows
call pgmb.reg('cte.limit_1_of_cross_join_inlined', '{perf,planning,oltp}', $q$
with c as (select a.id, b.pad from g_narrow a cross join g_narrow b)
select * from c limit 1$q$);

call pgmb.reg('cte.limit_1_of_cross_join_materialized', '{perf,planning,oltp}', $q$
with c as materialized (select a.id, b.pad from g_narrow a cross join g_narrow b)
select * from c limit 1$q$);

-- LIMIT inside vs. outside the CTE
call pgmb.reg('cte.limit_inside', '{perf,planning,consistency,oltp}', $q$
with c as (select id, k_10k from g_narrow where k_100 = :k order by id limit 20)
select * from c$q$,
    setup => '\set k random(0, 99)', equiv => 'cte.limit_place');

call pgmb.reg('cte.limit_outside_inlined', '{perf,planning,consistency,oltp}', $q$
with c as (select id, k_10k from g_narrow where k_100 = :k)
select * from c order by id limit 20$q$,
    setup => '\set k random(0, 99)', equiv => 'cte.limit_place');

call pgmb.reg('cte.limit_outside_materialized', '{perf,planning,consistency}', $q$
with c as materialized (select id, k_10k from g_narrow where k_100 = :k)
select * from c order by id limit 20$q$,
    setup => '\set k random(0, 99)', equiv => 'cte.limit_place');

-- OFFSET decides how many rows are pulled from the CTE
call pgmb.reg('cte.offset_outer_10', '{perf,planning}', $q$
with c as materialized (select id, pad from g_narrow where id >= :id)
select * from c offset 10 limit 10$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.offset_outer_5000', '{perf,planning}', $q$
with c as materialized (select id, pad from g_narrow where id >= :id)
select * from c offset 5000 limit 10$q$,
    setup => '\set id random(1, :n_g_narrow / 2)');

call pgmb.reg('cte.offset_inside_5000', '{perf,planning}', $q$
with c as (select id, pad from g_narrow where id >= :id order by id offset 5000 limit 10)
select * from c$q$,
    setup => '\set id random(1, :n_g_narrow / 2)');

-- outer ORDER BY: everything must be fetched before the first row comes out
call pgmb.reg('cte.order_outer_forces_full_read', '{perf,planning}', $q$
with c as materialized (select id, pad from g_narrow where id between :id and :id + 20000)
select * from c order by pad limit 10$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- NOT EXISTS: stops at the first row, or has to exhaust an empty result
call pgmb.reg('cte.not_exists_stops_at_first_row', '{perf,planning,oltp}', $q$
with c as materialized (select id from g_narrow where k_100 = :k)
select not exists (select 1 from c)$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('cte.not_exists_reads_everything', '{perf,planning,olap}', $q$
with c as materialized (select id from g_narrow where k_corr % 1000 = -1)
select not exists (select 1 from c)$q$);

-- two readers that consume different amounts
call pgmb.reg('cte.readers_one_row_then_all', '{perf,planning}', $q$
with c as materialized (select id, pad from g_narrow where k_100 = :k)
select (select id from c limit 1) as first_id, (select count(*) from c) as n$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('cte.readers_one_row_and_exists', '{perf,planning,oltp}', $q$
with c as materialized (select id, pad from g_narrow where k_100 = :k)
select (select id from c limit 1) as first_id, exists (select 1 from c where id > 0) as any_row$q$,
    setup => '\set k random(0, 99)');

-- a branch that is never evaluated never fills its CTE
call pgmb.reg('cte.case_branch_not_taken', '{perf,planning,oltp}', $q$
with heavy as materialized (select count(*) as n from g_narrow where pad like '%ab%')
select p.id, case when p.grp < 0 then (select n from heavy) else p.grp end
from g_parent p where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.case_branch_taken', '{perf,planning,olap}', $q$
with heavy as materialized (select count(*) as n from g_narrow where pad like '%ab%')
select p.id, case when p.grp >= 0 then (select n from heavy) else p.grp end
from g_parent p where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.coalesce_fallback_not_needed', '{perf,planning,oltp}', $q$
with heavy as materialized (select max(val) as m from g_events where val::text like '%99%')
select p.id, coalesce(p.val, (select m from heavy)::numeric) from g_parent p where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- VOLATILE functions and side effects
------------------------------------------------------------------------------
call pgmb.reg('cte.volatile_unreferenced_not_run', '{perf,planning,oltp}', $q$
with r as (select random() as x from generate_series(1, 1000000)),
     s as (select nextval('g_cte_seq') as v from generate_series(1, 1000000))
select 1$q$,
    kind => 'write');

call pgmb.reg('cte.volatile_random_single_reader', '{perf,planning}', $q$
with r as (select i, random() as x from generate_series(1, 10000) i)
select count(*), avg(x) from r$q$);

-- two readers must see the same random values: the self-join matches every row
call pgmb.reg('cte.volatile_random_two_readers_agree', '{perf,planning}', $q$
with r as (select i, random() as x from generate_series(1, 10000) i)
select count(*) from r a join r b using (i) where a.x = b.x$q$);

call pgmb.reg('cte.nextval_single_reader', '{perf,planning}', $q$
with s as (select nextval('g_cte_seq') as v from generate_series(1, 100))
select count(*), max(v) - min(v) from s$q$,
    kind => 'write');

call pgmb.reg('cte.nextval_two_readers_called_once', '{perf,planning}', $q$
with s as (select nextval('g_cte_seq') as v from generate_series(1, 100))
select (select max(v) - min(v) from s) as span, (select count(distinct v) from s) as distinct_values$q$,
    kind => 'write');

call pgmb.reg('cte.nextval_behind_limit', '{perf,planning,oltp}', $q$
with s as (select nextval('g_cte_seq') as v from g_parent)
select v from s limit 5$q$,
    kind => 'write');

-- a function that raises: is the failing row ever reached
call pgmb.reg('cte.error_function_unreferenced', '{perf,planning,oltp}', $q$
with boom as (select raise_if(true) from g_parent)
select count(*) from g_dim$q$);

call pgmb.reg('cte.error_function_reader_where_false', '{perf,planning,oltp}', $q$
with boom as (select id, raise_if(true) as r from g_parent)
select * from boom where false$q$);

call pgmb.reg('cte.error_function_behind_limit', '{perf,planning,oltp}', $q$
with c as (select id, raise_if(id > 50) as r from g_parent where id <= 100 order by id)
select id from c limit 5$q$);

call pgmb.reg('cte.err_error_function_reached', '{errors,needs_data}',
    $q$with c as (select id, raise_if(id > 50) as r from g_parent where id <= 100) select count(*) from c$q$,
    expect_error => 'P0001');
