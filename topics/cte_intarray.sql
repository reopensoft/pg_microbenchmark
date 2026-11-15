-- Topic: cte (part 17) - CTEs around intarray's sort() and uniq().
-- Registered only with -v intarray=1 (see data/tables.sql). The extension lives
-- in schema pgmb_intarray, off the search_path, so every call names the schema.
-- Materialized or inlined, read once or many times, predicates moved through
-- the CTE, arrays computed but never used, LIMIT, work_mem, TOAST, join order.
\if :pgmb_has_intarray

------------------------------------------------------------------------------
-- sort(): materialized, inlined, and the built-in array_sort() for comparison
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_sort_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr10) as s from g_intarr where id between :id and :id + 999)
select count(*), sum(s[1]), sum(s[10]) from c$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_sort');

-- inlined: the expression is copied to each place that reads it, here twice
call pgmb.reg('cte.intarray_sort_not_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with c as not materialized (select id, pgmb_intarray.sort(arr10) as s from g_intarr where id between :id and :id + 999)
select count(*), sum(s[1]), sum(s[10]) from c$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_sort');

call pgmb.reg('cte.intarray_sort_builtin_array_sort', '{perf,planning,consistency}', $q$
with c as materialized (select id, array_sort(arr10) as s from g_intarr where id between :id and :id + 999)
select count(*), sum(s[1]), sum(s[10]) from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_sort');

call pgmb.reg('cte.intarray_sort_already_sorted_input', '{perf,planning}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr10_sorted) as s from g_intarr where id between :id and :id + 999)
select count(*), sum(s[1]), sum(s[10]) from c$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.intarray_sort_100_elements_materialized', '{perf,planning}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 999)
select count(*), sum(s[1]), sum(s[100]) from c$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.intarray_sort_100_elements_not_materialized', '{perf,planning}', pgmb.ia($q$
with c as not materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 999)
select count(*), sum(s[1]), sum(s[100]) from c$q$),
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- uniq(sort(arr)) read five times: computed once, or once per reader
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_uniq_sort_five_readers_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with c as (select id, pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)) as u from g_intarr where id between :id and :id + 999)
select (select count(*) from c) as n,
       (select sum(cardinality(u)) from c) as elements,
       (select max(u[1]) from c) as highest_first,
       (select count(*) from c where cardinality(u) < 8) as many_duplicates,
       (select count(*) from c where u[1] = 0) as starting_at_zero$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_five');

call pgmb.reg('cte.intarray_uniq_sort_five_readers_inlined', '{perf,planning,consistency}', pgmb.ia($q$
with c as not materialized (select id, pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)) as u from g_intarr where id between :id and :id + 999)
select (select count(*) from c) as n,
       (select sum(cardinality(u)) from c) as elements,
       (select max(u[1]) from c) as highest_first,
       (select count(*) from c where cardinality(u) < 8) as many_duplicates,
       (select count(*) from c where u[1] = 0) as starting_at_zero$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_five');

-- five branches of a UNION ALL, each with its own filter on the computed array
call pgmb.reg('cte.intarray_uniq_sort_five_branches_inlined', '{perf,planning,consistency}', pgmb.ia($q$
with c as not materialized (select id, pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)) as u from g_intarr where id between :id and :id + 999)
select 5 as len, count(*) from c where cardinality(u) <= 5
union all select 6, count(*) from c where cardinality(u) = 6
union all select 7, count(*) from c where cardinality(u) = 7
union all select 8, count(*) from c where cardinality(u) = 8
union all select 9, count(*) from c where cardinality(u) >= 9$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_branches');

