-- Topic: cte (part 20) - CTEs that are not read to the end.
-- The executor pulls rows on demand, so a reader that has enough stops the
-- producer: LIMIT, FETCH FIRST, EXISTS, IN / ANY / ALL, semi and anti joins,
-- joins with an empty side, WHERE false, untaken CASE branches, UNION ALL,
-- cursors, and several readers of one CTE.
--
-- Two questions per mechanism:
--   * is the rest of the CTE left alone?  The CTEs below carry a "bomb": row
--     500 of 1000 (or row 1) divides by zero. A reader that stops in time gets
--     its answer; one that reads on fails with 22012. The first kind are
--     ordinary tests (an error would leave them without a result in the
--     report), the second kind are error tests.
--   * how much work is saved?  The cost_* tests at the end use real tables.
--
-- The bomb CTEs read generate_series() from the select list: rows arrive one by
-- one, in order, and no index or join order decides which row comes first.
-- Where the outcome depends on the plan, the plan is forced for one transaction.
-- Elsewhere: cte.limit_*, cte.offset_*, cte.error_function_*, cte.mix_error_*,
-- cte.intarray_error_* (partial reads with other kinds of errors).

-- 1000 rows, row 500 fails
\set pgmb_bomb500 'select n as id, n % 100 as k from (select generate_series(1, 1000) as n) g where (1 / (n - 500)) is not null'
-- 1000 rows, the very first row fails
\set pgmb_bomb1 'select n as id, n % 100 as k from (select generate_series(1, 1000) as n) g where (1 / (n - 1)) is not null'
-- 1000 rows, none fails
\set pgmb_safe 'select n as id, n % 100 as k from (select generate_series(1, 1000) as n) g'

