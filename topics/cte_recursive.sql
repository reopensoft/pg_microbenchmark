-- Topic: cte (part 9) - recursive CTEs in detail.
-- UNION vs UNION ALL, duplicate removal, shapes of recursion, typing rules,
-- SEARCH and CYCLE clauses, readers of a recursive CTE, and the parser's limits.

call pgmb.reg_ddl('cte.create_d_positive', 'schema', $q$create domain d_positive as int check (value > 0)$q$);

------------------------------------------------------------------------------
-- UNION vs UNION ALL, duplicate removal
------------------------------------------------------------------------------
call pgmb.reg('cte.rec_union_all_bounded', '{perf,planning}', $q$
with recursive w(node, depth) as (
    select :id::bigint, 0
    union all
    select g.dst, w.depth + 1 from g_graph g join w on g.src = w.node where w.depth < 4)
select count(*), count(distinct node) from w$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.rec_union_bounded', '{perf,planning}', $q$
with recursive w(node, depth) as (
    select :id::bigint, 0
    union
    select g.dst, w.depth + 1 from g_graph g join w on g.src = w.node where w.depth < 4)
select count(*), count(distinct node) from w$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

-- duplicates of rows produced by earlier iterations end the recursion
call pgmb.reg('cte.rec_dedup_across_iterations', '{perf,planning}', $q$
with recursive r(n) as (select 1 union select (n * 2) % 9973 from r)
select count(*) from r$q$);

-- every iteration produces the same row a hundred times
call pgmb.reg('cte.rec_dedup_within_iteration', '{perf,planning}', $q$
with recursive r(n) as (select 0 union select (r.n + 1) % 200 from r, generate_series(1, 100))
select count(*) from r$q$);

-- UNION with a changing extra column never converges; only the outer LIMIT stops it
call pgmb.reg('cte.rec_union_depth_column_needs_limit', '{perf,planning}', $q$
with recursive r(node, depth) as (select 1, 0 union select node % 10 + 1, depth + 1 from r)
select node, depth from r limit 2000$q$);

------------------------------------------------------------------------------
-- shapes
------------------------------------------------------------------------------
call pgmb.reg('cte.rec_one_start_row', '{perf,planning,oltp}', $q$
with recursive up as (
    select id, parent_id from g_tree where id = :id
    union all
    select t.id, t.parent_id from g_tree t join up u on t.id = u.parent_id)
select count(*) from up$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.rec_many_start_rows', '{perf,planning}', $q$
with recursive up as (
    select id, parent_id from g_tree where id between :id and :id + 999
    union all
    select t.id, t.parent_id from g_tree t join up u on t.id = u.parent_id)
select count(*), count(distinct id) from up$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.rec_deep_one_row_per_level', '{perf,planning}', $q$
with recursive t(n) as (select 1 union all select n + 1 from t where n < 100000)
select count(*), max(n) from t$q$);

call pgmb.reg('cte.rec_shallow_many_rows_per_level', '{perf,planning}', $q$
with recursive r(i, d) as (
    select i, 0 from generate_series(1, 100) i
    union all
    select r.i, r.d + 1 from r, generate_series(1, 10) where r.d < 3)
select d, count(*) from r group by d$q$);

call pgmb.reg('cte.rec_branching_whole_tree', '{perf,planning,olap}', $q$
with recursive sub as (
    select id, 0 as lvl from g_tree where id = 1
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id)
select lvl, count(*) from sub group by lvl$q$);

call pgmb.reg('cte.rec_empty_base', '{perf,planning,oltp}', $q$
with recursive sub as (
    select id, parent_id from g_tree where id = -1
    union all
    select t.id, t.parent_id from g_tree t join sub s on t.parent_id = s.id)
select count(*) from sub$q$);

call pgmb.reg('cte.rec_no_new_rows', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id from g_tree where id between :id and :id + 999
    union all
    select t.id, t.parent_id from g_tree t join sub s on t.parent_id = s.id and t.id < 0)
select count(*) from sub$q$,
    setup => '\set id random(1, :n_g_tree)');