call pgmb.reg('cte.intarray_uniq_sort_five_branches_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)) as u from g_intarr where id between :id and :id + 999)
select 5 as len, count(*) from c where cardinality(u) <= 5
union all select 6, count(*) from c where cardinality(u) = 6
union all select 7, count(*) from c where cardinality(u) = 7
union all select 8, count(*) from c where cardinality(u) = 8
union all select 9, count(*) from c where cardinality(u) >= 9$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_branches');

-- one pass instead of five readers
call pgmb.reg('cte.intarray_uniq_sort_five_branches_single_pass', '{perf,planning}', pgmb.ia($q$
with c as (select id, pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)) as u from g_intarr where id between :id and :id + 999)
select greatest(5, least(9, cardinality(u))) as len, count(*) from c group by 1 order by 1$q$),
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- predicates moved through the CTE: @> and &&
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_pushdown_contains_builtin', '{perf,planning,consistency,oltp}', $q$
with c as (select id, arr5 from g_intarr)
select count(*) from c where arr5 @> array[:v]$q$,
    setup => '\set v random(0, 9999)', equiv => 'cte.intarray_contains');

call pgmb.reg('cte.intarray_pushdown_contains_extension', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with c as (select id, arr5 from g_intarr)
select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'cte.intarray_contains');

-- MATERIALIZED keeps the predicate outside: every row is stored, then filtered
call pgmb.reg('cte.intarray_pushdown_contains_blocked_by_materialized', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as materialized (select id, arr5 from g_intarr)
select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'cte.intarray_contains');

-- the predicate does move down, but onto sort(arr5): no index matches that
call pgmb.reg('cte.intarray_pushdown_contains_on_sorted_column', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr5) as s from g_intarr)
select count(*) from c where s operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'cte.intarray_contains');