------------------------------------------------------------------------------
-- 1. LIMIT
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_limit_10_inlined', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id from c limit 10$q$);
call pgmb.reg('cte.partial_limit_10_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select id from c limit 10$q$);
-- one row short of the bomb
call pgmb.reg('cte.partial_limit_499_inlined', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select count(*) from (select id from c limit 499) s$q$);
call pgmb.reg('cte.partial_limit_499_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select count(*) from (select id from c limit 499) s$q$);
call pgmb.reg('cte.err_partial_limit_500_inlined', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$) select count(*) from (select id from c limit 500) s$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_limit_500_materialized', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select count(*) from (select id from c limit 500) s$q$, expect_error => '22012');

-- OFFSET rows are produced and thrown away: they count
call pgmb.reg('cte.partial_limit_offset_480_limit_10', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id from c offset 480 limit 10$q$);
call pgmb.reg('cte.err_partial_limit_offset_495_limit_10', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id from c offset 495 limit 10$q$, expect_error => '22012');

-- LIMIT 0 pulls nothing, not even the first row
call pgmb.reg('cte.partial_limit_0', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb1' || $q$) select id from c limit 0$q$);
call pgmb.reg('cte.partial_limit_0_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$) select id from c limit 0$q$);

-- a sort between the CTE and the LIMIT needs every row first
call pgmb.reg('cte.err_partial_limit_after_sort', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id from c order by k limit 1$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_limit_after_aggregate', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$) select k, count(*) from c group by k limit 1$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_limit_after_distinct', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$) select distinct k from c limit 1$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_limit_after_window', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id, count(*) over () from c limit 1$q$, expect_error => '22012');

-- a running window streams, but its ORDER BY puts a sort in front of it when
-- the input order is not known: everything is read before the first row
call pgmb.reg('cte.err_partial_limit_after_running_window_needs_sort', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id, sum(id) over (order by id rows unbounded preceding) from c limit 10$q$, expect_error => '22012');
-- without ORDER BY the window takes the rows as they come, and LIMIT stops it
call pgmb.reg('cte.partial_limit_after_unordered_running_window', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id, sum(id) over (rows unbounded preceding) from c limit 10$q$);

-- LIMIT in an inner query block, the CTE two levels below
call pgmb.reg('cte.partial_limit_through_two_levels', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$), d as (select id, k from c where k <> 7), e as (select id * 2 as id2 from d)
select sum(id2) from (select id2 from e limit 20) s$q$);

-- the outer condition is moved into an inlined CTE and becomes an index
-- condition: the scan never visits row 500 (table-based: pushdown needs a table)
call pgmb.reg('cte.partial_limit_pushdown_skips_error_row', '{perf,planning,oltp}', $q$
with c as (select id from g_narrow where id <= 1000 and (1 / (id - 500)) is not null)
select count(*) from (select id from c where id > 600 and id < 610 limit 5) s$q$);
-- materialized: every row of the CTE is produced before the outer condition is applied
call pgmb.reg('cte.err_partial_limit_no_pushdown_materialized', '{errors}', $q$
with c as materialized (select id from g_narrow where id <= 1000 and (1 / (id - 500)) is not null)
select count(*) from (select id from c where id > 600 and id < 610 limit 5) s$q$, expect_error => '22012');

------------------------------------------------------------------------------
-- 2. FETCH FIRST n ROWS ONLY / WITH TIES
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_fetch_first_10_rows_only', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select id from c fetch first 10 rows only$q$);
call pgmb.reg('cte.partial_fetch_first_row_only_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select id from c fetch first row only$q$);
-- WITH TIES requires ORDER BY, and the order of this CTE is not known to the
-- planner: the sort reads every row, however few are asked for
call pgmb.reg('cte.err_partial_fetch_first_10_with_ties_needs_sort', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select id from c order by id fetch first 10 rows with ties$q$, expect_error => '22012');
-- over an index the order is free: WITH TIES reads one row past the limit to
-- look for a tie (rows 11 and 500 of a table-based CTE; pushdown is not involved)
call pgmb.reg('cte.partial_fetch_first_10_with_ties_index_order', '{perf,oltp}', $q$
begin;
set local enable_seqscan = off;
set local enable_sort = off;
set local enable_bitmapscan = off;
with c as (select id from g_narrow where (1 / (id - 500)) is not null order by id)
select id from c order by id fetch first 10 rows with ties;
commit;$q$);
call pgmb.reg('cte.partial_fetch_first_499_rows_only', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select count(*) from (select id from c fetch first 499 rows only) s$q$);

------------------------------------------------------------------------------
-- 3. EXISTS     4. NOT EXISTS
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_exists_first_match_inlined', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select exists (select 1 from c where id >= 10)$q$);
call pgmb.reg('cte.partial_exists_first_match_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select exists (select 1 from c where id >= 10)$q$);
call pgmb.reg('cte.partial_exists_any_row', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select exists (select 1 from c)$q$);
-- nothing matches before the bomb: the search runs into it
call pgmb.reg('cte.err_partial_exists_no_match_before_error', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select exists (select 1 from c where id > 600)$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_exists_no_match_at_all', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select exists (select 1 from c where k < 0)$q$, expect_error => '22012');

call pgmb.reg('cte.partial_not_exists_first_match_inlined', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select not exists (select 1 from c where id >= 10)$q$);
call pgmb.reg('cte.partial_not_exists_first_match_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select not exists (select 1 from c where id >= 10)$q$);
-- NOT EXISTS is true only after the whole CTE has been searched
call pgmb.reg('cte.err_partial_not_exists_no_match', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select not exists (select 1 from c where k < 0)$q$, expect_error => '22012');

-- EXISTS with aggregation inside always has one row, but must read all input
call pgmb.reg('cte.err_partial_exists_over_aggregate', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select exists (select count(*) from c)$q$, expect_error => '22012');

------------------------------------------------------------------------------
-- 5. IN (SELECT)   6. = ANY (SELECT)   7. <> ALL   8. > ALL, < ALL
-- An uncorrelated IN / = ANY / NOT IN is run as a hashed subplan when its rows
-- fit in work_mem: all rows are read into the hash table first, although the
-- answer is known after ten. Comparisons that cannot be hashed stop early.
------------------------------------------------------------------------------
call pgmb.reg('cte.err_partial_in_hashed_reads_all', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 10 in (select id from c)$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_any_hashed_reads_all', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 10 = any (select id from c)$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_not_in_hashed_reads_all', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 10 not in (select id from c)$q$, expect_error => '22012');
-- "<> ALL" means the same as NOT IN but is not rewritten to a hashable form:
-- it is checked row by row and stops at the first equal value
call pgmb.reg('cte.partial_not_equal_all_stops_at_counterexample', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 10 <> all (select id from c)$q$);
call pgmb.reg('cte.err_partial_not_equal_all_no_counterexample', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 2000 <> all (select id from c)$q$, expect_error => '22012');

-- the same questions with a LIMIT inside the subquery: only the prefix is hashed
call pgmb.reg('cte.partial_in_prefix_only', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 10 in (select id from c limit 100)$q$);

-- not hashable: >= ANY is true at the first row that is small enough
call pgmb.reg('cte.partial_any_inequality_stops_at_first_match', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 10 >= any (select id from c)$q$);
call pgmb.reg('cte.err_partial_any_inequality_no_match', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 0 >= any (select id from c)$q$, expect_error => '22012');

-- > ALL is false at the first counterexample (row 5)
call pgmb.reg('cte.partial_greater_than_all_counterexample_early', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 5 > all (select id from c)$q$);
call pgmb.reg('cte.partial_less_than_all_counterexample_first_row', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$) select 3 < all (select id from c)$q$);
-- no counterexample: every row has to be checked
call pgmb.reg('cte.err_partial_less_than_all_no_counterexample', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 0 < all (select id from c)$q$, expect_error => '22012');
call pgmb.reg('cte.err_partial_greater_than_all_no_counterexample', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$) select 2000 > all (select id from c)$q$, expect_error => '22012');

------------------------------------------------------------------------------
-- 9. semi join   10. anti join
-- A nested loop stops the inner side at the first match of each outer row; a
-- hash join reads the inner side completely before the first probe.
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_semi_join_nested_loop', '{perf,oltp}',
    $q$begin;
set local enable_hashjoin = off;
set local enable_mergejoin = off;
set local enable_hashagg = off;
set local enable_sort = off;
with c as materialized ($q$ || :'pgmb_bomb500' || $q$)
select count(*) from g_dim d where d.id <= 10 and exists (select 1 from c where c.id = d.id);
commit;$q$);

call pgmb.reg('cte.partial_anti_join_nested_loop', '{perf,oltp}',
    $q$begin;
set local enable_hashjoin = off;
set local enable_mergejoin = off;
set local enable_hashagg = off;
set local enable_sort = off;
with c as materialized ($q$ || :'pgmb_bomb500' || $q$)
select count(*) from g_dim d where d.id <= 10 and not exists (select 1 from c where c.id = d.id);
commit;$q$);

-- a correlated subquery that the planner cannot turn into a join (OFFSET 0):
-- it runs once per outer row and stops at the first match, whatever the settings
call pgmb.reg('cte.partial_semi_as_correlated_subplan', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$)
select count(*) from g_dim d where d.id <= 10 and exists (select 1 from c where c.id = d.id offset 0)$q$);

call pgmb.reg('cte.partial_anti_as_correlated_subplan', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$)
select count(*) from g_dim d where d.id <= 10 and not exists (select 1 from c where c.id = d.id offset 0)$q$);

-- an outer row without a partner sends the search through the whole CTE
call pgmb.reg('cte.err_partial_semi_subplan_outer_row_without_match', '{errors}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$)
select count(*) from (values (3), (2000)) d(id) where exists (select 1 from c where c.id = d.id offset 0)$q$, expect_error => '22012');

-- semi join on a safe CTE: the three join methods, to compare their cost
call pgmb.reg('cte.partial_semi_join_safe_planner_choice', '{perf,planning}',
    'with c as materialized (' || :'pgmb_safe' || $q$)
select count(*) from g_dim d where exists (select 1 from c where c.id = d.id)$q$);

call pgmb.reg('cte.partial_semi_join_safe_nested_loop', '{perf}',
    $q$begin;
set local enable_hashjoin = off;
set local enable_mergejoin = off;
set local enable_hashagg = off;
set local enable_sort = off;
with c as materialized ($q$ || :'pgmb_safe' || $q$)
select count(*) from g_dim d where exists (select 1 from c where c.id = d.id);
commit;$q$);

------------------------------------------------------------------------------
-- 11. nested loop with nothing on the outer side   12. a join side that is empty
-- The CTE here fails on its first row: any read at all would show.
------------------------------------------------------------------------------
-- nested loop and merge join start with the empty side and never open the CTE
call pgmb.reg('cte.partial_join_empty_side_nested_loop', '{perf,oltp}',
    $q$begin;
set local enable_hashjoin = off;
set local enable_mergejoin = off;
with c as materialized ($q$ || :'pgmb_bomb1' || $q$)
select count(*) from g_dim d join c on c.id = d.id where d.id < 0;
commit;$q$);

call pgmb.reg('cte.partial_join_empty_side_merge_join', '{perf,oltp}',
    $q$begin;
set local enable_hashjoin = off;
set local enable_nestloop = off;
with c as materialized ($q$ || :'pgmb_bomb1' || $q$)
select count(*) from g_dim d join c on c.id = d.id where d.id < 0;
commit;$q$);

-- a hash join that probes with the CTE asks it for one row before building the
-- hash table (to learn early that the probe side is empty). That single row is
-- enough to start the CTE: with the bomb on row 1 the statement fails although
-- the join has no rows. A LEFT JOIN from the empty side has no such peek.
call pgmb.reg('cte.err_partial_join_empty_side_hash_join_peeks', '{errors}',
    'with nothing as materialized (select id from g_dim where id < 0), c as materialized (' || :'pgmb_bomb1' || $q$)
select count(*) from nothing n join c on c.id = n.id$q$, expect_error => '22012');

