-- Topic: cte (part 27) - edge cases, systematically: every case as an inlined
-- and as a MATERIALIZED CTE, with results compared.
--   zero rows, one row, millions of rows; rows made of NULLs, duplicates,
--   arrays, JSONB documents and wide text; many references; nested loops that
--   rescan the CTE; CTEs nobody reads; LIMIT, EXISTS and conditionally executed
--   subplans; and the final ORDER BY, checked without relying on any order the
--   CTE itself may have produced.
-- "Millions" follow data_scale: generate_series(1, 5 x rows of g_narrow) is
-- 50,000 rows at scale 0.01 and 5,000,000 at scale 1.

------------------------------------------------------------------------------
-- R01. a CTE that returns no rows
------------------------------------------------------------------------------
-- aggregates over nothing: one row of zero and NULLs
call pgmb.reg('cte.edge_zero_aggregates_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select id, val from g_parent where id < 0)
select count(*), count(val), sum(val), min(id), array_agg(id), coalesce(sum(val), 0), array(select id from c) from c$q$,
    equiv => 'cte.edge_zero_agg');

call pgmb.reg('cte.edge_zero_aggregates_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select id, val from g_parent where id < 0)
select count(*), count(val), sum(val), min(id), array_agg(id), coalesce(sum(val), 0), array(select id from c) from c$q$,
    equiv => 'cte.edge_zero_agg');

-- empty by a constant: the planner removes the scan altogether
call pgmb.reg('cte.edge_zero_aggregates_constant_false', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select id, val from g_parent where false)
select count(*), count(val), sum(val), min(id), array_agg(id), coalesce(sum(val), 0), array(select id from c) from c$q$,
    equiv => 'cte.edge_zero_agg');

-- grouped: no groups, so no rows at all
call pgmb.reg('cte.edge_zero_group_by_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select grp, val from g_parent where id < 0)
select count(*) from (select grp, sum(val) from c group by grp) s$q$, equiv => 'cte.edge_zero_group');

call pgmb.reg('cte.edge_zero_group_by_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select grp, val from g_parent where id < 0)
select count(*) from (select grp, sum(val) from c group by grp) s$q$, equiv => 'cte.edge_zero_group');

-- joins: inner and cross give nothing, an outer join from the other side keeps its rows
call pgmb.reg('cte.edge_zero_joins_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select id, val from g_parent where id < 0)
select (select count(*) from g_dim d join c on c.id = d.id) as inner_join,
       (select count(*) from g_dim d cross join c) as cross_join,
       (select count(*) from g_dim d left join c on c.id = d.id) = (select count(*) from g_dim) as left_join_keeps_all,
       (select count(c.id) from g_dim d left join c on c.id = d.id) as matched,
       (select count(*) from c left join g_dim d on d.id = c.id) as left_join_from_empty,
       (select count(*) from c full join c c2 on c2.id = c.id) as full_join_of_empties$q$,
    equiv => 'cte.edge_zero_joins');

call pgmb.reg('cte.edge_zero_joins_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select id, val from g_parent where id < 0)
select (select count(*) from g_dim d join c on c.id = d.id) as inner_join,
       (select count(*) from g_dim d cross join c) as cross_join,
       (select count(*) from g_dim d left join c on c.id = d.id) = (select count(*) from g_dim) as left_join_keeps_all,
       (select count(c.id) from g_dim d left join c on c.id = d.id) as matched,
       (select count(*) from c left join g_dim d on d.id = c.id) as left_join_from_empty,
       (select count(*) from c full join c c2 on c2.id = c.id) as full_join_of_empties$q$,
    equiv => 'cte.edge_zero_joins');

-- quantifiers over the empty set: IN false, NOT IN true, ALL true, ANY false, a scalar subquery NULL
call pgmb.reg('cte.edge_zero_quantifiers_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select id from g_parent where id < 0)
select 1 in (select id from c) as in_empty, 1 not in (select id from c) as not_in_empty,
       1 > all (select id from c) as all_empty, 1 = any (select id from c) as any_empty,
       exists (select 1 from c) as exists_empty, not exists (select 1 from c) as not_exists_empty,
       (select id from c) is null as scalar_is_null, (select max(id) from c) is null as max_is_null$q$,
    equiv => 'cte.edge_zero_quant');

call pgmb.reg('cte.edge_zero_quantifiers_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select id from g_parent where id < 0)
select 1 in (select id from c) as in_empty, 1 not in (select id from c) as not_in_empty,
       1 > all (select id from c) as all_empty, 1 = any (select id from c) as any_empty,
       exists (select 1 from c) as exists_empty, not exists (select 1 from c) as not_exists_empty,
       (select id from c) is null as scalar_is_null, (select max(id) from c) is null as max_is_null$q$,
    equiv => 'cte.edge_zero_quant');