-- through two CTEs and a join
call pgmb.reg('cte.intarray_pushdown_contains_through_chain', '{perf,planning,consistency}', pgmb.ia($q$
with a as (select id, arr5 from g_intarr),
     b as (select a.id, a.arr5, d.category from a join g_dim d on d.id = a.id % :n_g_dim + 1)
select count(*) from b where arr5 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'cte.intarray_contains');

call pgmb.reg('cte.intarray_pushdown_overlap_builtin', '{perf,planning,consistency,oltp}', $q$
with c as (select id, arr5 from g_intarr)
select count(*) from c where arr5 && array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'cte.intarray_overlap');

call pgmb.reg('cte.intarray_pushdown_overlap_extension', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with c as (select id, arr5 from g_intarr)
select count(*) from c where arr5 operator(pgmb_intarray.&&) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'cte.intarray_overlap');

call pgmb.reg('cte.intarray_pushdown_overlap_blocked_by_materialized', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as materialized (select id, arr5 from g_intarr)
select count(*) from c where arr5 operator(pgmb_intarray.&&) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'cte.intarray_overlap');

-- GiST instead of GIN (arr10)
call pgmb.reg('cte.intarray_pushdown_overlap_gist', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select id, arr10 from g_intarr)
select count(*) from c where arr10 operator(pgmb_intarray.&&) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

-- blocked by OFFSET 0 inside the CTE
call pgmb.reg('cte.intarray_pushdown_overlap_blocked_by_offset_0', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as (select id, arr5 from g_intarr offset 0)
select count(*) from c where arr5 operator(pgmb_intarray.&&) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'cte.intarray_overlap');

------------------------------------------------------------------------------
-- an array the reader never looks at
------------------------------------------------------------------------------
-- inlined: the unused column is dropped and sort() is never called
call pgmb.reg('cte.intarray_unused_array_inlined', '{perf,planning,consistency}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 999)
select count(*) from c$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_unused');

-- materialized: the CTE is planned on its own, so the array is built and
-- stored for every row although nobody reads it
call pgmb.reg('cte.intarray_unused_array_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 999)
select count(*) from c$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_unused');

-- one of two readers uses it: it has to be built for all rows
call pgmb.reg('cte.intarray_unused_array_one_reader_of_two', '{perf,planning}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 999)
select (select count(*) from c) as n, (select max(s[1]) from c where id = :id) as one_row$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.intarray_used_array_baseline', '{perf,planning}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 999)
select count(*), sum(s[1]) from c$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.intarray_no_array_baseline', '{perf,planning,consistency}', $q$
with c as (select id from g_intarr where id between :id and :id + 999)
select count(*) from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.intarray_unused');

-- an aggregate that would build arrays nobody reads: the planner removes it
call pgmb.reg('cte.intarray_unused_array_agg_per_group', '{perf,planning,olap}', pgmb.ia($q$
with c as (select arr1[1] as k, count(*) as n, pgmb_intarray.sort(array_agg(id)) as ids from g_intarr group by arr1[1])
select count(*), sum(n) from c$q$));

call pgmb.reg('cte.intarray_used_array_agg_per_group', '{perf,planning,olap}', pgmb.ia($q$
with c as (select arr1[1] as k, count(*) as n, pgmb_intarray.sort(array_agg(id)) as ids from g_intarr group by arr1[1])
select count(*), sum(n), sum(ids[1]) from c$q$));

------------------------------------------------------------------------------
-- outer LIMIT over unnest() and over array_agg()
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_unnest_outer_limit_inlined', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select id, unnest(pgmb_intarray.sort(arr100)) as v from g_intarr)
select * from c limit 10$q$));

-- a materialized CTE is filled lazily too: ten rows are produced, not all
call pgmb.reg('cte.intarray_unnest_outer_limit_materialized', '{perf,planning,oltp}', pgmb.ia($q$
with c as materialized (select id, unnest(pgmb_intarray.sort(arr100)) as v from g_intarr)
select * from c limit 10$q$));

-- ORDER BY inside the CTE: everything is unnested and sorted before the first row
call pgmb.reg('cte.intarray_unnest_outer_limit_after_inner_sort', '{perf,planning}', pgmb.ia($q$
with c as (select id, v from g_intarr, unnest(pgmb_intarray.sort(arr100)) v
           where id between :id and :id + 999 order by v)
select * from c limit 10$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.intarray_unnest_outer_limit_with_filter', '{perf,planning}', pgmb.ia($q$
with c as (select id, unnest(pgmb_intarray.sort(arr100)) as v from g_intarr)
select * from c where v < :v limit 10$q$),
    setup => '\set v random(1, 1000)');

-- array_agg per group: grouped by an expression, all groups are built first
call pgmb.reg('cte.intarray_agg_outer_limit_hash_groups', '{perf,planning,olap}', pgmb.ia($q$
with c as (select arr1[1] as k, pgmb_intarray.sort(array_agg(id)) as ids from g_intarr group by arr1[1])
select k, ids[1], cardinality(ids) from c limit 1$q$));

-- grouped by the indexed column: groups can arrive one at a time
call pgmb.reg('cte.intarray_agg_outer_limit_index_order_groups', '{perf,planning,olap}', pgmb.ia($q$
with c as (select arr1, pgmb_intarray.sort(array_agg(id)) as ids from g_intarr group by arr1)
select arr1, ids[1], cardinality(ids) from c limit 1$q$));

call pgmb.reg('cte.intarray_agg_outer_limit_single_array', '{perf,planning,olap}', pgmb.ia($q$
with c as (select pgmb_intarray.uniq(pgmb_intarray.sort(array_agg(arr1[1]))) as vals from g_intarr)
select cardinality(vals) from c limit 1$q$));

------------------------------------------------------------------------------
-- materializing wide arrays: work_mem, re-reading, TOAST
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_wide_materialized_work_mem_64kb', '{perf,olap}', pgmb.ia($q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr)
select count(*), sum(s[50]) from c;
commit;$q$));

call pgmb.reg('cte.intarray_wide_materialized_work_mem_256mb', '{perf,olap}', pgmb.ia($q$
begin;
set local work_mem = '256MB';
with c as materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr)
select count(*), sum(s[50]) from c;
commit;$q$));

call pgmb.reg('cte.intarray_wide_inlined_no_storage', '{perf,planning,olap}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr100) as s from g_intarr)
select count(*), sum(s[50]) from c$q$));

-- the stored arrays are read again: twice by a self-join, then by a third reader
call pgmb.reg('cte.intarray_materialized_reread_self_join', '{perf,planning}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 999)
select count(*), (select sum(s[100]) from c) as third_reader
from c a join c b on b.id = a.id + 1 where a.s[1] <= b.s[100]$q$),
    setup => '\set id random(1, :n_g_intarr)');