call pgmb.reg('cte.partial_left_join_outer_side_empty', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$)
select count(*) from g_dim d left join c on c.id = d.id where d.id < 0$q$);

-- the empty side is another CTE
call pgmb.reg('cte.partial_cross_join_with_empty_cte', '{perf,planning,oltp}',
    'with nothing as materialized (select id from g_dim where id < 0), c as materialized (' || :'pgmb_bomb1' || $q$)
select count(*) from nothing n, c$q$);

-- lateral: the CTE is read once per outer row, and there are none
call pgmb.reg('cte.partial_lateral_no_outer_rows', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$)
select count(*) from g_dim d, lateral (select count(*) as n from c where c.k = d.category) s where d.id < 0$q$);

-- the empty side is on the right of a LEFT JOIN: the CTE must still be read
call pgmb.reg('cte.err_partial_cte_left_join_empty_side', '{errors}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$)
select count(*) from c left join g_dim d on d.id = c.id and d.id < 0$q$, expect_error => '22012');

------------------------------------------------------------------------------
-- 13. WHERE false
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_where_false_constant', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb1' || $q$) select count(*) from c where false$q$);
call pgmb.reg('cte.partial_where_false_constant_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$) select count(*) from c where false$q$);
-- false only at run time: a one-time filter in front of the scan
call pgmb.reg('cte.partial_where_false_at_run_time', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$) select count(*) from c where current_setting('pgmb.no_such_setting', true) = 'x'$q$);
call pgmb.reg('cte.partial_where_contradiction', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb1' || $q$) select count(*) from c where id < 0 and id > 0 and false$q$);

------------------------------------------------------------------------------
-- 14. CASE and other conditional evaluation
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_case_branch_not_taken_constant', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$) select case when :pick = 1 then (select count(*) from c) else -1 end$q$,
    setup => '\set pick 0');

