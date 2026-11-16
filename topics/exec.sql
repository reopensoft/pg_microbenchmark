-- Topic: exec - planner and executor nodes that the other topics only touch:
-- Memoize, Materialize, grouping sets, JIT, plans that depend on search_path,
-- rows updated by somebody else while a statement waits for them
-- (EvalPlanQual), short circuits in OR, ROWS FROM.

------------------------------------------------------------------------------
-- Memoize: a cache in front of the inner side of a nested loop
------------------------------------------------------------------------------
-- Hash and merge joins and Materialize are switched off so that the planner
-- has to use a nested loop; each form runs with the cache and without it.
\set pgmb_memo_on 'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\nset local enable_material = off;\n'
\set pgmb_memo_off 'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\nset local enable_material = off;\nset local enable_memoize = off;\n'
\set pgmb_exec_end ';\ncommit;'

-- ten distinct keys in 10,000 outer rows: nearly every lookup is a hit
call pgmb.reg('exec.memoize_few_keys_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_on' || $q$
select count(*), sum(d.id) from g_narrow n join g_dim d on d.id = n.k_100 % 10 + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_few_keys');
call pgmb.reg('exec.memoize_few_keys_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_off' || $q$
select count(*), sum(d.id) from g_narrow n join g_dim d on d.id = n.k_100 % 10 + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_few_keys');

-- up to 10,000 distinct keys: mostly misses, the cache only costs
call pgmb.reg('exec.memoize_many_keys_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_on' || $q$
select count(*), sum(p.grp) from g_narrow n join g_parent p on p.id = n.k_10k % :n_g_parent + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_many_keys');
call pgmb.reg('exec.memoize_many_keys_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_off' || $q$
select count(*), sum(p.grp) from g_narrow n join g_parent p on p.id = n.k_10k % :n_g_parent + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_many_keys');

-- the same with 64 kB: the cache is full early and entries are evicted
call pgmb.reg('exec.memoize_many_keys_work_mem_64kb', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_on' || $q$
set local work_mem = '64kB';
select count(*), sum(p.grp) from g_narrow n join g_parent p on p.id = n.k_10k % :n_g_parent + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_many_keys');

-- half of the keys are NULL and match nothing
call pgmb.reg('exec.memoize_null_keys_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_on' || $q$
select count(*), count(d.id) from g_narrow n left join g_dim d on d.id = n.k_null % 10 + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_null_keys');
call pgmb.reg('exec.memoize_null_keys_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_off' || $q$
select count(*), count(d.id) from g_narrow n left join g_dim d on d.id = n.k_null % 10 + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_null_keys');

-- the cached thing is a whole aggregate, computed per key in a LATERAL subquery
call pgmb.reg('exec.memoize_lateral_aggregate_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_on' || $q$
select count(*), sum(s.c) from g_narrow n,
     lateral (select count(*) as c from g_child ch where ch.parent_id = n.k_100 + 1) s
where n.id between :id and :id + 999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_lateral');
call pgmb.reg('exec.memoize_lateral_aggregate_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_memo_off' || $q$
select count(*), sum(s.c) from g_narrow n,
     lateral (select count(*) as c from g_child ch where ch.parent_id = n.k_100 + 1) s
where n.id between :id and :id + 999$q$ || :'pgmb_exec_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'exec.memoize_lateral');

------------------------------------------------------------------------------
-- Materialize: the inner side of a nested loop stored once and read again
------------------------------------------------------------------------------
-- An inequality join of 20 rows with a subquery: no hash or merge join is
-- possible, the subquery is read once per outer row.
call pgmb.reg('exec.material_rescan_on', '{perf,planning,analyze,consistency,needs_data}', $q$
select count(*) from (select id from g_dim where id <= 20) a,
     (select k_100 from g_narrow where id <= 2000 offset 0) b
where a.id < b.k_100$q$, equiv => 'exec.material');

-- without Materialize the subquery is executed again for every outer row
call pgmb.reg('exec.material_rescan_off', '{perf,planning,analyze,consistency,needs_data}', $q$
begin;
set local enable_material = off;
select count(*) from (select id from g_dim where id <= 20) a,
     (select k_100 from g_narrow where id <= 2000 offset 0) b
where a.id < b.k_100;
commit;$q$, equiv => 'exec.material');

-- 50,000 stored rows in 64 kB: the store is a temporary file, read 20 times
call pgmb.reg('exec.material_rescan_spilled', '{perf,planning,analyze,consistency,needs_data}', $q$
begin;
set local work_mem = '64kB';
select count(*) from (select id from g_dim where id <= 20) a,
     (select k_100 from g_narrow where id <= 50000 offset 0) b
where a.id < b.k_100;
commit;$q$, equiv => 'exec.material_50k');
call pgmb.reg('exec.material_rescan_in_memory', '{perf,planning,analyze,consistency,needs_data}', $q$
begin;
set local work_mem = '64MB';
select count(*) from (select id from g_dim where id <= 20) a,
     (select k_100 from g_narrow where id <= 50000 offset 0) b
where a.id < b.k_100;
commit;$q$, equiv => 'exec.material_50k');

-- the inner side is a materialized CTE: it has its own store already
call pgmb.reg('exec.material_cte_as_inner_side', '{perf,planning,analyze,consistency,needs_data}', $q$
with c as materialized (select k_100 from g_narrow where id <= 2000)
select count(*) from (select id from g_dim where id <= 20) a, c
where a.id < c.k_100$q$, equiv => 'exec.material');

------------------------------------------------------------------------------
-- GROUPING SETS, ROLLUP, CUBE
------------------------------------------------------------------------------
call pgmb.reg('exec.grouping_sets_three', '{perf,planning,analyze,consistency,olap}', $q$
select grp, status, count(*), sum(val) from g_parent group by grouping sets ((grp), (status), ())$q$,
    equiv => 'exec.grouping_sets');

-- sorted: one sort per grouping set that cannot share an order
call pgmb.reg('exec.grouping_sets_three_sorted', '{perf,planning,analyze,consistency,olap}', $q$
begin;
set local enable_hashagg = off;
select grp, status, count(*), sum(val) from g_parent group by grouping sets ((grp), (status), ());
commit;$q$, equiv => 'exec.grouping_sets');

-- the same rows from three scans
call pgmb.reg('exec.grouping_sets_three_as_union_all', '{perf,planning,consistency,olap}', $q$
select grp, null::smallint as status, count(*), sum(val) from g_parent group by grp
union all
select null::int, status, count(*), sum(val) from g_parent group by status
union all
select null::int, null::smallint, count(*), sum(val) from g_parent$q$, equiv => 'exec.grouping_sets');

call pgmb.reg('exec.rollup_two_columns', '{perf,planning,analyze,consistency,olap}', $q$
select grp, status, grouping(grp, status), count(*), sum(val) from g_parent group by rollup (grp, status)$q$,
    equiv => 'exec.rollup');
call pgmb.reg('exec.rollup_two_columns_as_grouping_sets', '{perf,planning,consistency,olap}', $q$
select grp, status, grouping(grp, status), count(*), sum(val) from g_parent
group by grouping sets ((grp, status), (grp), ())$q$, equiv => 'exec.rollup');

call pgmb.reg('exec.cube_two_columns', '{perf,planning,analyze,consistency,olap}', $q$
select grp, status, grouping(grp, status), count(*), sum(val) from g_parent group by cube (grp, status)$q$,
    equiv => 'exec.cube');
call pgmb.reg('exec.cube_two_columns_as_grouping_sets', '{perf,planning,consistency,olap}', $q$
select grp, status, grouping(grp, status), count(*), sum(val) from g_parent
group by grouping sets ((grp, status), (grp), (status), ())$q$, equiv => 'exec.cube');

-- three columns: eight grouping sets from one scan
call pgmb.reg('exec.cube_three_columns', '{perf,planning,analyze,olap}', $q$
select grp, status, dim_id % 10, count(*) from g_parent group by cube (grp, status, dim_id % 10)$q$);

------------------------------------------------------------------------------
-- JIT
------------------------------------------------------------------------------
-- A server built without LLVM accepts the settings and compiles nothing; the
-- forms then measure the same thing. Expression evaluation first.
call pgmb.reg('exec.jit_off_expressions', '{perf,consistency,olap}', $q$
begin;
set local jit = off;
select sum(k_100 * 2 + k_10k % 7 + case when k_skew > 5 then 1 else 0 end),
       count(*) filter (where k_null is not null and k_corr % 3 = 0) from g_narrow;
commit;$q$, equiv => 'exec.jit_expressions');

-- compiled without optimization and without inlining
call pgmb.reg('exec.jit_on_expressions', '{perf,consistency,olap}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
set local jit_optimize_above_cost = -1;
set local jit_inline_above_cost = -1;
select sum(k_100 * 2 + k_10k % 7 + case when k_skew > 5 then 1 else 0 end),
       count(*) filter (where k_null is not null and k_corr % 3 = 0) from g_narrow;
commit;$q$, equiv => 'exec.jit_expressions');

call pgmb.reg('exec.jit_on_expressions_optimized_inlined', '{perf,consistency,olap}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
set local jit_optimize_above_cost = 0;
set local jit_inline_above_cost = 0;
select sum(k_100 * 2 + k_10k % 7 + case when k_skew > 5 then 1 else 0 end),
       count(*) filter (where k_null is not null and k_corr % 3 = 0) from g_narrow;
commit;$q$, equiv => 'exec.jit_expressions');

-- the server's own thresholds decide
call pgmb.reg('exec.jit_default_thresholds_expressions', '{perf,consistency,olap}', $q$
select sum(k_100 * 2 + k_10k % 7 + case when k_skew > 5 then 1 else 0 end),
       count(*) filter (where k_null is not null and k_corr % 3 = 0) from g_narrow$q$,
    equiv => 'exec.jit_expressions');

-- tuple deforming: the last column of the row is the only one used
call pgmb.reg('exec.jit_off_deform_last_column', '{perf,consistency,olap}', $q$
begin;
set local jit = off;
select count(pad), max(pad) from g_narrow;
commit;$q$, equiv => 'exec.jit_deform');
call pgmb.reg('exec.jit_on_deform_last_column', '{perf,consistency,olap}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
select count(pad), max(pad) from g_narrow;
commit;$q$, equiv => 'exec.jit_deform');
call pgmb.reg('exec.jit_on_no_deform_last_column', '{perf,consistency,olap}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
set local jit_tuple_deforming = off;
select count(pad), max(pad) from g_narrow;
commit;$q$, equiv => 'exec.jit_deform');

-- one row by primary key: compiling costs more than it can save
call pgmb.reg('exec.jit_off_point_lookup', '{perf,oltp}', $q$
begin;
set local jit = off;
select val * 2 + grp from g_parent where id = :id;
commit;$q$, setup => '\set id random(1, :n_g_parent)');
call pgmb.reg('exec.jit_forced_point_lookup', '{perf,oltp}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
set local jit_optimize_above_cost = 0;
set local jit_inline_above_cost = 0;
select val * 2 + grp from g_parent where id = :id;
commit;$q$, setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- cached plans and the schema
------------------------------------------------------------------------------
call pgmb.reg_ddl('exec.create_plan_functions', 'schema', $q$
create function exec_count_dim() returns bigint language plpgsql as
'begin return (select count(*) from g_dim); end';
-- A temporary table named g_dim exists from the start. With pg_temp last in
-- search_path the cached statement reads the real table, with pg_temp first
-- the empty temporary one, and after switching back the real one again.
create function exec_plan_follows_search_path() returns text language plpgsql as
$f$declare
    a bigint; b bigint; c bigint;
begin
    create temp table g_dim (id int);
    perform set_config('search_path', 'pgmb_data, pgmb, pg_temp', true);
    a := pgmb_data.exec_count_dim();
    perform set_config('search_path', 'pg_temp, pgmb_data, pgmb', true);
    b := pgmb_data.exec_count_dim();
    perform set_config('search_path', 'pgmb_data, pgmb, pg_temp', true);
    c := pgmb_data.exec_count_dim();
    drop table pg_temp.g_dim;
    return format('%s %s %s', a > 0, b, c = a);
end$f$;
-- the same statement before and after its index is dropped
create function exec_plan_survives_index_drop() returns text language plpgsql as
$f$declare
    n bigint[] := '{}';
begin
    create temp table exec_t as select g from generate_series(1, 10000) g;
    create index exec_t_g on exec_t (g);
    analyze exec_t;
    for pass in 1 .. 2 loop
        n := n || (select count(*) from exec_t where g = 5);
        if pass = 1 then drop index exec_t_g; end if;
    end loop;
    drop table exec_t;
    return n::text;
end$f$$q$);

call pgmb.reg('exec.plancache_follows_search_path', '{consistency,needs_data}',
    $q$select exec_plan_follows_search_path()$q$, equiv => 'exec.plan_search_path');
call pgmb.reg('exec.plancache_follows_search_path_expected', '{consistency,needs_data}',
    $q$select 't 0 t'::text$q$, equiv => 'exec.plan_search_path');

call pgmb.reg('exec.plancache_survives_index_drop', '{consistency}',
    $q$select exec_plan_survives_index_drop()$q$, equiv => 'exec.plan_index_drop');
call pgmb.reg('exec.plancache_survives_index_drop_expected', '{consistency}',
    $q$select '{1,1}'::text$q$, equiv => 'exec.plan_index_drop');

-- "select *" prepared, then a column is added: the result type may not change
call pgmb.reg('exec.err_plancache_result_type_changed', '{errors}', $q$
do $do$
begin
    begin
        execute 'deallocate exec_p';
    exception when others then null;
    end;
    create temp table exec_p_t (a int);
    execute 'prepare exec_p as select * from exec_p_t';
    execute 'execute exec_p';
    alter table exec_p_t add column b int;
    execute 'execute exec_p';
end $do$$q$, expect_error => '0A000');

------------------------------------------------------------------------------
-- EvalPlanQual: the row was changed by somebody else while we waited for it
------------------------------------------------------------------------------
-- Every client goes for the same row. Under READ COMMITTED a waiter takes the
-- new version of the row when the lock is released and checks the WHERE
-- clause again. With one client nobody waits and nothing is rechecked.
call pgmb.reg_ddl('exec.create_g_epq', 'schema', $q$
create table g_epq (id int primary key, v bigint not null);
insert into g_epq select n, 0 from generate_series(1, 10) n$q$);

call pgmb.reg('exec.epq_update_same_row', '{perf,locking,concurrency,oltp}',
    $q$update g_epq set v = v + 1 where id = 1$q$, kind => 'write');

call pgmb.reg('exec.epq_update_recheck_passes', '{perf,locking,concurrency,oltp}',
    $q$update g_epq set v = v + 1 where id = 2 and v >= 0$q$, kind => 'write');

-- the first update makes v odd: the waiters find that their row no longer qualifies
call pgmb.reg('exec.epq_update_recheck_fails', '{perf,locking,concurrency,oltp}',
    $q$update g_epq set v = v + 1 where id = 3 and v % 2 = 0$q$, kind => 'write');

-- the recheck has to run the join again for the new row version
call pgmb.reg('exec.epq_update_with_join', '{perf,locking,concurrency,oltp,needs_data}',
    $q$update g_epq e set v = e.v + d.id from g_dim d where d.id = e.id and e.id = 4 and e.v >= 0$q$, kind => 'write');

call pgmb.reg('exec.epq_select_for_update', '{perf,locking,concurrency,oltp}', $q$
begin;
select v from g_epq where id = 5 and v >= 0 for update;
update g_epq set v = v + 1 where id = 5;
commit;$q$, kind => 'write');

call pgmb.reg('exec.epq_delete_and_reinsert', '{perf,locking,concurrency,oltp}', $q$
with d as (delete from g_epq where id = 6 and v >= 0 returning id, v)
insert into g_epq select id, v + 1 from d$q$, kind => 'write');

------------------------------------------------------------------------------
-- short circuits in OR, AND and CASE
------------------------------------------------------------------------------
call pgmb.reg('exec.expected_true', '{consistency}', $q$select true$q$, equiv => 'exec.true');
call pgmb.reg('exec.expected_10', '{consistency}', $q$select 10::bigint$q$, equiv => 'exec.ten');
call pgmb.reg('exec.expected_0', '{consistency}', $q$select 0::bigint$q$, equiv => 'exec.zero');

-- constants: the planner stops at the first TRUE and never looks at the rest
call pgmb.reg('exec.shortcircuit_or_constant_true_first', '{consistency}',
    $q$select true or (1 / 0 > 0)$q$, equiv => 'exec.true');
call pgmb.reg('exec.err_shortcircuit_or_constant_true_last', '{errors}',
    $q$select (1 / 0 > 0) or true$q$, expect_error => '22012');

-- per row: the right side is not evaluated when the left one decides
call pgmb.reg('exec.shortcircuit_or_per_row', '{consistency}',
    $q$select count(*) from generate_series(1, 10) n where n > 0 or 1 / (n - 5) > 0$q$, equiv => 'exec.ten');
call pgmb.reg('exec.err_shortcircuit_or_right_side_reached', '{errors}',
    $q$select count(*) from generate_series(1, 10) n where n < 0 or 1 / (n - 5) > 0$q$, expect_error => '22012');
call pgmb.reg('exec.shortcircuit_and_per_row', '{consistency}',
    $q$select count(*) from generate_series(1, 10) n where n < 0 and 1 / (n - 5) > 0$q$, equiv => 'exec.zero');
call pgmb.reg('exec.err_shortcircuit_and_right_side_reached', '{errors}',
    $q$select count(*) from generate_series(1, 10) n where n > 0 and 1 / (n - 5) > 0$q$, expect_error => '22012');

-- CASE protects an expression that depends on the row ...
call pgmb.reg('exec.shortcircuit_case_per_row', '{consistency}',
    $q$select count(case when n = 5 then 0 else 1 / (n - 5) end) from generate_series(1, 10) n$q$, equiv => 'exec.ten');
-- ... but not a constant one, which the planner evaluates before any row is read
call pgmb.reg('exec.err_shortcircuit_case_constant_folded', '{errors}',
    $q$select case when n > 0 then 1 else 1 / 0 end from generate_series(1, 10) n$q$, expect_error => '22012');

------------------------------------------------------------------------------
-- ROWS FROM
------------------------------------------------------------------------------
-- functions of different length side by side: the shorter one is padded with NULLs
call pgmb.reg('exec.srf_rows_from_unequal_lengths', '{perf,planning,consistency}',
    $q$select a, b from rows from (generate_series(1, 3), generate_series(1, 5)) as t(a, b)$q$,
    equiv => 'exec.rows_from');
call pgmb.reg('exec.srf_rows_from_unequal_lengths_by_hand', '{perf,planning,consistency}',
    $q$select case when n <= 3 then n end as a, n as b from generate_series(1, 5) n$q$, equiv => 'exec.rows_from');

call pgmb.reg('exec.srf_rows_from_with_ordinality', '{perf,planning,consistency}', $q$
select a, b, o from rows from (generate_series(1, 3), generate_series(1, 5)) with ordinality as t(a, b, o)$q$,
    equiv => 'exec.rows_from_ordinality');
call pgmb.reg('exec.srf_rows_from_with_ordinality_by_hand', '{perf,planning,consistency}',
    $q$select case when n <= 3 then n end as a, n as b, n::bigint as o from generate_series(1, 5) n$q$,
    equiv => 'exec.rows_from_ordinality');

-- unnest() with several arrays is the same thing
call pgmb.reg('exec.srf_unnest_two_arrays', '{perf,planning,consistency}',
    $q$select a, b from unnest(array[1, 2, 3], array['x', 'y']) as t(a, b)$q$, equiv => 'exec.rows_from_unnest');
call pgmb.reg('exec.srf_rows_from_two_unnests', '{perf,planning,consistency}',
    $q$select a, b from rows from (unnest(array[1, 2, 3]), unnest(array['x', 'y'])) as t(a, b)$q$,
    equiv => 'exec.rows_from_unnest');

-- 10,000 rows from two functions in step, against a join on the row number
call pgmb.reg('exec.srf_rows_from_10k', '{perf,planning,consistency}', $q$
select count(*), sum(a), sum(b) from rows from (generate_series(1, 10000), generate_series(10001, 20000)) as t(a, b)$q$,
    equiv => 'exec.rows_from_10k');
call pgmb.reg('exec.srf_join_on_ordinality_10k', '{perf,planning,consistency}', $q$
select count(*), sum(x.a), sum(y.b)
from generate_series(1, 10000) with ordinality as x(a, o)
     join generate_series(10001, 20000) with ordinality as y(b, o) using (o)$q$, equiv => 'exec.rows_from_10k');