-- rescanned once per outer row
call pgmb.reg('cte.intarray_materialized_reread_per_row', '{perf,planning}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 199)
select x.id, (select count(*) from c where c.s[1] > x.s[1]) as later from c x order by x.id limit 20$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.intarray_materialized_reread_spilled', '{perf}', pgmb.ia($q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, pgmb_intarray.sort(arr100) as s from g_intarr where id between :id and :id + 1999)
select (select sum(s[1]) from c), (select sum(s[50]) from c), (select sum(s[100]) from c);
commit;$q$),
    setup => '\set id random(1, :n_g_intarr)');

-- 2000-element arrays are stored out of line: every sort() starts with a detoast
call pgmb.reg('cte.intarray_toast_sort_inlined_two_uses', '{perf,planning}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(a) as s from g_array_big where id between :id and :id + 9)
select sum(s[1]), sum(s[2000]) from c$q$),
    setup => '\set id random(1, :n_g_array_big)');

call pgmb.reg('cte.intarray_toast_sort_materialized_two_uses', '{perf,planning}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(a) as s from g_array_big where id between :id and :id + 9)
select sum(s[1]), sum(s[2000]) from c$q$),
    setup => '\set id random(1, :n_g_array_big)');

-- stored as a pointer, never fetched
call pgmb.reg('cte.intarray_toast_passed_through_untouched', '{perf,planning}', $q$
with c as materialized (select id, a from g_array_big where id between :id and :id + 9)
select count(*) from c$q$,
    setup => '\set id random(1, :n_g_array_big)');

call pgmb.reg('cte.intarray_toast_uniq_sort_cardinality', '{perf,planning}', pgmb.ia($q$
with c as (select id, pgmb_intarray.uniq(pgmb_intarray.sort(a)) as u from g_array_big where id between :id and :id + 9)
select sum(cardinality(u)), sum(pg_column_size(u)) from c$q$),
    setup => '\set id random(1, :n_g_array_big)');

call pgmb.reg('cte.intarray_toast_sorted_arrays_compared', '{perf,planning}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(a) as s from g_array_big where id between :id and :id + 9)
select count(*) from c x join c y on y.id > x.id where x.s operator(pgmb_intarray.&&) y.s$q$),
    setup => '\set id random(1, :n_g_array_big)');