-- the condition depends on a row: the subquery is planned, and never started
call pgmb.reg('cte.partial_case_branch_not_taken_per_row', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$)
select d.id, case when d.id < 0 then (select count(*) from c) else -1 end from g_dim d where d.id = 1$q$);

call pgmb.reg('cte.err_partial_case_branch_taken', '{errors}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$)
select d.id, case when d.id > 0 then (select count(*) from c) else -1 end from g_dim d where d.id = 1$q$, expect_error => '22012');

call pgmb.reg('cte.partial_coalesce_first_argument_enough', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$)
select coalesce(d.id, (select max(id) from c)) from g_dim d where d.id = 1$q$);

call pgmb.reg('cte.partial_and_short_circuit_in_select_list', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$)
select d.id < 0 and (select count(*) from c) > 0 from g_dim d where d.id = 1$q$);

------------------------------------------------------------------------------
-- 15. a CTE that nobody reads
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_unreferenced_cte', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb1' || $q$) select 1$q$);
call pgmb.reg('cte.partial_unreferenced_cte_materialized', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$) select 1$q$);
-- read only by another CTE that nobody reads
call pgmb.reg('cte.partial_unreferenced_cte_chain', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb1' || $q$), d as (select count(*) from c) select 1$q$);

------------------------------------------------------------------------------
-- 16. UNION ALL: later branches are not started when the reader stops early
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_union_all_second_branch_not_started', '{perf,planning,oltp}',
    'with ok as materialized (' || :'pgmb_safe' || '), bad as materialized (' || :'pgmb_bomb1' || $q$)
