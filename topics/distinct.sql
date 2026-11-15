-- Topic: DISTINCT in all its forms.
-- SELECT DISTINCT, DISTINCT ON, GROUP BY, set operations, window emulation,
-- loose index scan, and DISTINCT inside aggregates (count, array_agg, ...).
-- Equivalent formulations are grouped and must return the same rows.

------------------------------------------------------------------------------
-- the same distinct values of one column, written eight ways
------------------------------------------------------------------------------
call pgmb.reg('distinct.form_select_distinct', '{perf,planning,consistency}', $q$
select distinct k_100 from g_narrow where id between :id and :id + 2000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

call pgmb.reg('distinct.form_group_by', '{perf,planning,consistency}', $q$
select k_100 from g_narrow where id between :id and :id + 2000 group by k_100$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

call pgmb.reg('distinct.form_distinct_on', '{perf,planning,consistency}', $q$
select distinct on (k_100) k_100 from g_narrow where id between :id and :id + 2000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

call pgmb.reg('distinct.form_union_self', '{perf,planning,consistency}', $q$
select k_100 from g_narrow where id between :id and :id + 2000
union
select k_100 from g_narrow where id between :id and :id + 2000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

call pgmb.reg('distinct.form_intersect_self', '{perf,planning,consistency}', $q$
select k_100 from g_narrow where id between :id and :id + 2000
intersect
select k_100 from g_narrow where id between :id and :id + 2000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

call pgmb.reg('distinct.form_row_number', '{perf,planning,consistency}', $q$
select k_100
from (select k_100, row_number() over (partition by k_100) as rn
      from g_narrow where id between :id and :id + 2000) s
where rn = 1$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

call pgmb.reg('distinct.form_unnest_array_agg', '{perf,planning,consistency}', $q$
select unnest(array_agg(distinct k_100)) from g_narrow where id between :id and :id + 2000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

call pgmb.reg('distinct.form_not_exists_earlier', '{perf,planning,consistency}', $q$
select a.k_100
from g_narrow a
where a.id between :id and :id + 2000
  and not exists (select 1 from g_narrow b
                  where b.id between :id and :id + 2000 and b.k_100 = a.k_100 and b.id < a.id)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.form');

------------------------------------------------------------------------------
-- distinct values of a whole table: hash/sort vs. walking the index
------------------------------------------------------------------------------
call pgmb.reg('distinct.table_select_distinct', '{perf,planning,consistency,olap}', $q$
select distinct k_100 from g_narrow$q$, equiv => 'distinct.table');

call pgmb.reg('distinct.table_group_by', '{perf,planning,consistency,olap}', $q$
select k_100 from g_narrow group by k_100$q$, equiv => 'distinct.table');

call pgmb.reg('distinct.table_ordered_by_index', '{perf,planning,consistency,olap}', $q$
select distinct k_100 from g_narrow order by k_100$q$, equiv => 'distinct.table');

-- loose index scan emulated with a recursive CTE: one index probe per distinct value
call pgmb.reg('distinct.table_loose_index_scan', '{perf,planning,consistency}', $q$
with recursive t(k) as (
    (select k_100 from g_narrow order by k_100 limit 1)
    union all
    select (select n.k_100 from g_narrow n where n.k_100 > t.k order by n.k_100 limit 1)
    from t where t.k is not null)
select k from t where k is not null$q$, equiv => 'distinct.table');

------------------------------------------------------------------------------
-- SELECT DISTINCT: cardinality, columns, expressions
------------------------------------------------------------------------------
call pgmb.reg('distinct.high_cardinality', '{perf,planning}', $q$
select distinct k_10k from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.already_unique', '{perf,planning}', $q$
select distinct id from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.two_columns', '{perf,planning}', $q$
select distinct k_100, k_skew from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.two_columns_index_order', '{perf,planning}', $q$
select distinct k_100, k_10k from g_narrow where k_100 = :k order by k_100, k_10k$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('distinct.expression', '{perf,planning}', $q$
select distinct k_10k % 10, k_100 / 25 from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.with_nulls', '{perf,planning}', $q$
select distinct k_null from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.text_prefix', '{perf,planning}', $q$
select distinct left(pad, 2) from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.whole_wide_rows', '{perf,planning}', $q$
select distinct * from g_wide where id between :id and :id + 1000$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('distinct.with_limit', '{perf,planning,oltp}', $q$
select distinct k_10k from g_narrow where k_100 = :k limit 10$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('distinct.order_by_limit', '{perf,planning,oltp}', $q$
select distinct k_10k from g_narrow where k_100 = :k order by k_10k desc limit 10$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('distinct.set_returning_function', '{perf,planning}', $q$
select distinct unnest(a_med) from g_array where id between :id and :id + 100$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('distinct.after_join_fan_out', '{perf,planning}', $q$
select distinct p.id, p.grp
from g_parent p join g_child c on c.parent_id = p.id
where p.id between :id and :id + 100$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.with_window_function', '{perf,planning}', $q$
select distinct entity_id, count(*) over (partition by entity_id) as n
from g_events where entity_id between :e and :e + 19$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('distinct.redundant_in_subquery', '{perf,planning,oltp}', $q$
select id, val from g_parent
where id in (select distinct parent_id from g_child where id between :id and :id + 50)$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('distinct.two_columns_whole_table', '{perf,planning,olap}', $q$
select count(*) from (select distinct k_100, k_10k from g_narrow) s$q$);

------------------------------------------------------------------------------
-- DISTINCT ON
------------------------------------------------------------------------------
call pgmb.reg('distinct.on_first_per_group', '{perf,planning,oltp}', $q$
select distinct on (parent_id) parent_id, id, seq, amount
from g_child where parent_id between :id and :id + 30
order by parent_id, seq desc, id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.on_two_keys', '{perf,planning}', $q$
select distinct on (parent_id, kind) parent_id, kind, id, amount
from g_child where parent_id between :id and :id + 30
order by parent_id, kind, amount desc, id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.on_latest_event', '{perf,planning}', $q$
select distinct on (entity_id) entity_id, ts, val
from g_events where entity_id between :e and :e + 19
order by entity_id, ts desc$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('distinct.on_expression', '{perf,planning}', $q$
select distinct on (k_10k / 1000) k_10k / 1000 as bucket, id, k_10k
from g_narrow where id between :id and :id + 2000
order by k_10k / 1000, k_10k, id$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- GROUP BY as DISTINCT
------------------------------------------------------------------------------
call pgmb.reg('distinct.group_by_functional_dependency', '{perf,planning}', $q$
select p.id, p.name, p.grp, count(c.id)
from g_parent p left join g_child c on c.parent_id = p.id
where p.id between :id and :id + 50
group by p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.group_by_position_and_expression', '{perf,planning}', $q$
select k_100 % 10, k_skew > 0, count(*) from g_narrow where id between :id and :id + 5000 group by 1, 2$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.group_by_distinct_rollup', '{perf,planning}', $q$
select cat, entity_id % 4 as e4, count(*)
from g_events where entity_id between :e and :e + 19
group by distinct rollup (cat), rollup (cat, entity_id % 4)$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('distinct.group_by_having_single', '{perf,planning}', $q$
select parent_id from g_child where parent_id between :id and :id + 200
group by parent_id having count(distinct kind) = 1$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- set operations
------------------------------------------------------------------------------
call pgmb.reg('distinct.union_two_tables', '{perf,planning}', $q$
select grp from g_parent where id between :id and :id + 500
union
select kind from g_child where parent_id between :id and :id + 500$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.intersect_and_except', '{perf,planning}', $q$
(select k_10k from g_narrow where id between :id and :id + 3000
 intersect
 select k_10k from g_narrow where id between :id + 3001 and :id + 6000)
except
select k_10k from g_narrow where k_100 = 0$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.union_all_then_distinct', '{perf,planning}', $q$
select distinct k from (
    select grp as k from g_parent where id between :id and :id + 500
    union all
    select kind from g_child where parent_id between :id and :id + 500) u$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- DISTINCT inside aggregates
------------------------------------------------------------------------------
-- counting distinct values, three ways
call pgmb.reg('distinct.count_aggregate', '{perf,planning,consistency}', $q$
select count(distinct k_10k) from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.count');

call pgmb.reg('distinct.count_over_select_distinct', '{perf,planning,consistency}', $q$
select count(*) from (select distinct k_10k from g_narrow where id between :id and :id + 5000) s$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.count');

call pgmb.reg('distinct.count_over_group_by', '{perf,planning,consistency}', $q$
select count(*) from (select k_10k from g_narrow where id between :id and :id + 5000 group by k_10k) s$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'distinct.count');

call pgmb.reg('distinct.count_three_columns', '{perf,planning}', $q$
select count(distinct k_100), count(distinct k_10k), count(distinct k_skew), count(*)
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.count_grouped', '{perf,planning}', $q$
select k_100, count(distinct k_skew), count(distinct k_null)
from g_narrow where id between :id and :id + 5000 group by k_100$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.count_with_filter', '{perf,planning}', $q$
select parent_id,
       count(distinct kind) as kinds,
       count(distinct kind) filter (where amount > 500) as big_kinds
from g_child where parent_id between :id and :id + 50 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.count_row_value', '{perf,planning}', $q$
select count(distinct (k_100, k_skew)) from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.count_presorted_by_index', '{perf,planning}', $q$
select count(distinct k_10k) from g_narrow where k_100 = :k$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('distinct.count_whole_table_unique', '{perf,planning,olap}', $q$
select count(distinct k_uniq), count(distinct k_10k) from g_narrow$q$);

call pgmb.reg('distinct.sum_avg', '{perf,planning}', $q$
select sum(distinct amount), avg(distinct amount), sum(amount), avg(amount)
from g_child where parent_id between :id and :id + 50$q$,
    setup => '\set id random(1, :n_g_parent)');

-- array of distinct values, three ways
call pgmb.reg('distinct.array_agg_distinct', '{perf,planning,consistency,oltp}', $q$
select coalesce(array_agg(distinct kind order by kind), '{}') from g_child where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'distinct.array');

call pgmb.reg('distinct.array_subquery_distinct', '{perf,planning,consistency,oltp}', $q$
select array(select distinct kind from g_child where parent_id = :id order by kind)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'distinct.array');

call pgmb.reg('distinct.array_agg_over_group_by', '{perf,planning,consistency,oltp}', $q$
select coalesce(array_agg(kind order by kind), '{}')
from (select kind from g_child where parent_id = :id group by kind) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'distinct.array');

call pgmb.reg('distinct.array_agg_grouped', '{perf,planning}', $q$
select parent_id, array_agg(distinct kind), array_agg(distinct seq % 10 order by seq % 10 desc)
from g_child where parent_id between :id and :id + 50 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.array_agg_distinct_vs_all', '{perf,planning}', $q$
select cardinality(array_agg(distinct k_10k)), cardinality(array_agg(k_10k))
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('distinct.string_agg', '{perf,planning}', $q$
select grp, string_agg(distinct status::text, ',' order by status::text)
from g_parent where id between :id and :id + 500 group by grp$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.jsonb_agg', '{perf,planning}', $q$
select parent_id, jsonb_agg(distinct kind), jsonb_agg(distinct jsonb_build_object('k', kind, 'big', amount > 500))
from g_child where parent_id between :id and :id + 30 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('distinct.array_elements', '{perf,planning}', $q$
select count(distinct x), count(x), array_length(array_agg(distinct x), 1)
from g_array, unnest(a_med) as x where id between :id and :id + 100$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('distinct.array_dedup_one_value', '{perf,planning,oltp}', $q$
select array(select distinct x from unnest(a) as x order by x) from g_array_big where id = :id$q$,
    setup => '\set id random(1, :n_g_array_big)');

call pgmb.reg('distinct.aggregate_in_window_emulation', '{perf,planning}', $q$
select id, entity_id,
       (select count(distinct x.cat) from g_events x where x.entity_id = e.entity_id and x.ts <= e.ts) as cats_so_far
from g_events e where e.entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)');

------------------------------------------------------------------------------
-- writes
------------------------------------------------------------------------------
call pgmb.reg('distinct.update_from_distinct', '{perf,planning,oltp}', $q$
update g_parent set val = val + 1
where id in (select distinct parent_id from g_child where id between :id and :id + 5)$q$,
    kind => 'write', setup => '\set id random(1, :n_g_child)');

------------------------------------------------------------------------------
-- errors
------------------------------------------------------------------------------
call pgmb.reg('distinct.err_order_by_not_selected', '{errors}',
    $q$select distinct k_100 from g_narrow order by k_10k$q$, expect_error => '42P10');
call pgmb.reg('distinct.err_on_order_mismatch', '{errors}',
    $q$select distinct on (k_100) k_100, id from g_narrow order by id$q$, expect_error => '42P10');
call pgmb.reg('distinct.err_aggregate_order_mismatch', '{errors}',
    $q$select array_agg(distinct kind order by amount) from g_child$q$, expect_error => '42P10');
call pgmb.reg('distinct.err_window_aggregate', '{errors}',
    $q$select count(distinct cat) over () from g_events$q$, expect_error => '0A000');
call pgmb.reg('distinct.err_no_equality_operator', '{errors}',
    $q$select distinct j from (select '{}'::json as j) s$q$, expect_error => '42883');