------------------------------------------------------------------------------
-- sort() before the join or after it
------------------------------------------------------------------------------
-- before: all 1000 arrays are sorted, the join then keeps about 1% of them
call pgmb.reg('cte.intarray_sort_before_join', '{perf,planning,consistency}', pgmb.ia($q$
with s as materialized (select id, pgmb_intarray.sort(arr100) as arr from g_intarr where id between :id and :id + 999)
select count(*), sum(s.arr[1]) from s join g_parent p on p.id = s.id where p.grp = :g$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set g random(0, 99)', equiv => 'cte.intarray_join');

-- after: join first, sort only what is left
call pgmb.reg('cte.intarray_sort_after_join', '{perf,planning,consistency}', pgmb.ia($q$
with j as materialized (select i.id, i.arr100 from g_intarr i join g_parent p on p.id = i.id
                        where i.id between :id and :id + 999 and p.grp = :g),
     s as (select id, pgmb_intarray.sort(arr100) as arr from j)
select count(*), sum(arr[1]) from s$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set g random(0, 99)', equiv => 'cte.intarray_join');

-- written as "before", left to the planner: the expression is evaluated above the join
call pgmb.reg('cte.intarray_sort_before_join_inlined', '{perf,planning,consistency}', pgmb.ia($q$
with s as (select id, pgmb_intarray.sort(arr100) as arr from g_intarr where id between :id and :id + 999)
select count(*), sum(s.arr[1]) from s join g_parent p on p.id = s.id where p.grp = :g$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set g random(0, 99)', equiv => 'cte.intarray_join');

-- the sorted array is the join key itself: it cannot be postponed
call pgmb.reg('cte.intarray_sort_is_join_key', '{perf,planning}', pgmb.ia($q$
with s as (select id, pgmb_intarray.sort(arr10_lowcard[1:2]) as k from g_intarr where id between :id and :id + 499)
select count(*) from s a join s b on b.k = a.k and b.id > a.id$q$),
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- sort, then uniq, then filter, as separate CTEs
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_chain_sort_uniq_filter', '{perf,planning,consistency}', pgmb.ia($q$
with sorted as (select id, pgmb_intarray.sort(arr10_lowcard) as a from g_intarr where id between :id and :id + 999),
     deduped as (select id, pgmb_intarray.uniq(a) as a from sorted),
     kept as (select id, a from deduped where a operator(pgmb_intarray.@>) array[:v] and cardinality(a) >= 7)
select count(*), sum(a[1]) from kept$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 19)', equiv => 'cte.intarray_chain');

call pgmb.reg('cte.intarray_chain_sort_uniq_filter_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with sorted as materialized (select id, pgmb_intarray.sort(arr10_lowcard) as a from g_intarr where id between :id and :id + 999),
     deduped as materialized (select id, pgmb_intarray.uniq(a) as a from sorted),
     kept as materialized (select id, a from deduped where a operator(pgmb_intarray.@>) array[:v] and cardinality(a) >= 7)
select count(*), sum(a[1]) from kept$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 19)', equiv => 'cte.intarray_chain');

call pgmb.reg('cte.intarray_chain_single_expression', '{perf,planning,consistency}', pgmb.ia($q$
select count(*), sum((pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)))[1])
from g_intarr
where id between :id and :id + 999
  and pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)) operator(pgmb_intarray.@>) array[:v]
  and cardinality(pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard))) >= 7$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 19)', equiv => 'cte.intarray_chain');

-- filter first: containment does not need the array sorted or deduplicated
call pgmb.reg('cte.intarray_chain_filter_sort_uniq', '{perf,planning,consistency}', pgmb.ia($q$
with kept as (select id, arr10_lowcard as a from g_intarr
              where id between :id and :id + 999 and arr10_lowcard operator(pgmb_intarray.@>) array[:v]),
     sorted as (select id, pgmb_intarray.sort(a) as a from kept),
     deduped as (select id, pgmb_intarray.uniq(a) as a from sorted)
select count(*), sum(a[1]) from deduped where cardinality(a) >= 7$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 19)', equiv => 'cte.intarray_chain');

------------------------------------------------------------------------------
-- one array built by array_agg(), several consumers
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_agg_array_three_consumers', '{perf,planning}', pgmb.ia($q$
with k as (select pgmb_intarray.uniq(pgmb_intarray.sort(array_agg(arr5[1]))) as vals
           from g_intarr where id between :id and :id + 199)
select (select pgmb_intarray.icount(vals) from k) as n,
       (select count(*) from g_intarr g, k where g.id between :id + 200 and :id + 1199 and g.arr5 operator(pgmb_intarray.&&) k.vals) as overlapping_rows,
       (select count(*) from k, unnest(vals) v join g_narrow nr on nr.id = v) as keys_found$q$),
    setup => '\set id random(1, :n_g_intarr)');

-- the aggregated array as an index key: GIN with the extension's operator class
call pgmb.reg('cte.intarray_agg_array_as_overlap_key', '{perf,planning}', pgmb.ia($q$
with k as (select pgmb_intarray.uniq(pgmb_intarray.sort(array_agg(arr5[1]))) as vals
           from g_intarr where id between :id and :id + 9)
select count(*) from g_intarr g where g.arr5 operator(pgmb_intarray.&&) (select vals from k)$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.intarray_agg_array_five_consumers', '{perf,planning}', pgmb.ia($q$
with k as (select pgmb_intarray.sort(array_agg(id)) as ids from g_intarr where arr1 = array[:v])
select (select cardinality(ids) from k),
       (select ids[1] from k),
       (select count(*) from g_intarr where id = any ((select ids from k)::integer[])),
       (select count(*) from k, unnest(ids) x where x % 2 = 0),
       (select pgmb_intarray.idx(ids, ids[cardinality(ids)]) from k)$q$),
    setup => '\set v random(0, 99)');
\endif