select id from (select id from ok union all select id from bad) u limit 10$q$);

call pgmb.reg('cte.partial_union_all_second_branch_not_started_inlined', '{perf,planning,oltp}',
    'with ok as (' || :'pgmb_safe' || '), bad as (' || :'pgmb_bomb1' || $q$)
select id from (select id from ok union all select id from bad) u limit 10$q$);

-- the reader wants more than the first branch has
call pgmb.reg('cte.err_partial_union_all_reader_reaches_second_branch', '{errors}',
    'with ok as materialized (' || :'pgmb_safe' || '), bad as materialized (' || :'pgmb_bomb1' || $q$)
select count(*) from (select id from ok union all select id from bad limit 1001) u$q$, expect_error => '22012');

-- the first branch is empty: the reader goes straight to the second
call pgmb.reg('cte.err_partial_union_all_first_branch_empty', '{errors}',
    'with ok as materialized (' || :'pgmb_safe' || '), bad as materialized (' || :'pgmb_bomb1' || $q$)
select id from (select id from ok where id < 0 union all select id from bad) u limit 1$q$, expect_error => '22012');

-- an ordered result needs the first row of every branch (or all rows)
call pgmb.reg('cte.err_partial_union_all_ordered_needs_every_branch', '{errors}',
    'with ok as materialized (' || :'pgmb_safe' || '), bad as materialized (' || :'pgmb_bomb1' || $q$)
select id from (select id from ok union all select id from bad) u order by id limit 1$q$, expect_error => '22012');

-- UNION (distinct) reads everything before it returns anything
call pgmb.reg('cte.err_partial_union_distinct_reads_all', '{errors}',
    'with ok as materialized (' || :'pgmb_safe' || '), bad as materialized (' || :'pgmb_bomb1' || $q$)
select id from (select id from ok union select id from bad) u limit 1$q$, expect_error => '22012');

