-- Topic: cte (part 22) - CTEs and cached plans.
-- A prepared statement is planned with its parameter values for the first five
-- executions, after that a generic plan, built without them, is used when it
-- does not look worse. With a CTE in the query the parameters decide how much
-- can be moved into it. Each case is run with pgbench in the simple protocol
-- (planned every time), as a prepared statement, and with plan_cache_mode
-- forced. PL/pgSQL keeps plans the same way; dynamic SQL does not.
-- protocol => ... applies in isolated mode (see README).

call pgmb.reg_ddl('cte.create_plan_cache_functions', 'schema', $q$
-- a static query in PL/pgSQL: prepared once per session
create function cte_fn_static(p_id bigint) returns numeric language plpgsql stable as $f$
declare r numeric;
begin
    with c as (select id, val from g_parent where id between p_id and p_id + 9)
    select sum(val) into r from c;
    return r;
end $f$;
-- the same query as dynamic SQL: planned on every call
create function cte_fn_dynamic(p_id bigint) returns numeric language plpgsql stable as $f$
declare r numeric;
begin
    execute 'with c as (select id, val from g_parent where id between $1 and $1 + 9) select sum(val) from c'
        into r using p_id;
    return r;
end $f$;
-- the CTE is materialized: the parameter is inside it
create function cte_fn_static_materialized(p_id bigint) returns numeric language plpgsql stable as $f$
declare r numeric;
begin
    with c as materialized (select id, val from g_parent where id between p_id and p_id + 9)
    select sum(val) into r from c;
    return r;
end $f$;
-- SQL functions with a CTE in the body: scalar, and set-returning
create function cte_fn_sql_scalar(p_id bigint) returns numeric language sql stable as $f$
    with c as (select id, val from g_parent where id between p_id and p_id + 9) select sum(val) from c
$f$;
create function cte_fn_sql_rows(p_id bigint) returns table (id bigint, val numeric) language sql stable as $f$
    with c as (select id, val from g_parent where id between p_id and p_id + 9) select id, val from c
$f$$q$);

------------------------------------------------------------------------------
-- the parameter is a filter above an inlined CTE (pushed down to the index)
------------------------------------------------------------------------------
call pgmb.reg('cte.plancache_pushdown_simple', '{perf,oltp}', $q$
with c as (select id, val, grp from g_parent)
select count(*), sum(val) from c where id between :id and :id + 9$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'simple');

call pgmb.reg('cte.plancache_pushdown_extended', '{perf,oltp}', $q$
with c as (select id, val, grp from g_parent)
select count(*), sum(val) from c where id between :id and :id + 9$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'extended');