-- NOT IN an empty CTE keeps every row of the table, NULLs included
call pgmb.reg('cte.edge_zero_not_in_keeps_all_rows', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select k_null from g_narrow where id < 0)
select count(*) from g_narrow where id between :id and :id + 999 and k_null not in (select k_null from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.edge_zero_not_in');

call pgmb.reg('cte.edge_zero_not_in_baseline', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_narrow where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.edge_zero_not_in');

-- set operations and windows over nothing
call pgmb.reg('cte.edge_zero_set_operations', '{perf,planning,analyze,consistency,oltp}', $q$
with e as materialized (select id from g_parent where id < 0),
     f as materialized (select id from g_parent where id between :id and :id + 9)
select (select count(*) from (select id from e union all select id from f) u) as union_all,
       (select count(*) from (select id from e union select id from e) u) as union_of_empties,
       (select count(*) from (select id from f intersect select id from e) u) as intersect_empty,
       (select count(*) from (select id from f except select id from e) u) as except_empty,
       (select count(*) from (select id, row_number() over () from e) w) as window_over_empty$q$,
    setup => '\set id random(1, :n_g_parent - 10)', equiv => 'cte.edge_zero_setops');

call pgmb.reg('cte.edge_zero_set_operations_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with e as (select id from g_parent where id < 0),
     f as (select id from g_parent where id between :id and :id + 9)
select (select count(*) from (select id from e union all select id from f) u) as union_all,
       (select count(*) from (select id from e union select id from e) u) as union_of_empties,
       (select count(*) from (select id from f intersect select id from e) u) as intersect_empty,
       (select count(*) from (select id from f except select id from e) u) as except_empty,
       (select count(*) from (select id, row_number() over () from e) w) as window_over_empty$q$,
    setup => '\set id random(1, :n_g_parent - 10)', equiv => 'cte.edge_zero_setops');

-- recursion from an empty start, and a chain that becomes empty in the middle
call pgmb.reg('cte.edge_zero_recursive_empty_start', '{perf,planning,analyze,oltp}', $q$
with recursive r as (
    select id, parent_id from g_tree where id < 0
    union all
    select t.id, t.parent_id from g_tree t join r on t.parent_id = r.id)
select count(*) from r$q$);

call pgmb.reg('cte.edge_zero_chain_empty_in_the_middle', '{perf,planning,analyze,consistency}', $q$
with a as materialized (select id, grp, val from g_parent where id between :id and :id + 999),
     b as materialized (select id, grp, val from a where grp < 0),
     c as materialized (select grp, sum(val) as total from b group by grp),
     d as materialized (select c.grp, c.total, a.id from c join a on a.grp = c.grp)
select count(*) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_zero_chain');

call pgmb.reg('cte.edge_zero_chain_empty_in_the_middle_inlined', '{perf,planning,analyze,consistency}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 999),
     b as (select id, grp, val from a where grp < 0),
     c as (select grp, sum(val) as total from b group by grp),
     d as (select c.grp, c.total, a.id from c join a on a.grp = c.grp)
select count(*) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_zero_chain');

-- writers fed by nothing
call pgmb.reg('cte.edge_zero_feeds_writers', '{perf,planning,analyze,oltp}', $q$
with nothing as (select id, val from g_parent where id < 0),
     ins as (insert into g_dml_audit (dml_id, action, qty) select id, 'never', 0 from nothing returning id),
     upd as (update g_parent p set val = p.val + 1 from nothing n where p.id = n.id returning p.id)
select (select count(*) from ins), (select count(*) from upd)$q$,
    kind => 'write');

------------------------------------------------------------------------------
-- R02. a CTE that returns one row
------------------------------------------------------------------------------
call pgmb.reg('cte.edge_one_row_as_scalar_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select id, val, grp from g_parent where id = :id)
select (select val from c), (select grp from c), (select count(*) from c), exists (select 1 from c)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_one_scalar');

call pgmb.reg('cte.edge_one_row_as_scalar_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select id, val, grp from g_parent where id = :id)
select (select val from c), (select grp from c), (select count(*) from c), exists (select 1 from c)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_one_scalar');

-- the "parameters" pattern: one row of constants cross-joined into the query
call pgmb.reg('cte.edge_one_row_parameters_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with params as (select :id::bigint as lo, :id::bigint + 99 as hi, 50 as max_grp)
select count(*), sum(p.val) from g_parent p, params where p.id between params.lo and params.hi and p.grp < params.max_grp$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_one_params');

call pgmb.reg('cte.edge_one_row_parameters_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with params as materialized (select :id::bigint as lo, :id::bigint + 99 as hi, 50 as max_grp)
select count(*), sum(p.val) from g_parent p, params where p.id between params.lo and params.hi and p.grp < params.max_grp$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_one_params');

call pgmb.reg('cte.edge_one_row_parameters_as_literals', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(p.val) from g_parent p where p.id between :id and :id + 99 and p.grp < 50$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_one_params');

-- one row driving an index join into a large table
call pgmb.reg('cte.edge_one_row_drives_join_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select id from g_parent where id = :id)
select count(*), sum(ch.amount) from c join g_child ch on ch.parent_id = c.id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_one_join');

call pgmb.reg('cte.edge_one_row_drives_join_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select id from g_parent where id = :id)
select count(*), sum(ch.amount) from c join g_child ch on ch.parent_id = c.id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_one_join');

-- an aggregate without GROUP BY is always exactly one row, even over nothing
call pgmb.reg('cte.edge_one_row_from_aggregate_over_nothing', '{perf,planning,analyze,oltp}', $q$
with c as materialized (select count(*) as n, sum(val) as total from g_parent where id < 0)
select n, total is null, (select count(*) from c) as rows_in_cte from c$q$);

-- one row from VALUES, from a function, from LIMIT 1
call pgmb.reg('cte.edge_one_row_sources', '{perf,planning,analyze,oltp}', $q$
with v(x) as (values (1)),
     f(x) as (select * from generate_series(1, 1)),
     l(x) as (select id from g_parent order by id limit 1),
     n(x) as (select 1 where true)
select v.x + f.x + l.x + n.x from v, f, l, n$q$);

-- a scalar subquery over a CTE with two rows is an error at run time
call pgmb.reg('cte.err_edge_scalar_subquery_two_rows', '{errors}',
    $q$with c as (select id from g_parent where id in (1, 2)) select (select id from c)$q$, expect_error => '21000');
call pgmb.reg('cte.err_edge_scalar_subquery_two_rows_materialized', '{errors}',
    $q$with c as materialized (select id from g_parent where id in (1, 2)) select (select id from c)$q$, expect_error => '21000');
-- ... but not when the subquery is never evaluated
call pgmb.reg('cte.edge_scalar_subquery_two_rows_not_evaluated', '{perf,planning,analyze,oltp}', $q$
with c as materialized (select id from g_parent where id in (1, 2))
select case when d.id < 0 then (select id from c) else -1 end from g_dim d where d.id = 1$q$);

------------------------------------------------------------------------------
-- R03. millions of rows (5 x the rows of g_narrow)
------------------------------------------------------------------------------
call pgmb.reg('cte.edge_millions_count_inlined', '{perf,planning,analyze,consistency,olap}', $q$
with c as (select g as n from generate_series(1, :n_g_narrow * 5) g)
select count(*), sum(n) from c$q$, equiv => 'cte.edge_millions_count');

call pgmb.reg('cte.edge_millions_count_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select g as n from generate_series(1, :n_g_narrow * 5) g)
select count(*), sum(n) from c$q$, equiv => 'cte.edge_millions_count');

-- the rows are produced in the select list instead: no function-scan store underneath
call pgmb.reg('cte.edge_millions_count_from_select_list_srf', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select generate_series(1, :n_g_narrow * 5) as n)
select count(*), sum(n) from c$q$, equiv => 'cte.edge_millions_count');

call pgmb.reg('cte.edge_millions_group_by_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select g as n, g % 1000 as k from generate_series(1, :n_g_narrow * 5) g)
select count(*), sum(cnt) from (select k, count(*) as cnt from c group by k) s$q$, equiv => 'cte.edge_millions_group');

call pgmb.reg('cte.edge_millions_group_by_inlined', '{perf,planning,analyze,consistency,olap}', $q$
with c as (select g as n, g % 1000 as k from generate_series(1, :n_g_narrow * 5) g)
select count(*), sum(cnt) from (select k, count(*) as cnt from c group by k) s$q$, equiv => 'cte.edge_millions_group');

call pgmb.reg('cte.edge_millions_join_to_table_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select g as n from generate_series(1, :n_g_narrow * 5) g)
select count(*), sum(t.k_100) from c join g_narrow t on t.id = c.n$q$, equiv => 'cte.edge_millions_join');

call pgmb.reg('cte.edge_millions_join_to_table_inlined', '{perf,planning,analyze,consistency,olap}', $q$
with c as (select g as n from generate_series(1, :n_g_narrow * 5) g)
select count(*), sum(t.k_100) from c join g_narrow t on t.id = c.n$q$, equiv => 'cte.edge_millions_join');

call pgmb.reg('cte.edge_millions_top_10_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select g as n, (g * 7919) % 1000003 as h from generate_series(1, :n_g_narrow * 5) g)
select array(select n from c order by h desc, n limit 10)$q$, equiv => 'cte.edge_millions_top');

call pgmb.reg('cte.edge_millions_top_10_inlined', '{perf,planning,analyze,consistency,olap}', $q$
with c as (select g as n, (g * 7919) % 1000003 as h from generate_series(1, :n_g_narrow * 5) g)
select array(select n from c order by h desc, n limit 10)$q$, equiv => 'cte.edge_millions_top');

-- two readers of millions of rows; a reader that needs ten of them
call pgmb.reg('cte.edge_millions_two_readers', '{perf,planning,analyze,olap}', $q$
with c as (select g as n from generate_series(1, :n_g_narrow * 5) g)
select (select count(*) from c), (select max(n) from c)$q$);

call pgmb.reg('cte.edge_millions_limit_10', '{perf,planning,analyze,oltp}', $q$
with c as materialized (select generate_series(1, :n_g_narrow * 5) as n)
select count(*) from (select n from c limit 10) s$q$);

-- the whole of a real table through a CTE, twice
call pgmb.reg('cte.edge_whole_table_self_join_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select id, k_100 from g_narrow)
select count(*), sum(a.k_100 + b.k_100) from c a join c b on b.id = a.id + 1$q$, equiv => 'cte.edge_whole_self');

call pgmb.reg('cte.edge_whole_table_self_join_inlined', '{perf,planning,analyze,consistency,olap}', $q$
with c as not materialized (select id, k_100 from g_narrow)
select count(*), sum(a.k_100 + b.k_100) from c a join c b on b.id = a.id + 1$q$, equiv => 'cte.edge_whole_self');

------------------------------------------------------------------------------
-- R04. what the rows are made of: NULLs, duplicates, arrays, JSONB, wide text
------------------------------------------------------------------------------
-- nothing but NULLs
call pgmb.reg('cte.edge_content_all_nulls_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select null::int as k, null::text as t from g_parent where id between :id and :id + 999)
select count(*), count(k), count(distinct k), max(t), (select count(*) from (select distinct k, t from c) d) as distinct_rows,
       (select count(*) from c a join c b on b.k = a.k) as joined_on_null,
       (select count(*) from c a join c b on b.k is not distinct from a.k) > 0 as joined_null_safe,
       (select count(*) from (select k from c group by k) g) as groups
from c$q$,
    setup => '\set id random(1, :n_g_parent / 2)', equiv => 'cte.edge_nulls');

call pgmb.reg('cte.edge_content_all_nulls_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select null::int as k, null::text as t from g_parent where id between :id and :id + 999)
select count(*), count(k), count(distinct k), max(t), (select count(*) from (select distinct k, t from c) d) as distinct_rows,
       (select count(*) from c a join c b on b.k = a.k) as joined_on_null,
       (select count(*) from c a join c b on b.k is not distinct from a.k) > 0 as joined_null_safe,
       (select count(*) from (select k from c group by k) g) as groups
from c$q$,
    setup => '\set id random(1, :n_g_parent / 2)', equiv => 'cte.edge_nulls');

-- nothing but duplicates of a few rows
call pgmb.reg('cte.edge_content_duplicates_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id % 3 as k, 'same'::text as t from g_parent where id between :id and :id + 999)
select count(*), count(distinct k), (select count(*) from (select k, t from c union select k, t from c) u) as after_union,
       (select count(*) from (select distinct k, t from c) d) as after_distinct,
       (select count(*) from c a join c b using (k)) as join_fan_out,
       (select count(*) from (select k from c intersect all select k from c) i) as intersect_all,
       (select count(*) from (select k from c except all select k from c where k = 0) e) as except_all
from c$q$,
    setup => '\set id random(1, :n_g_parent / 2)', equiv => 'cte.edge_dups');

call pgmb.reg('cte.edge_content_duplicates_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id % 3 as k, 'same'::text as t from g_parent where id between :id and :id + 999)
select count(*), count(distinct k), (select count(*) from (select k, t from c union select k, t from c) u) as after_union,
       (select count(*) from (select distinct k, t from c) d) as after_distinct,
       (select count(*) from c a join c b using (k)) as join_fan_out,
       (select count(*) from (select k from c intersect all select k from c) i) as intersect_all,
       (select count(*) from (select k from c except all select k from c where k = 0) e) as except_all
from c$q$,
    setup => '\set id random(1, :n_g_parent / 2)', equiv => 'cte.edge_dups');

-- arrays (in detail: cte.array_*)
call pgmb.reg('cte.edge_content_arrays_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, arr10, arr_var, arr_nulls from g_intarr where id between :id and :id + 499)
select count(*), sum(cardinality(arr10)), count(*) filter (where arr_var = '{}'), count(arr_nulls),
       (select count(*) from c, unnest(arr10) v) as elements, (select count(distinct arr_var) from c) as distinct_arrays
from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.edge_arrays');

call pgmb.reg('cte.edge_content_arrays_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, arr10, arr_var, arr_nulls from g_intarr where id between :id and :id + 499)
select count(*), sum(cardinality(arr10)), count(*) filter (where arr_var = '{}'), count(arr_nulls),
       (select count(*) from c, unnest(arr10) v) as elements, (select count(distinct arr_var) from c) as distinct_arrays
from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.edge_arrays');

-- JSONB documents built per row
call pgmb.reg('cte.edge_content_jsonb_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, jsonb_build_object('id', id, 'grp', grp, 'name', name, 'tags', jsonb_build_array(grp % 3, status), 'val', val) as doc
           from g_parent where id between :id and :id + 499)
select count(*), sum((doc->>'grp')::int), count(*) filter (where doc @> '{"tags": [1]}'),
       count(*) filter (where doc ? 'name'), sum(jsonb_array_length(doc->'tags')),
       count(distinct doc->'tags'), sum(pg_column_size(doc)) > 0
from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_jsonb');

call pgmb.reg('cte.edge_content_jsonb_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, jsonb_build_object('id', id, 'grp', grp, 'name', name, 'tags', jsonb_build_array(grp % 3, status), 'val', val) as doc
           from g_parent where id between :id and :id + 499)
select count(*), sum((doc->>'grp')::int), count(*) filter (where doc @> '{"tags": [1]}'),
       count(*) filter (where doc ? 'name'), sum(jsonb_array_length(doc->'tags')),
       count(distinct doc->'tags'), sum(pg_column_size(doc)) > 0
from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_jsonb');

-- one large document aggregated from 1000 rows, then taken apart again
call pgmb.reg('cte.edge_content_jsonb_one_large_document', '{perf,planning,analyze,consistency}', $q$
with big as materialized (select jsonb_agg(jsonb_build_object('id', id, 'grp', grp, 'name', name) order by id) as doc
                          from g_parent where id between :id and :id + 999),
     items as (select e->>'name' as name, (e->>'grp')::int as grp from big, jsonb_array_elements(doc) e)
select (select jsonb_array_length(doc) from big), (select count(*) from items), (select sum(grp) from items),
       (select count(*) from big, jsonb_path_query(doc, '$[*] ? (@.grp < 10)') p)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_jsonb_big');

call pgmb.reg('cte.edge_content_jsonb_one_large_document_inlined', '{perf,planning,analyze,consistency}', $q$
with big as not materialized (select jsonb_agg(jsonb_build_object('id', id, 'grp', grp, 'name', name) order by id) as doc
                          from g_parent where id between :id and :id + 999),
     items as (select e->>'name' as name, (e->>'grp')::int as grp from big, jsonb_array_elements(doc) e)
select (select jsonb_array_length(doc) from big), (select count(*) from items), (select sum(grp) from items),
       (select count(*) from big, jsonb_path_query(doc, '$[*] ? (@.grp < 10)') p)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_jsonb_big');

-- JSONB as a value: grouped, deduplicated, joined on
call pgmb.reg('cte.edge_content_jsonb_as_key', '{perf,planning,analyze}', $q$
with c as materialized (select id, jsonb_build_object('g', grp % 10, 's', status) as k from g_parent where id between :id and :id + 999)
select (select count(*) from (select k from c group by k) g) as groups,
       (select count(*) from (select distinct k from c) d) as distinct_docs,
       (select count(*) from c a join c b on b.k = a.k and b.id = a.id + 1) as equal_neighbours$q$,
    setup => '\set id random(1, :n_g_parent)');

-- wide text: 10 kB per row
call pgmb.reg('cte.edge_content_wide_text_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, repeat(name, 435) as t from g_parent where id between :id and :id + 199)
select count(*), sum(length(t)), max(t) = max(repeat(name, 435)), count(*) filter (where t like '%parent 0%')
from c join g_parent p using (id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_wide_text');

call pgmb.reg('cte.edge_content_wide_text_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, repeat(name, 435) as t from g_parent where id between :id and :id + 199)
select count(*), sum(length(t)), max(t) = max(repeat(name, 435)), count(*) filter (where t like '%parent 0%')
from c join g_parent p using (id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_wide_text');

-- wide text read three times and sorted on
call pgmb.reg('cte.edge_content_wide_text_sorted_three_readers', '{perf,planning,analyze}', $q$
with c as materialized (select id, repeat(name, 435) as t from g_parent where id between :id and :id + 199)
select (select count(*) from c), (select sum(length(t)) from c), (select count(*) from (select id from c order by t offset 0) s)$q$,
    setup => '\set id random(1, :n_g_parent)');

-- every kind of content in one row
call pgmb.reg('cte.edge_content_mixed_row_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (
    select p.id, null::int as n, p.id % 2 as dup, array[p.grp, p.status] as arr,
           jsonb_build_object('grp', p.grp) as doc, repeat(p.name, 100) as wide
    from g_parent p where p.id between :id and :id + 199)
select count(*), count(n), count(distinct dup), sum(arr[1]), sum((doc->>'grp')::int), sum(length(wide)) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_mixed_row');

call pgmb.reg('cte.edge_content_mixed_row_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (
    select p.id, null::int as n, p.id % 2 as dup, array[p.grp, p.status] as arr,
           jsonb_build_object('grp', p.grp) as doc, repeat(p.name, 100) as wide
    from g_parent p where p.id between :id and :id + 199)
select count(*), count(n), count(distinct dup), sum(arr[1]), sum((doc->>'grp')::int), sum(length(wide)) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_mixed_row');

------------------------------------------------------------------------------
-- R05. many references to one CTE (100 scalar subqueries)
------------------------------------------------------------------------------
select format($f$call pgmb.reg('cte.edge_refs_100_%1$s_%2$s', '{perf,planning,analyze,consistency}', %3$L, setup => '\set id random(1, :n_g_parent - 100)', equiv => 'cte.edge_refs_%1$s')$f$, lbl, form,
              format('with c as %s(select id, val from g_parent where %s) select ', kw, cond)
              || (select string_agg(format('coalesce((select sum(val) from c where id %% 100 = %s), 0)', i), ' + ' order by i) from generate_series(0, 99) i))
from (values ('empty_cte', 'id < 0'), ('one_row_cte', 'id = :id'), ('100_row_cte', 'id between :id and :id + 99')) v(lbl, cond),
     (values ('default', ''), ('materialized', 'materialized '), ('not_materialized', 'not materialized ')) w(form, kw) \gexec

-- the same 100-row answer in one pass
call pgmb.reg('cte.edge_refs_100_100_row_cte_single_pass', '{perf,planning,analyze,consistency}', $q$
with c as (select id, val from g_parent where id between :id and :id + 99)
select coalesce(sum(val), 0) from c$q$,
    setup => '\set id random(1, :n_g_parent - 100)', equiv => 'cte.edge_refs_100_row_cte');

------------------------------------------------------------------------------
-- R06. a nested loop that rescans the CTE once per outer row
-- (hash and merge joins, Materialize and Memoize are switched off for the test;
-- a LEFT JOIN keeps the table on the outer side, so the CTE is the side that is rescanned)
------------------------------------------------------------------------------
\set pgmb_nl 'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\nset local enable_material = off;\nset local enable_memoize = off;\n'
\set pgmb_end ';\ncommit;'

select format($f$call pgmb.reg('cte.edge_rescan_%1$s_outer_rows_in_memory', '{perf,planning,analyze,consistency}', %2$L, setup => '\set id random(1, :n_g_narrow - 2000)', equiv => 'cte.edge_rescan_%1$s')$f$, n,
              :'pgmb_nl' || format($q$with inner_side as materialized (select id, k_100 from g_narrow where id between :id and :id + 999)
select count(i.id) from g_narrow o left join inner_side i on i.k_100 = o.k_100 where o.id between :id + 1000 and :id + %s$q$, 999 + n) || :'pgmb_end')
from (values (10), (100), (1000)) v(n) \gexec

-- the rescanned CTE lives in a temporary file
select format($f$call pgmb.reg('cte.edge_rescan_%1$s_outer_rows_spilled', '{perf,planning,analyze,consistency}', %2$L, setup => '\set id random(1, :n_g_narrow - 2000)', equiv => 'cte.edge_rescan_%1$s')$f$, n,
              :'pgmb_nl' || E'set local work_mem = ''64kB'';\n' || format($q$with inner_side as materialized (select id, k_100, pad || pad as pad2 from g_narrow where id between :id and :id + 999)
select count(i.id) from g_narrow o left join inner_side i on i.k_100 = o.k_100 where o.id between :id + 1000 and :id + %s$q$, 999 + n) || :'pgmb_end')
from (values (10), (100), (1000)) v(n) \gexec

-- the same join left to the planner
select format($f$call pgmb.reg('cte.edge_rescan_%1$s_outer_rows_planner_choice', '{perf,planning,analyze,consistency}', %2$L, setup => '\set id random(1, :n_g_narrow - 2000)', equiv => 'cte.edge_rescan_%1$s')$f$, n,
              format($q$with inner_side as materialized (select id, k_100 from g_narrow where id between :id and :id + 999)
select count(i.id) from g_narrow o left join inner_side i on i.k_100 = o.k_100 where o.id between :id + 1000 and :id + %s$q$, 999 + n))
from (values (10), (100), (1000)) v(n) \gexec

-- rescans of an empty and of a one-row CTE
call pgmb.reg('cte.edge_rescan_empty_inner', '{perf,planning,analyze}', :'pgmb_nl' || $q$
with inner_side as materialized (select id, k_100 from g_narrow where id < 0)
select count(i.id) from g_narrow o left join inner_side i on i.k_100 = o.k_100 where o.id between :id and :id + 999$q$ || :'pgmb_end',
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.edge_rescan_one_row_inner', '{perf,planning,analyze}', :'pgmb_nl' || $q$
with inner_side as materialized (select id, k_100 from g_narrow where id = :id)
select count(i.id) from g_narrow o left join inner_side i on i.k_100 = o.k_100 where o.id between :id and :id + 999$q$ || :'pgmb_end',
    setup => '\set id random(1, :n_g_narrow)');

-- the CTE on the outer side: read once, the table probed by index
call pgmb.reg('cte.edge_rescan_cte_on_outer_side', '{perf,planning,analyze}', :'pgmb_nl' || $q$
with outer_side as materialized (select id, k_100 from g_narrow where id between :id and :id + 999)
select count(*) from outer_side o join g_wide ch on ch.id = o.id$q$ || :'pgmb_end',
    setup => '\set id random(1, :n_g_narrow)');

-- a correlated subplan rescanning the CTE for every row
call pgmb.reg('cte.edge_rescan_correlated_subplan', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from c o where o.k_10k >= (select max(i.k_10k) from c i where i.k_100 = o.k_100)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.edge_rescan_corr');

call pgmb.reg('cte.edge_rescan_correlated_as_window', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from (select k_10k as val, max(k_10k) over (partition by k_100) as mx from c) s where val >= mx$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.edge_rescan_corr');

-- the inner side is two CTE scans deep: a nested loop inside a nested loop
call pgmb.reg('cte.edge_rescan_three_levels', '{perf,planning,analyze}', :'pgmb_nl' || $q$
with a as materialized (select id, k_100 from g_narrow where id between :id and :id + 29),
     b as materialized (select id, k_100 from g_narrow where id between :id + 30 and :id + 59),
     c as materialized (select id, k_100 from g_narrow where id between :id + 60 and :id + 89)
select count(*) from a join b on b.k_100 % 10 = a.k_100 % 10 join c on c.k_100 % 10 = b.k_100 % 10$q$ || :'pgmb_end',
    setup => '\set id random(1, :n_g_narrow - 100)');

------------------------------------------------------------------------------
-- R08. a CTE no consumer reads
------------------------------------------------------------------------------
-- each of these would be expensive, empty, failing or endless if it ran
call pgmb.reg('cte.edge_unused_expensive', '{perf,planning,analyze,consistency,oltp}', $q$
with unused as (select a.id from g_child a cross join g_child b)
select 42 as answer$q$, equiv => 'cte.edge_unused');

call pgmb.reg('cte.edge_unused_expensive_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with unused as materialized (select a.id from g_child a cross join g_child b)
select 42 as answer$q$, equiv => 'cte.edge_unused');

call pgmb.reg('cte.edge_unused_failing', '{perf,planning,analyze,consistency,oltp}', $q$
with unused as materialized (select 1 / (id - id) from g_parent)
select 42 as answer$q$, equiv => 'cte.edge_unused');

-- a recursion that would never end (it would fail on its second step if it started)
call pgmb.reg('cte.edge_unused_endless_recursion', '{perf,planning,analyze,consistency,oltp}', $q$
with recursive unused(n) as (select 1 union all select n + 1 / (n - n) from unused)
select 42 as answer$q$, equiv => 'cte.edge_unused');

call pgmb.reg('cte.edge_unused_empty', '{perf,planning,analyze,consistency,oltp}', $q$
with unused as (select id from g_parent where false)
select 42 as answer$q$, equiv => 'cte.edge_unused');

-- read only by a CTE that is itself unread; and ten such CTEs
call pgmb.reg('cte.edge_unused_chain', '{perf,planning,analyze,consistency,oltp}', $q$
with a as materialized (select 1 / (id - id) as x from g_parent),
     b as (select count(*) from a),
     c as (select * from b)
select 42 as answer$q$, equiv => 'cte.edge_unused');

select 'with ' || string_agg(format('u%s as materialized (select 1 / (id - id) as x from g_parent)', i), ', ' order by i)
       || ' select 42 as answer' as pgmb_sql from generate_series(1, 10) i \gset
call pgmb.reg('cte.edge_unused_ten', '{perf,planning,analyze,consistency,oltp}', :'pgmb_sql', equiv => 'cte.edge_unused');

-- an unread sequence call consumes nothing; an unread writer still writes
call pgmb.reg('cte.edge_unused_nextval', '{perf,planning,analyze,oltp}', $q$
with unused as (select nextval('g_cte_seq') from generate_series(1, 1000))
select 42 as answer$q$);

call pgmb.reg('cte.edge_unused_writer_still_runs', '{perf,planning,analyze,oltp}', $q$
with unused as (update g_parent set updated_at = now() where id = :id)
select 42 as answer$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- used in the text, but only inside a branch that is never taken
call pgmb.reg('cte.edge_unused_at_run_time', '{perf,planning,analyze,oltp}', $q$
with c as materialized (select 1 / (id - id) as x from g_parent)
select case when d.id < 0 then (select count(*) from c) else 42 end as answer from g_dim d where d.id = 1$q$);

------------------------------------------------------------------------------
-- R09. LIMIT, EXISTS and subplans that run only sometimes
------------------------------------------------------------------------------
-- LIMIT and EXISTS over an empty CTE: to say "nothing" the whole source is read
call pgmb.reg('cte.edge_limit_on_empty_cte', '{perf,planning,analyze,olap}', $q$
with c as materialized (select id from g_child where amount < 0)
select count(*) from (select id from c limit 1) s$q$);

call pgmb.reg('cte.edge_exists_on_empty_cte', '{perf,planning,analyze,olap}', $q$
with c as materialized (select id from g_child where amount < 0)
select exists (select 1 from c)$q$);

-- the same over a CTE whose first row qualifies
call pgmb.reg('cte.edge_exists_on_first_row', '{perf,planning,analyze,oltp}', $q$
with c as materialized (select id from g_child where amount >= 0)
select exists (select 1 from c)$q$);

call pgmb.reg('cte.edge_limit_1_on_one_row_cte', '{perf,planning,analyze,oltp}', $q$
with c as materialized (select id, val from g_parent where id = :id)
select * from c limit 1$q$,
    setup => '\set id random(1, :n_g_parent)');

-- LIMIT larger than the CTE, LIMIT NULL, LIMIT ALL, OFFSET past the end
call pgmb.reg('cte.edge_limit_variants', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select id from g_parent where id between :id and :id + 9)
select (select count(*) from (select id from c limit 1000) s) as larger_than_cte,
       (select count(*) from (select id from c limit null) s) as limit_null,
       (select count(*) from (select id from c limit all) s) as limit_all,
       (select count(*) from (select id from c offset 1000) s) as offset_past_end,
       (select count(*) from (select id from c limit 0) s) as limit_zero,
       (select count(*) from (select id from c order by id offset 9 limit 5) s) as last_row$q$,
    setup => '\set id random(1, :n_g_parent - 10)', equiv => 'cte.edge_limit_variants');

call pgmb.reg('cte.edge_limit_variants_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as not materialized (select id from g_parent where id between :id and :id + 9)
select (select count(*) from (select id from c limit 1000) s) as larger_than_cte,
       (select count(*) from (select id from c limit null) s) as limit_null,
       (select count(*) from (select id from c limit all) s) as limit_all,
       (select count(*) from (select id from c offset 1000) s) as offset_past_end,
       (select count(*) from (select id from c limit 0) s) as limit_zero,
       (select count(*) from (select id from c order by id offset 9 limit 5) s) as last_row$q$,
    setup => '\set id random(1, :n_g_parent - 10)', equiv => 'cte.edge_limit_variants');

-- a subplan over the CTE that runs for about half of the statements:
-- the branch is chosen by the data of the row, not by a constant
call pgmb.reg('cte.edge_conditional_subplan_half_of_the_time', '{perf,planning,analyze}', $q$
with c as materialized (select count(*) as n, sum(amount) as total from g_child where kind < 4)
select p.id, case when p.grp < 50 then (select total from c) else p.val end from g_parent p where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.edge_conditional_subplan_always', '{perf,planning,analyze}', $q$
with c as materialized (select count(*) as n, sum(amount) as total from g_child where kind < 4)
select p.id, case when p.grp >= 0 then (select total from c) else p.val end from g_parent p where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.edge_conditional_subplan_never', '{perf,planning,analyze}', $q$
with c as materialized (select count(*) as n, sum(amount) as total from g_child where kind < 4)
select p.id, case when p.grp < 0 then (select total from c) else p.val end from g_parent p where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

-- over 100 rows the subplan is needed by some of them: it runs once and is reused
call pgmb.reg('cte.edge_conditional_subplan_some_of_100_rows', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select count(*) as n, sum(amount) as total from g_child where kind < 4)
select count(*), sum(case when p.grp < 50 then (select total from c) else 0 end) from g_parent p where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_cond_100');

call pgmb.reg('cte.edge_conditional_subplan_some_of_100_rows_inlined', '{perf,planning,analyze,consistency}', $q$
with c as not materialized (select count(*) as n, sum(amount) as total from g_child where kind < 4)
select count(*), sum(case when p.grp < 50 then (select total from c) else 0 end) from g_parent p where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_cond_100');

-- EXISTS in the WHERE of the main query decides whether a second CTE is read at all
call pgmb.reg('cte.edge_exists_gates_second_cte', '{perf,planning,analyze}', $q$
with gate as materialized (select 1 from g_parent where id = :id and grp < 50),
     heavy as materialized (select count(*) as n from g_child where kind < 4)
select (select n from heavy) from (select 1) one where exists (select 1 from gate)$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- R10. ORDER BY: the final order is what the outer query asks for.
-- Every test returns the ordered ids as one array (ARRAY(subquery) keeps the
-- subquery's order), so a wrong order changes the result. Nothing relies on the
-- order in which a CTE happens to deliver its rows.
------------------------------------------------------------------------------
-- the reference: no CTE
call pgmb.reg('cte.edge_order_reference', '{perf,planning,analyze,consistency}', $q$
select array(select id from g_parent where id between :id and :id + 199 order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

call pgmb.reg('cte.edge_order_outer_only_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, grp, val from g_parent where id between :id and :id + 199)
select array(select id from c order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

call pgmb.reg('cte.edge_order_outer_only_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199)
select array(select id from c order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

-- the CTE is sorted another way inside: the outer ORDER BY must win
call pgmb.reg('cte.edge_order_inner_differs_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, grp, val from g_parent where id between :id and :id + 199 order by val desc, id desc)
select array(select id from c order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

call pgmb.reg('cte.edge_order_inner_differs_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by val desc, id desc)
select array(select id from c order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

-- the CTE is sorted the same way inside: the outer sort may be skipped, the result may not change
call pgmb.reg('cte.edge_order_inner_same_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by grp desc, val, id)
select array(select id from c order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

-- through a chain, a join of two CTEs, and a UNION ALL of two CTEs
call pgmb.reg('cte.edge_order_through_chain', '{perf,planning,analyze,consistency}', $q$
with a as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by id desc),
     b as (select id, grp, val from a order by val),
     c as materialized (select id, grp, val from b)
select array(select id from c order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

call pgmb.reg('cte.edge_order_after_join_of_two_ctes', '{perf,planning,analyze,consistency}', $q$
with keys as materialized (select id, grp from g_parent where id between :id and :id + 199 order by grp),
     vals as materialized (select id, val from g_parent where id between :id and :id + 199 order by val desc)
select array(select k.id from keys k join vals v using (id) order by k.grp desc, v.val, k.id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

call pgmb.reg('cte.edge_order_after_union_all_of_two_ctes', '{perf,planning,analyze,consistency}', $q$
with low as materialized (select id, grp, val from g_parent where id between :id and :id + 99 order by id desc),
     high as materialized (select id, grp, val from g_parent where id between :id + 100 and :id + 199 order by id desc)
select array(select id from (select * from high union all select * from low) u order by grp desc, val, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order');

-- two readers of one CTE ask for opposite orders
call pgmb.reg('cte.edge_order_two_readers_opposite_orders', '{perf,planning,analyze,consistency}', $q$
with c as (select id, grp, val from g_parent where id between :id and :id + 199 order by id)
select array(select id from c order by grp desc, val, id) as down_array,
       array(select id from c order by grp, val desc, id desc) as up_array$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_two');

call pgmb.reg('cte.edge_order_two_readers_reference', '{perf,planning,analyze,consistency}', $q$
select array(select id from g_parent where id between :id and :id + 199 order by grp desc, val, id) as down_array,
       array(select id from g_parent where id between :id and :id + 199 order by grp, val desc, id desc) as up_array$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_two');

-- NULLS FIRST / LAST and an expression key
call pgmb.reg('cte.edge_order_nulls_and_expression_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, k_null, k_100 from g_narrow where id between :id and :id + 199 order by k_null nulls last)
select array(select id from c order by k_null desc nulls first, (k_100 % 7), id desc)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.edge_order_nulls');

call pgmb.reg('cte.edge_order_nulls_and_expression_reference', '{perf,planning,analyze,consistency}', $q$
select array(select id from g_narrow where id between :id and :id + 199 order by k_null desc nulls first, (k_100 % 7), id desc)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.edge_order_nulls');

-- ORDER BY with LIMIT and OFFSET: the top rows are those of the outer order
call pgmb.reg('cte.edge_order_top_n_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by id desc)
select array(select id from c order by val desc, id limit 10 offset 5)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_top');

call pgmb.reg('cte.edge_order_top_n_limit_inside_then_reordered', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by val desc, id limit 15)
select array(select id from (select id, val from c order by id) s order by val desc, id offset 5)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_top');

call pgmb.reg('cte.edge_order_top_n_reference', '{perf,planning,analyze,consistency}', $q$
select array(select id from g_parent where id between :id and :id + 199 order by val desc, id limit 10 offset 5)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_top');

-- ordered aggregates and window functions name their own order
call pgmb.reg('cte.edge_order_in_aggregate_and_window', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by val desc)
select array_agg(id order by grp desc, val, id) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_agg');

call pgmb.reg('cte.edge_order_by_window_row_number', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by val desc),
     numbered as (select id, row_number() over (order by grp desc, val, id) as rn from c)
select array(select id from numbered order by rn) as array_agg$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_agg');

-- a recursive CTE: rows arrive level by level, the outer query sorts them
call pgmb.reg('cte.edge_order_over_recursive', '{perf,planning,analyze,consistency}', $q$
with recursive sub as (
    select id, parent_id, val from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.val from g_tree t join sub s on t.parent_id = s.id)
select array(select id from sub order by id desc)$q$,
    setup => '\set id random(1, :n_g_tree / 64 + 1)', equiv => 'cte.edge_order_rec');

call pgmb.reg('cte.edge_order_over_recursive_with_search', '{perf,planning,analyze,consistency}', $q$
with recursive sub as (
    select id, parent_id, val from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.val from g_tree t join sub s on t.parent_id = s.id)
search depth first by id set ord
select array(select id from sub order by id desc)$q$,
    setup => '\set id random(1, :n_g_tree / 64 + 1)', equiv => 'cte.edge_order_rec');

-- no ORDER BY anywhere outside: the order is not defined, so only the set is compared
call pgmb.reg('cte.edge_order_inner_only_set_compared', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, grp, val from g_parent where id between :id and :id + 199 order by grp desc, val, id)
select id from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_set');

call pgmb.reg('cte.edge_order_none_set_compared', '{perf,planning,analyze,consistency}', $q$
with c as (select id, grp, val from g_parent where id between :id and :id + 199)
select id from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.edge_order_set');