------------------------------------------------------------------------------
-- 17. DECLARE CURSOR + FETCH   18. CLOSE   19. the client stops reading
-- pgbench and psql always read a result to its end, so "the client stops" is
-- modelled with a cursor that is closed, or left to the end of the transaction,
-- after a partial FETCH.
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_cursor_fetch_10_close', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as ($q$ || :'pgmb_bomb500' || $q$) select id from c;
fetch 10 from pgmb_cur;
close pgmb_cur;
commit;$q$);

call pgmb.reg('cte.partial_cursor_fetch_10_close_materialized', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_bomb500' || $q$) select id from c;
fetch 10 from pgmb_cur;
close pgmb_cur;
commit;$q$);

-- several small fetches, still short of the bomb
call pgmb.reg('cte.partial_cursor_fetch_in_steps', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_bomb500' || $q$) select id from c;
fetch 100 from pgmb_cur;
fetch 100 from pgmb_cur;
fetch 100 from pgmb_cur;
close pgmb_cur;
commit;$q$);

-- MOVE skips rows without sending them, but they are produced
call pgmb.reg('cte.partial_cursor_move_then_fetch', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_bomb500' || $q$) select id from c;
move 480 from pgmb_cur;
fetch 10 from pgmb_cur;
close pgmb_cur;
commit;$q$);

-- no CLOSE: the transaction end drops the portal with its unread rows
call pgmb.reg('cte.partial_cursor_fetch_then_commit_without_close', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_bomb500' || $q$) select id from c;
fetch 10 from pgmb_cur;
commit;$q$);

call pgmb.reg('cte.partial_cursor_fetch_then_rollback', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_bomb500' || $q$) select id from c;
fetch 10 from pgmb_cur;
rollback;$q$);

-- declared and never fetched
call pgmb.reg('cte.partial_cursor_declared_never_fetched', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_bomb1' || $q$) select id from c;
close pgmb_cur;
commit;$q$);

-- scrollable: going back re-reads stored rows, not the producer
call pgmb.reg('cte.partial_cursor_scroll_back_and_forth', '{perf,oltp}',
    $q$begin;
declare pgmb_cur scroll cursor for with c as materialized ($q$ || :'pgmb_bomb500' || $q$) select id from c;
fetch 50 from pgmb_cur;
fetch backward 50 from pgmb_cur;
fetch 50 from pgmb_cur;
close pgmb_cur;
commit;$q$);

-- WITH HOLD: at commit the rest of the result is produced and stored, so a
-- partially read holdable cursor costs a full read (safe CTE: with the bomb the
-- commit itself would fail)
call pgmb.reg('cte.partial_cursor_with_hold_reads_all_at_commit', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor with hold for with c as materialized ($q$ || :'pgmb_safe' || $q$) select id from c;
fetch 10 from pgmb_cur;
commit;
close pgmb_cur;$q$);

call pgmb.reg('cte.partial_cursor_without_hold_same_reads', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_safe' || $q$) select id from c;
fetch 10 from pgmb_cur;
close pgmb_cur;
commit;$q$);

-- the cursor read to its end, for comparison
call pgmb.reg('cte.partial_cursor_fetch_all', '{perf,oltp}',
    $q$begin;
declare pgmb_cur cursor for with c as materialized ($q$ || :'pgmb_safe' || $q$) select id from c;
fetch all from pgmb_cur;
close pgmb_cur;
commit;$q$);

------------------------------------------------------------------------------
-- 20. several readers of one CTE: the producer runs as far as the greediest
------------------------------------------------------------------------------
call pgmb.reg('cte.partial_two_readers_both_stop_early', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$)
select (select id from c limit 1) as first_row, (select count(*) from (select id from c limit 100) s) as first_hundred$q$);

-- the second reader starts from the stored rows of the first
call pgmb.reg('cte.partial_two_readers_big_then_small', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$)
select (select count(*) from (select id from c limit 400) s) as first_400, (select max(id) from (select id from c limit 10) s) as first_10$q$);