call pgmb.reg('cte.plancache_pushdown_prepared', '{perf,oltp}', $q$
with c as (select id, val, grp from g_parent)
select count(*), sum(val) from c where id between :id and :id + 9$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

call pgmb.reg('cte.plancache_pushdown_prepared_force_generic', '{perf,oltp}', $q$
begin;
set local plan_cache_mode = force_generic_plan;
with c as (select id, val, grp from g_parent)
select count(*), sum(val) from c where id between :id and :id + 9;
commit;$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

call pgmb.reg('cte.plancache_pushdown_prepared_force_custom', '{perf,oltp}', $q$
begin;
set local plan_cache_mode = force_custom_plan;
with c as (select id, val, grp from g_parent)
select count(*), sum(val) from c where id between :id and :id + 9;
commit;$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

-- the same statement without a CTE
call pgmb.reg('cte.plancache_no_cte_prepared', '{perf,oltp}', $q$
select count(*), sum(val) from g_parent where id between :id and :id + 9$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

------------------------------------------------------------------------------
-- the parameter is inside a materialized CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.plancache_materialized_simple', '{perf,oltp}', $q$
with c as materialized (select id, val, grp from g_parent where id between :id and :id + 99)
select count(*), sum(val) from c where grp < 50$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'simple');

call pgmb.reg('cte.plancache_materialized_prepared', '{perf,oltp}', $q$
with c as materialized (select id, val, grp from g_parent where id between :id and :id + 99)
select count(*), sum(val) from c where grp < 50$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

-- five CTEs, a diamond: planning is the larger part of a short query
call pgmb.reg('cte.plancache_diamond_simple', '{perf,oltp}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 49),
     b as (select grp, count(*) as n from a group by grp),
     c as (select grp, sum(val) as total from a group by grp),
     d as (select b.grp, b.n, c.total from b join c using (grp)),
     e as (select count(*) as groups, sum(n) as n, sum(total) as total from d)
select * from e$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'simple');

call pgmb.reg('cte.plancache_diamond_prepared', '{perf,oltp}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 49),
     b as (select grp, count(*) as n from a group by grp),
     c as (select grp, sum(val) as total from a group by grp),
     d as (select b.grp, b.n, c.total from b join c using (grp)),
     e as (select count(*) as groups, sum(n) as n, sum(total) as total from d)
select * from e$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

------------------------------------------------------------------------------
-- a skewed parameter: the generic plan is built for an average value
------------------------------------------------------------------------------
-- always the frequent value: a custom plan would scan, the generic plan is for a typical value
call pgmb.reg('cte.plancache_skew_frequent_value_force_custom', '{perf,olap}', $q$
begin;
set local plan_cache_mode = force_custom_plan;
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v;
commit;$q$,
    setup => '\set v random(0, 0)', protocol => 'prepared');

call pgmb.reg('cte.plancache_skew_frequent_value_force_generic', '{perf,olap}', $q$
begin;
set local plan_cache_mode = force_generic_plan;
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v;
commit;$q$,
    setup => '\set v random(0, 0)', protocol => 'prepared');

call pgmb.reg('cte.plancache_skew_rare_value_force_custom', '{perf,oltp}', $q$
begin;
set local plan_cache_mode = force_custom_plan;
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v;
commit;$q$,
    setup => '\set v random(700, 999)', protocol => 'prepared');

call pgmb.reg('cte.plancache_skew_rare_value_force_generic', '{perf,oltp}', $q$
begin;
set local plan_cache_mode = force_generic_plan;
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v;
commit;$q$,
    setup => '\set v random(700, 999)', protocol => 'prepared');

-- a mixture of both, left to the default (auto) mode
call pgmb.reg('cte.plancache_skew_mixed_values_auto', '{perf}', $q$
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v$q$,
    setup => '\set v random_zipfian(0, 999, 1.5)', protocol => 'prepared');

call pgmb.reg('cte.plancache_skew_mixed_values_simple', '{perf}', $q$
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v$q$,
    setup => '\set v random_zipfian(0, 999, 1.5)', protocol => 'simple');

------------------------------------------------------------------------------
-- partition pruning through a CTE: at plan time, or at execution start
------------------------------------------------------------------------------
call pgmb.reg('cte.plancache_partition_pruning_force_custom', '{perf,oltp}', $q$
begin;
set local plan_cache_mode = force_custom_plan;
with c as (select id, bucket, val from g_part)
select count(*), sum(val) from c where bucket = :b;
commit;$q$,
    setup => '\set b random(0, 15)', protocol => 'prepared');

call pgmb.reg('cte.plancache_partition_pruning_force_generic', '{perf,oltp}', $q$
begin;
set local plan_cache_mode = force_generic_plan;
with c as (select id, bucket, val from g_part)
select count(*), sum(val) from c where bucket = :b;
commit;$q$,
    setup => '\set b random(0, 15)', protocol => 'prepared');

-- materialized: the parameter cannot reach the partitions in either mode
call pgmb.reg('cte.plancache_partition_pruning_blocked_by_materialized', '{perf,olap}', $q$
begin;
set local plan_cache_mode = force_generic_plan;
with c as materialized (select id, bucket, val from g_part)
select count(*), sum(val) from c where bucket = :b;
commit;$q$,
    setup => '\set b random(0, 15)', protocol => 'prepared');

------------------------------------------------------------------------------
-- functions
------------------------------------------------------------------------------
call pgmb.reg('cte.plancache_plpgsql_static_query', '{perf,planning,consistency,oltp}', $q$
select cte_fn_static(:id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn');

call pgmb.reg('cte.plancache_plpgsql_dynamic_query', '{perf,planning,consistency,oltp}', $q$
select cte_fn_dynamic(:id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn');

call pgmb.reg('cte.plancache_plpgsql_static_materialized', '{perf,planning,consistency,oltp}', $q$
select cte_fn_static_materialized(:id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn');

call pgmb.reg('cte.plancache_sql_function_scalar', '{perf,planning,consistency,oltp}', $q$
select cte_fn_sql_scalar(:id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn');

call pgmb.reg('cte.plancache_inline_query', '{perf,planning,consistency,oltp}', $q$
with c as (select id, val from g_parent where id between :id and :id + 9) select sum(val) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn');

-- called once per row of a driving query: the cached plan pays off, or not
call pgmb.reg('cte.plancache_plpgsql_static_100_calls', '{perf,planning,consistency}', $q$
select sum(cte_fn_static(p.id)) from g_parent p where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn100');

call pgmb.reg('cte.plancache_plpgsql_dynamic_100_calls', '{perf,planning,consistency}', $q$
select sum(cte_fn_dynamic(p.id)) from g_parent p where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn100');

call pgmb.reg('cte.plancache_sql_function_scalar_100_calls', '{perf,planning,consistency}', $q$
select sum(cte_fn_sql_scalar(p.id)) from g_parent p where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn100');

call pgmb.reg('cte.plancache_lateral_cte_100_rows', '{perf,planning,consistency}', $q$
select sum(s.total) from g_parent p,
     lateral (with c as (select id, val from g_parent where id between p.id and p.id + 9) select sum(val) as total from c) s
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_fn100');

-- a set-returning SQL function with a CTE, in FROM: can it be inlined into the caller?
call pgmb.reg('cte.plancache_sql_function_rows_in_from', '{perf,planning,consistency,oltp}', $q$
select count(*), sum(val) from cte_fn_sql_rows(:id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_rows');

call pgmb.reg('cte.plancache_sql_function_rows_with_outer_filter', '{perf,planning,oltp}', $q$
select count(*), sum(val) from cte_fn_sql_rows(:id) where id = :id + 3$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.plancache_rows_inline_query', '{perf,planning,consistency,oltp}', $q$
with c as (select id, val from g_parent where id between :id and :id + 9) select count(*), sum(val) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.plancache_rows');

------------------------------------------------------------------------------
-- invalidation: ANALYZE on a table of the query throws the cached plan away
------------------------------------------------------------------------------
call pgmb.reg('cte.plancache_invalidated_by_analyze', '{perf}', $q$
analyze g_dim;
with c as (select id, dim_id, val from g_parent where id between :id and :id + 9)
select count(*), sum(c.val), min(d.code) from c join g_dim d on d.id = c.dim_id;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

-- the same ANALYZE on a table the query does not read: the plan stays
call pgmb.reg('cte.plancache_not_invalidated_by_unrelated_analyze', '{perf}', $q$
analyze g_dim;
with c as (select id, val from g_parent where id between :id and :id + 9)
select count(*), sum(c.val) from c;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

call pgmb.reg('cte.plancache_invalidation_baseline_no_analyze', '{perf}', $q$
with c as (select id, dim_id, val from g_parent where id between :id and :id + 9)
select count(*), sum(c.val), min(d.code) from c join g_dim d on d.id = c.dim_id$q$,
    setup => '\set id random(1, :n_g_parent)', protocol => 'prepared');

-- a function's cached plan against the same ANALYZE
call pgmb.reg('cte.plancache_plpgsql_invalidated_by_analyze', '{perf}', $q$
analyze g_parent;
select cte_fn_static(:id);$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');
