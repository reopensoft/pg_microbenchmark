-- Topic: cte (part 21) - row estimates across the CTE boundary.
-- A materialized CTE is planned on its own and read through a CTE Scan. What
-- the outer query knows about its rows decides the plans above it: how many
-- rows a filter keeps, which join method and order follow, whether a sort is
-- needed. Every test carries the tag "analyze": the run stores the worst ratio
-- between estimated and actual rows over the plan nodes (q-error) next to the
-- timing, and the usual pair is the inlined form against the MATERIALIZED one.
-- Columns of g_narrow: k_100 uniform, k_skew heavily skewed towards 0,
-- k_corr correlated with the physical order, k_null half NULL.

------------------------------------------------------------------------------
-- filters above the CTE
------------------------------------------------------------------------------
-- plain column, equality: the column statistics can be found through the CTE
call pgmb.reg('cte.est_filter_equality_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, k_100, k_skew from g_narrow)
select count(*) from c where k_100 = :v$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.est_eq');

call pgmb.reg('cte.est_filter_equality_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_100, k_skew from g_narrow)
select count(*) from c where k_100 = :v$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.est_eq');

-- skewed column: the frequent value and a rare one
call pgmb.reg('cte.est_filter_skew_frequent_value_inlined', '{perf,planning,analyze}', $q$
with c as (select id, k_100, k_skew from g_narrow)
select count(*) from c where k_skew = 0$q$);

call pgmb.reg('cte.est_filter_skew_frequent_value_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100, k_skew from g_narrow)
select count(*) from c where k_skew = 0$q$);

call pgmb.reg('cte.est_filter_skew_rare_value_inlined', '{perf,planning,analyze}', $q$
with c as (select id, k_100, k_skew from g_narrow)
select count(*) from c where k_skew = :v$q$,
    setup => '\set v random(700, 999)');

call pgmb.reg('cte.est_filter_skew_rare_value_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100, k_skew from g_narrow)
select count(*) from c where k_skew = :v$q$,
    setup => '\set v random(700, 999)');

-- range, NULL test, pattern
call pgmb.reg('cte.est_filter_range_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_10k, k_null, pad from g_narrow)
select count(*) from c where k_10k between :v and :v + 99$q$,
    setup => '\set v random(0, 9900)');

call pgmb.reg('cte.est_filter_is_null_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_10k, k_null, pad from g_narrow)
select count(*) from c where k_null is null$q$);

call pgmb.reg('cte.est_filter_like_prefix_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_10k, k_null, pad from g_narrow)
select count(*) from c where pad like 'a%'$q$);

-- the column is an expression in the CTE: no statistics to look up
call pgmb.reg('cte.est_filter_on_expression_column_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, k_100 + 0 as k from g_narrow)
select count(*) from c where k = :v$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.est_expr');

call pgmb.reg('cte.est_filter_on_expression_column_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_100 + 0 as k from g_narrow)
select count(*) from c where k = :v$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.est_expr');

-- two conditions on correlated columns (id and k_corr move together)
call pgmb.reg('cte.est_filter_correlated_columns_inlined', '{perf,planning,analyze}', $q$
with c as (select id, k_corr from g_narrow)
select count(*) from c where id between :id and :id + 999 and k_corr between :id / 10 and :id / 10 + 109$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.est_filter_correlated_columns_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_corr from g_narrow)
select count(*) from c where id between :id and :id + 999 and k_corr between :id / 10 and :id / 10 + 109$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- the filter is inside the CTE: its own estimate travels up unchanged
call pgmb.reg('cte.est_filter_inside_cte_skew_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100 from g_narrow where k_skew = 0)
select count(*) from c where k_100 = :v$q$,
    setup => '\set v random(0, 99)');

------------------------------------------------------------------------------
-- what kind of CTE the estimate comes from
------------------------------------------------------------------------------
call pgmb.reg('cte.est_output_group_by_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select k_10k, count(*) as n from g_narrow group by k_10k)
select count(*) from c where n > 1$q$);

call pgmb.reg('cte.est_output_group_by_two_columns_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select k_100, k_skew, count(*) as n from g_narrow group by k_100, k_skew)
select count(*) from c$q$);

call pgmb.reg('cte.est_output_distinct_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select distinct k_skew from g_narrow)
select count(*) from c$q$);

call pgmb.reg('cte.est_output_union_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select k_100 as k from g_narrow union select k_skew from g_narrow)
select count(*) from c$q$);

call pgmb.reg('cte.est_output_join_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select p.id, ch.kind from g_parent p join g_child ch on ch.parent_id = p.id where p.grp = :g)
select count(*) from c where kind = 3$q$,
    setup => '\set g random(0, 99)');

-- set-returning functions have a fixed default estimate
call pgmb.reg('cte.est_output_generate_series_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select g as id from generate_series(1, 50000) g)
select count(*) from c join g_narrow n using (id)$q$);

call pgmb.reg('cte.est_output_unnest_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, unnest(arr100) as v from g_intarr where id between :id and :id + 99)
select count(*) from c where v < 50000$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- a recursive CTE is estimated at ten times its non-recursive term
call pgmb.reg('cte.est_output_recursive_counter', '{perf,planning,analyze}', $q$
with recursive c(n) as (select 1 union all select n + 1 from c where n < 5000)
select count(*) from c join g_narrow g on g.id = c.n$q$);

call pgmb.reg('cte.est_output_recursive_tree', '{perf,planning,analyze}', $q$
with recursive c as (
    select id, parent_id from g_tree where id = :id
    union all
    select t.id, t.parent_id from g_tree t join c on t.parent_id = c.id)
select count(*) from c join g_narrow g on g.id = c.id$q$,
    setup => '\set id random(1, :n_g_tree / 64 + 1)');

-- a window function and LIMIT in the CTE
call pgmb.reg('cte.est_output_limit_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100 from g_narrow order by id limit 1000)
select count(*) from c where k_100 = :v$q$,
    setup => '\set v random(0, 99)');

call pgmb.reg('cte.est_output_window_rank_filter', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100, row_number() over (partition by k_100 order by id) as rn from g_narrow)
select count(*) from c where rn <= 3$q$);

------------------------------------------------------------------------------
-- estimates feeding a join
------------------------------------------------------------------------------
-- the number of rows surviving the filter decides nested loop or hash join
call pgmb.reg('cte.est_join_after_selective_filter_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v$q$,
    setup => '\set v random(700, 999)', equiv => 'cte.est_join_sel');

call pgmb.reg('cte.est_join_after_selective_filter_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = :v$q$,
    setup => '\set v random(700, 999)', equiv => 'cte.est_join_sel');

call pgmb.reg('cte.est_join_after_unselective_filter_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = 0$q$,
    equiv => 'cte.est_join_unsel');

call pgmb.reg('cte.est_join_after_unselective_filter_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_skew from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k_skew = 0$q$,
    equiv => 'cte.est_join_unsel');

-- a filter on an expression column is guessed: the join above follows the guess
call pgmb.reg('cte.est_join_after_expression_filter_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_skew + 0 as k from g_narrow)
select count(*) from c join g_wide w on w.id = c.id where c.k = 0$q$);

-- join key: number of distinct values of a CTE column
call pgmb.reg('cte.est_join_on_low_cardinality_key_inlined', '{perf,planning,analyze}', $q$
with c as (select id, k_100 from g_narrow where id between :id and :id + 999)
select count(*) from c join g_dim d on d.id = c.k_100 + 1$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.est_join_on_low_cardinality_key_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100 from g_narrow where id between :id and :id + 999)
select count(*) from c join g_dim d on d.id = c.k_100 + 1$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- two CTEs joined to each other on a grouped key
call pgmb.reg('cte.est_join_two_aggregated_ctes', '{perf,planning,analyze}', $q$
with a as materialized (select k_10k, count(*) as n from g_narrow group by k_10k),
     b as materialized (select k_10k, max(id) as last_id from g_narrow where k_100 < 50 group by k_10k)
select count(*) from a join b using (k_10k)$q$);

-- the error grows level by level
call pgmb.reg('cte.est_chain_three_levels_inlined', '{perf,planning,analyze,consistency}', $q$
with a as (select id, k_100 + 0 as k, k_skew + 0 as s from g_narrow),
     b as (select id, k, s from a where k < 50),
     c as (select id, k, s from b where s = 0)
select count(*) from c join g_wide w on w.id = c.id$q$, equiv => 'cte.est_chain');

call pgmb.reg('cte.est_chain_three_levels_materialized', '{perf,planning,analyze,consistency}', $q$
with a as materialized (select id, k_100 + 0 as k, k_skew + 0 as s from g_narrow),
     b as materialized (select id, k, s from a where k < 50),
     c as materialized (select id, k, s from b where s = 0)
select count(*) from c join g_wide w on w.id = c.id$q$, equiv => 'cte.est_chain');

-- join order among three inputs when one of them is a mis-sized CTE
call pgmb.reg('cte.est_join_order_three_inputs_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, k_skew + 0 as k from g_narrow)
select count(*) from c join g_parent p on p.id = c.id join g_child ch on ch.parent_id = p.id where c.k = :v$q$,
    setup => '\set v random(700, 999)', equiv => 'cte.est_order');

call pgmb.reg('cte.est_join_order_three_inputs_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_skew + 0 as k from g_narrow)
select count(*) from c join g_parent p on p.id = c.id join g_child ch on ch.parent_id = p.id where c.k = :v$q$,
    setup => '\set v random(700, 999)', equiv => 'cte.est_order');

------------------------------------------------------------------------------
-- sort order carried out of the CTE
------------------------------------------------------------------------------
-- the CTE is already sorted the way the reader wants it
call pgmb.reg('cte.est_order_reused_by_outer_order_by_inlined', '{perf,planning,analyze}', $q$
with c as (select id, k_100 from g_narrow where id between :id and :id + 4999 order by id)
select count(*) from (select id from c order by id offset 0) s$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.est_order_reused_by_outer_order_by_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100 from g_narrow where id between :id and :id + 4999 order by id)
select count(*) from (select id from c order by id offset 0) s$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- sorted on one key in the CTE, asked for two: incremental sort, or everything again
call pgmb.reg('cte.est_order_prefix_reused_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select id, k_100, k_10k from g_narrow where id between :id and :id + 4999 order by k_100)
select count(*) from (select id from c order by k_100, k_10k offset 0) s$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- two sorted CTEs joined on the sort key: merge join without sorting
call pgmb.reg('cte.est_order_reused_by_merge_join_materialized', '{perf,planning,analyze}', $q$
with a as materialized (select id, k_100 from g_narrow where id between :id and :id + 4999 order by id),
     b as materialized (select id, i3 from g_wide where id between :id and :id + 4999 order by id)
select count(*) from a join b using (id)$q$,
    setup => '\set id random(1, :n_g_wide)');

-- grouped on the sort key: aggregation in one pass
call pgmb.reg('cte.est_order_reused_by_group_by_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select k_10k, id from g_narrow where id between :id and :id + 4999 order by k_10k)
select count(*) from (select k_10k, count(*) from c group by k_10k) s$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- DISTINCT in the CTE: the reader knows the column is unique
call pgmb.reg('cte.est_unique_output_join_materialized', '{perf,planning,analyze}', $q$
with c as materialized (select distinct k_10k from g_narrow)
select count(*) from g_narrow n join c using (k_10k) where n.id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_narrow)');