call pgmb.reg('cte.partial_three_readers_exists_limit_any', '{perf,planning,oltp}',
    'with c as (' || :'pgmb_bomb500' || $q$)
select exists (select 1 from c where id = 50) as has_50,
       (select count(*) from (select id from c limit 200) s) as first_200,
       7 >= any (select id from c) as small_value$q$);

-- one reader that wants everything is enough to hit the bomb
call pgmb.reg('cte.err_partial_two_readers_one_reads_all', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$)
select (select id from c limit 1) as first_row, (select count(*) from c) as everything$q$, expect_error => '22012');

call pgmb.reg('cte.err_partial_two_readers_one_past_the_bomb', '{errors}',
    'with c as (' || :'pgmb_bomb500' || $q$)
select (select id from c limit 1) as first_row, (select count(*) from (select id from c limit 600) s) as first_600$q$, expect_error => '22012');

-- NOT MATERIALIZED: each reader has its own producer and its own stopping point
call pgmb.reg('cte.partial_two_readers_not_materialized', '{perf,planning,oltp}',
    'with c as not materialized (' || :'pgmb_bomb500' || $q$)
select (select id from c limit 1) as first_row, (select count(*) from (select id from c limit 100) s) as first_hundred$q$);

-- a self-join in a nested loop: the inner reader restarts for every outer row
call pgmb.reg('cte.partial_self_join_readers_stop_early', '{perf,planning,oltp}',
    'with c as materialized (' || :'pgmb_bomb500' || $q$)
select count(*) from (select id from c limit 20) a where exists (select 1 from c b where b.id = a.id + 5 offset 0)$q$);

------------------------------------------------------------------------------
-- how much work a partial read saves (real tables, nothing fails)
------------------------------------------------------------------------------
-- streaming producer: the cost follows the number of rows asked for
call pgmb.reg('cte.partial_cost_streaming_limit_10', '{perf,planning,oltp}', $q$
with c as (select id, parent_id, md5(note) as h from g_child order by id)
select count(*) from (select h from c limit 10) s$q$);

call pgmb.reg('cte.partial_cost_streaming_limit_10_materialized', '{perf,planning,oltp}', $q$
with c as materialized (select id, parent_id, md5(note) as h from g_child order by id)
select count(*) from (select h from c limit 10) s$q$);

call pgmb.reg('cte.partial_cost_streaming_limit_10000', '{perf,planning}', $q$
with c as (select id, parent_id, md5(note) as h from g_child order by id)
select count(*) from (select h from c limit 10000) s$q$);

call pgmb.reg('cte.partial_cost_streaming_read_all', '{perf,planning,olap}', $q$
with c as (select id, parent_id, md5(note) as h from g_child order by id)
select count(h) from c$q$);

-- a sort without an index: inlined, LIMIT turns it into a top-N sort; materialized,
-- the CTE is planned alone, sorts everything and then gives ten rows
call pgmb.reg('cte.partial_cost_sort_limit_10_inlined', '{perf,planning,olap}', $q$
with c as (select id, amount from g_child order by amount desc, id)
select count(*) from (select id from c limit 10) s$q$);

call pgmb.reg('cte.partial_cost_sort_limit_10_materialized', '{perf,planning,olap}', $q$
with c as materialized (select id, amount from g_child order by amount desc, id)
select count(*) from (select id from c limit 10) s$q$);

-- aggregation: hashed groups are all built before the first one is returned;
-- groups in index order are returned one by one
call pgmb.reg('cte.partial_cost_hash_aggregate_limit_1', '{perf,planning,olap}', $q$
with c as (select kind, seq, count(*) as n, sum(amount) as total from g_child group by kind, seq)
select count(*) from (select n from c limit 1) s$q$);