-- the same node reached along different paths
call pgmb.reg('cte.rec_many_paths_to_same_node', '{perf,planning}', $q$
with recursive walk(node, path) as (
    select :id::bigint, array[:id::bigint]
    union all
    select g.dst, w.path || g.dst from g_graph g join walk w on g.src = w.node
    where cardinality(w.path) < 5 and g.dst <> all (w.path))
select count(*) as paths, count(distinct node) as nodes, max(cardinality(path)) from walk$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

------------------------------------------------------------------------------
-- NULLs and types
------------------------------------------------------------------------------
-- UNION treats NULLs as equal, so a second NULL ends the recursion
call pgmb.reg('cte.rec_null_key_dedup', '{perf,planning,oltp}', $q$
with recursive r(k) as (
    select null::int
    union
    select case when k is null then 1 when k < 500 then k + 1 end from r)
select count(*), count(k) from r$q$);

call pgmb.reg('cte.rec_null_stops_join', '{perf,planning,oltp}', $q$
with recursive up(id, parent_id, hops) as (
    select id, parent_id, 0 from g_tree where id = :id
    union all
    select t.id, t.parent_id, u.hops + 1 from g_tree t join up u on t.id = u.parent_id)
select max(hops), count(*) filter (where parent_id is null) from up$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.rec_type_int', '{perf,planning}', $q$
with recursive t(n) as (select 1::int union all select n + 1 from t where n < 20000) select sum(n) from t$q$);
call pgmb.reg('cte.rec_type_bigint', '{perf,planning}', $q$
with recursive t(n) as (select 1::bigint union all select n + 1 from t where n < 20000) select sum(n) from t$q$);
call pgmb.reg('cte.rec_type_numeric', '{perf,planning}', $q$
with recursive t(n) as (select 1::numeric union all select n + 1 from t where n < 20000) select sum(n) from t$q$);
call pgmb.reg('cte.rec_type_text_growing', '{perf,planning}', $q$
with recursive t(s) as (select 'a'::text union all select s || 'a' from t where length(s) < 2000)
select count(*), max(length(s)) from t$q$);

call pgmb.reg('cte.rec_type_cast_in_recursive_term', '{perf,planning}', $q$
with recursive t(n) as (select 1 union all select (n + 1.5)::int from t where n < 20000) select count(*) from t$q$);

call pgmb.reg('cte.rec_type_typed_null_base', '{perf,planning,oltp}', $q$
with recursive t(n, prev) as (select 1, null::int union all select n + 1, n from t where n < 1000)
select count(*), count(prev) from t$q$);

call pgmb.reg('cte.rec_type_unknown_literal_base', '{perf,planning,oltp}', $q$
with recursive t(s, n) as (select 'x', 1 union all select s || 'y', n + 1 from t where n < 500)
select max(length(s)) from t$q$);

call pgmb.reg('cte.rec_type_domain', '{perf,planning}', $q$
with recursive t(n) as (select 1::d_positive union all select (n + 1)::d_positive from t where n < 20000)
select count(*), max(n) from t$q$);

call pgmb.reg('cte.rec_type_composite_row', '{perf,planning}', $q$
with recursive t(d) as (
    select row(g.id, g.code, g.category, g.name)::g_dim from g_dim g where g.id = 1
    union all
    select row((t.d).id + 1, (t.d).code, (t.d).category, (t.d).name)::g_dim from t where (t.d).id < 5000)
select count(*), max((d).id) from t$q$);

call pgmb.reg('cte.rec_type_collation_explicit', '{perf,planning}', $q$
with recursive t(s) as (
    select 'a'::text collate "C"
    union all
    select (s || chr(97 + length(s) % 26)) collate "C" from t where length(s) < 1000)
select count(*), max(s) from t$q$);

------------------------------------------------------------------------------
-- SEARCH
------------------------------------------------------------------------------
call pgmb.reg('cte.rec_search_none', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id, depth from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.depth from g_tree t join sub s on t.parent_id = s.id)
select count(*) from sub$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

-- the clause adds a sort key column; without ORDER BY nothing is sorted
call pgmb.reg('cte.rec_search_column_unused', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id, depth from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.depth from g_tree t join sub s on t.parent_id = s.id)
search depth first by id set ord
select count(*) from sub$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

call pgmb.reg('cte.rec_search_depth_first_ordered', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id, depth from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.depth from g_tree t join sub s on t.parent_id = s.id)
search depth first by id set ord
select id, depth from sub order by ord$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

call pgmb.reg('cte.rec_search_breadth_first_ordered', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id, depth from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.depth from g_tree t join sub s on t.parent_id = s.id)
search breadth first by id set ord
select id, depth from sub order by ord$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

call pgmb.reg('cte.rec_search_two_key_columns', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id, val from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.val from g_tree t join sub s on t.parent_id = s.id)
search depth first by val, id set ord
select id from sub order by ord$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

-- the generated columns are part of the result
call pgmb.reg('cte.rec_search_hidden_columns_returned', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id from g_tree where id = :id
    union all
    select t.id, t.parent_id from g_tree t join sub s on t.parent_id = s.id)
search depth first by id set ord
select * from sub$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

------------------------------------------------------------------------------
-- CYCLE
------------------------------------------------------------------------------
-- a ring of 500: the row that closes the cycle is returned, marked, and not expanded
call pgmb.reg('cte.rec_cycle_closing_row', '{perf,planning}', $q$
with recursive r(n) as (select 0 union all select (n + 1) % 500 from r)
cycle n set is_cycle using path
select count(*), count(*) filter (where is_cycle), max(cardinality(path)) from r$q$);

call pgmb.reg('cte.rec_cycle_two_columns', '{perf,planning}', $q$
with recursive w(src, dst, depth) as (
    select src, dst, 0 from g_graph where src = :id
    union all
    select g.src, g.dst, w.depth + 1 from g_graph g join w on g.src = w.dst where w.depth < 4)
cycle src, dst set is_cycle using path
select count(*), count(*) filter (where is_cycle) from w$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.rec_cycle_null_key', '{perf,planning,oltp}', $q$
with recursive r(k) as (
    select null::int
    union all
    select case when k is null then 1 when k < 300 then k + 1 end from r)
cycle k set is_cycle using path
select count(*), count(*) filter (where is_cycle), count(k) from r$q$);

call pgmb.reg('cte.rec_cycle_custom_marker', '{perf,planning}', $q$
with recursive w(node, depth) as (
    select :id::bigint, 0
    union all
    select g.dst, w.depth + 1 from g_graph g join w on g.src = w.node where w.depth < 4)
cycle node set state to 'loop' default 'ok' using trail
select state, count(*) from w group by state$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.rec_search_and_cycle', '{perf,planning}', $q$
with recursive w(node, depth) as (
    select :id::bigint, 0
    union all
    select g.dst, w.depth + 1 from g_graph g join w on g.src = w.node where w.depth < 4)
search breadth first by node set ord
cycle node set is_cycle using path
select node, depth, is_cycle from w order by ord limit 200$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.rec_cycle_hidden_columns_returned', '{perf,planning}', $q$
with recursive w(node, depth) as (
    select :id::bigint, 0
    union all
    select g.dst, w.depth + 1 from g_graph g join w on g.src = w.node where w.depth < 3)
cycle node set is_cycle using path
select * from w$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

-- hand-written path tracking: plain array vs. array of records (what CYCLE builds)
call pgmb.reg('cte.rec_path_plain_array', '{perf,planning}', $q$
with recursive w(node, depth, path) as (
    select :id::bigint, 0, array[:id::bigint]
    union all
    select g.dst, w.depth + 1, w.path || g.dst from g_graph g join w on g.src = w.node
    where w.depth < 4 and g.dst <> all (w.path))
select count(*), max(cardinality(path)) from w$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.rec_path_record_array', '{perf,planning}', $q$
with recursive w(node, depth, path) as (
    select :id::bigint, 0, array[row(:id::bigint)]
    union all
    select g.dst, w.depth + 1, w.path || row(g.dst) from g_graph g join w on g.src = w.node
    where w.depth < 4 and row(g.dst) <> all (w.path))
select count(*), max(cardinality(path)) from w$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

------------------------------------------------------------------------------
-- readers of a recursive CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.rec_three_readers', '{perf,planning}', $q$
with recursive sub as (
    select id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 4)
select (select count(*) from sub), (select max(lvl) from sub), (select count(*) from sub a join sub b on a.id = b.id)$q$,
    setup => '\set id random(1, :n_g_tree)');

-- an endless recursion that the outer LIMIT cuts off
call pgmb.reg('cte.rec_outer_limit_stops_infinite', '{perf,planning,oltp}', $q$
with recursive t(n) as (select 1 union all select n + 1 from t)
select n from t limit 100$q$);

call pgmb.reg('cte.rec_outer_limit_on_tree', '{perf,planning,oltp}', $q$
with recursive sub as (
    select id from g_tree where id = 1
    union all
    select t.id from g_tree t join sub s on t.parent_id = s.id)
select id from sub limit 50$q$);

call pgmb.reg('cte.rec_outer_order_by', '{perf,planning}', $q$
with recursive sub as (
    select id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id)
select id, lvl from sub order by lvl desc, id limit 20$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

call pgmb.reg('cte.rec_outer_distinct_and_group', '{perf,planning}', $q$
with recursive w(node, depth) as (
    select :id::bigint, 0
    union all
    select g.dst, w.depth + 1 from g_graph g join w on g.src = w.node where w.depth < 4)
select depth, count(*), count(distinct node) from w group by depth$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.rec_window_in_recursive_term', '{perf,planning}', $q$
with recursive t(n, rn, lvl) as (
    select i, 0::bigint, 1 from generate_series(1, 20) i
    union all
    select n, row_number() over (order by n desc), lvl + 1 from t where lvl < 50)
select count(*), max(rn) from t$q$);

------------------------------------------------------------------------------
-- what the parser rejects
------------------------------------------------------------------------------
call pgmb.reg('cte.err_rec_reference_in_base_term', '{errors}',
    $q$with recursive t(n) as (select n from t union all select 1) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_rec_two_references', '{errors}',
    $q$with recursive t(n) as (select 1 union all select a.n + 1 from t a join t b on a.n = b.n where a.n < 3) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_rec_mutual', '{errors}',
    $q$with recursive a(n) as (select 1 union all select n + 1 from b where n < 3), b(n) as (select 1 union all select n + 1 from a where n < 3) select * from a$q$, expect_error => '0A000');
call pgmb.reg('cte.err_rec_reference_in_subquery', '{errors}',
    $q$with recursive t(n) as (select 1 union all select (select max(n) from t) + 1) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_rec_outer_join_nullable_side', '{errors}',
    $q$with recursive t(n) as (select 1 union all select t.n + 1 from g_dim d left join t on t.n = d.id where t.n < 3) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_rec_order_by_in_recursive_term', '{errors}',
    $q$with recursive t(n) as (select 1 union all select n + 1 from t where n < 3 order by 1) select * from t$q$, expect_error => '0A000');
call pgmb.reg('cte.err_rec_limit_in_recursive_term', '{errors}',
    $q$with recursive t(n) as (select 1 union all select n + 1 from t where n < 3 limit 1) select * from t$q$, expect_error => '0A000');
call pgmb.reg('cte.err_rec_untyped_null_base', '{errors}',
    $q$with recursive t(n) as (select null union all select n + 1 from t where n < 3) select * from t$q$, expect_error => '42883');
call pgmb.reg('cte.err_rec_domain_lost', '{errors}',
    $q$with recursive t(n) as (select 1::d_positive union all select n + 1 from t where n < 3) select * from t$q$, expect_error => '42804');
call pgmb.reg('cte.err_rec_collation_mismatch', '{errors}',
    $q$with recursive t(s) as (select 'a'::text collate "C" union all select (s || 'b') collate "POSIX" from t where length(s) < 3) select * from t$q$, expect_error => '42P21');
call pgmb.reg('cte.err_rec_intersect', '{errors}',
    $q$with recursive t(n) as (select 1 intersect select n + 1 from t) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_rec_cycle_column_missing', '{errors}',
    $q$with recursive t(n) as (select 1 union all select n + 1 from t where n < 3) cycle m set is_cycle using path select * from t$q$, expect_error => '42601');
call pgmb.reg('cte.err_rec_search_on_non_recursive', '{errors}',
    $q$with t(n) as (select 1) search depth first by n set ord select * from t$q$, expect_error => '42601');