call pgmb.reg('cte.partial_cost_group_aggregate_in_index_order_limit_1', '{perf,planning,oltp}', $q$
with c as (select parent_id, count(*) as n, sum(amount) as total from g_child group by parent_id order by parent_id)
select count(*) from (select n from c limit 1) s$q$);

call pgmb.reg('cte.partial_cost_group_aggregate_in_index_order_materialized', '{perf,planning,olap}', $q$
with c as materialized (select parent_id, count(*) as n, sum(amount) as total from g_child group by parent_id order by parent_id)
select count(*) from (select n from c limit 1) s$q$);

-- a window over the whole set against a window per partition in index order
call pgmb.reg('cte.partial_cost_window_whole_set_limit_10', '{perf,planning,olap}', $q$
with c as (select id, amount, rank() over (order by amount desc) as r from g_child)
select count(*) from (select r from c limit 10) s$q$);

call pgmb.reg('cte.partial_cost_window_per_partition_limit_10', '{perf,planning,oltp}', $q$
with c as (select parent_id, seq, sum(amount) over (partition by parent_id order by seq) as running from g_child)
select count(*) from (select running from c limit 10) s$q$);

-- EXISTS over an expensive CTE: found at once, found late, not found
call pgmb.reg('cte.partial_cost_exists_found_at_once', '{perf,planning,oltp}', $q$
with c as materialized (select id, md5(note) as h from g_child order by id)
select exists (select 1 from c where id >= 1)$q$);

call pgmb.reg('cte.partial_cost_exists_found_halfway', '{perf,planning,olap}', $q$
with c as materialized (select id, md5(note) as h from g_child order by id)
select exists (select 1 from c where id >= :n_g_child / 2)$q$);

call pgmb.reg('cte.partial_cost_exists_not_found', '{perf,planning,olap}', $q$
with c as materialized (select id, md5(note) as h from g_child order by id)
select exists (select 1 from c where id < 0)$q$);

-- the same EXISTS inlined: the condition reaches the index and none of the three reads much
call pgmb.reg('cte.partial_cost_exists_found_halfway_inlined', '{perf,planning,oltp}', $q$
with c as (select id, md5(note) as h from g_child order by id)
select exists (select 1 from c where id >= :n_g_child / 2)$q$);

-- IN against a CTE: hashed subplan (reads all) or a prefix
call pgmb.reg('cte.partial_cost_in_hashed_reads_all', '{perf,planning,olap}', $q$
with c as materialized (select id from g_parent order by id)
select 10 in (select id from c)$q$);

call pgmb.reg('cte.partial_cost_exists_instead_of_in', '{perf,planning,oltp}', $q$
with c as materialized (select id from g_parent order by id)
select exists (select 1 from c where id = 10)$q$);

-- two readers: the CTE is produced as far as the second needs, once
call pgmb.reg('cte.partial_cost_two_readers_10_and_10000', '{perf,planning}', $q$
with c as (select id, md5(note) as h from g_child order by id)
select (select count(*) from (select h from c limit 10) s), (select count(*) from (select h from c limit 10000) s)$q$);

-- a cursor over an expensive CTE, ten rows fetched
call pgmb.reg('cte.partial_cost_cursor_fetch_10', '{perf,oltp}', $q$
begin;
declare pgmb_cur cursor for with c as materialized (select id, md5(note) as h from g_child order by id) select h from c;
fetch 10 from pgmb_cur;
close pgmb_cur;
commit;$q$);

-- a recursive CTE is produced on demand as well: ten levels of a million
call pgmb.reg('cte.partial_cost_recursive_limit_10', '{perf,planning,oltp}', $q$
with recursive r(n) as (select 1 union all select n + 1 from r where n < 1000000)
select count(*) from (select n from r limit 10) s$q$);

call pgmb.reg('cte.partial_cost_recursive_exists', '{perf,planning,oltp}', $q$
with recursive r(n) as (select 1 union all select n + 1 from r where n < 1000000)
select exists (select 1 from r where n = 100)$q$);
