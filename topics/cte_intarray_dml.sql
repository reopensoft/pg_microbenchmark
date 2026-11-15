-- Topic: cte (part 18) - writes to integer[] columns from CTEs with intarray,
-- NULL handling of the extension, and when its errors are raised.
-- Registered only with -v intarray=1. Table g_ia_dml: a_gin (GIN gin__int_ops),
-- a_gist (GiST gist__int_ops), a_plain (no index), a_big (500 elements), n.
-- Operators: a + x appends, a - x removes every x, a | b is the set union.
-- "subarray(a, 2) + x" drops the first element and appends one: the length
-- stays the same, so the tests can run for any time without changing the data shape.
\if :pgmb_has_intarray

------------------------------------------------------------------------------
-- INSERT ... RETURNING integer[]
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_dml_insert_returning_array', '{perf,planning,oltp}', pgmb.ia($q$
with ins as (insert into g_ia_dml (id, a_gin, a_gist, a_plain, a_big, n)
             values (:id, array[:v, :w, :x], array[:v, :w, :x], array[:v, :w, :x], array[:v], 0)
             on conflict do nothing
             returning a_gin)
select a_gin, pgmb_intarray.icount(a_gin), pgmb_intarray.sort(a_gin) from ins$q$),
    kind => 'write', setup => E'\\set id random(:n_g_ia_dml + 1, 2 * :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)\n\\set x random(0, 99)');

call pgmb.reg('cte.intarray_dml_insert_returning_array_batch', '{perf,planning}', pgmb.ia($q$
with ins as (insert into g_ia_dml (id, a_gin, a_gist, a_plain, a_big, n)
             select i, array[i % 100, :v], array[i % 100, :v], array[i % 100, :v], array[:v], 0
             from generate_series(:id, :id + 19) i
             on conflict do nothing
             returning a_gin)
select count(*), sum(pgmb_intarray.icount(a_gin)) from ins$q$),
    kind => 'write', setup => E'\\set id random(:n_g_ia_dml + 1, 2 * :n_g_ia_dml - 20)\n\\set v random(0, 99)');

------------------------------------------------------------------------------
-- UPDATE with the extension's operators
------------------------------------------------------------------------------
-- append (the first element is dropped, so the array keeps its length)
call pgmb.reg('cte.intarray_dml_update_append_element', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 2) operator(pgmb_intarray.+) :v
           where id = :id returning a_gin)
select a_gin from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_update_append_array', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 3) operator(pgmb_intarray.+) array[:v, :w]
           where id = :id returning a_gin)
select a_gin from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)');

-- remove every occurrence of a value; most rows do not contain it
call pgmb.reg('cte.intarray_dml_update_remove_element', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_plain = a_plain operator(pgmb_intarray.-) :v
           where id = :id returning a_plain)
select a_plain from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

-- remove and add in one expression: the value moves to the end
call pgmb.reg('cte.intarray_dml_update_remove_then_append', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = (a_gin operator(pgmb_intarray.-) a_gin[1]) operator(pgmb_intarray.+) a_gin[1]
           where id = :id returning a_gin)
select a_gin from u$q$),
    kind => 'write', setup => '\set id random(1, :n_g_ia_dml)');

-- remove from the rows that contain the value, found through the index
call pgmb.reg('cte.intarray_dml_update_remove_where_contains', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = (a_gin operator(pgmb_intarray.-) :v) operator(pgmb_intarray.+) :w
           where a_gin operator(pgmb_intarray.@>) array[:v] and id between :id and :id + 199
           returning id)
select count(*) from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)');

-- normalize: sorted, without duplicates
call pgmb.reg('cte.intarray_dml_update_uniq_sort', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_plain = pgmb_intarray.uniq(pgmb_intarray.sort(a_plain))
           where id = :id returning a_plain)
select a_plain from u$q$),
    kind => 'write', setup => '\set id random(1, :n_g_ia_dml)');

call pgmb.reg('cte.intarray_dml_update_uniq_sort_indexed', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.uniq(pgmb_intarray.sort(a_gin))
           where id = :id returning a_gin)
select a_gin from u$q$),
    kind => 'write', setup => '\set id random(1, :n_g_ia_dml)');

-- only the rows that are not normalized yet
call pgmb.reg('cte.intarray_dml_update_uniq_sort_only_changed', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set a_plain = pgmb_intarray.uniq(pgmb_intarray.sort(a_plain))
           where id between :id and :id + 99
             and a_plain is distinct from pgmb_intarray.uniq(pgmb_intarray.sort(a_plain))
           returning id)
select count(*) from u$q$),
    kind => 'write', setup => '\set id random(1, :n_g_ia_dml)');

------------------------------------------------------------------------------
-- DELETE by arr @@ query_int
------------------------------------------------------------------------------
-- among the rows the insert tests add (ids above n)
call pgmb.reg('cte.intarray_dml_delete_by_query_int', '{perf,planning,oltp}', pgmb.ia($q$
with d as (delete from g_ia_dml
           where id > :n_g_ia_dml and a_gin operator(pgmb_intarray.@@) ':v&:w'
           returning id, a_gin)
select count(*), max(a_gin) from d$q$),
    kind => 'write', setup => E'\\set v random(0, 99)\n\\set w random(0, 99)');

-- loaded rows: deleted and put back in the same statement
call pgmb.reg('cte.intarray_dml_delete_by_query_int_reinsert', '{perf,planning,oltp}', pgmb.ia($q$
with d as (delete from g_ia_dml
           where id between :id and :id + 199 and a_gin operator(pgmb_intarray.@@) ':v|:w'
           returning *)
insert into g_ia_dml select * from d$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)');

call pgmb.reg('cte.intarray_dml_delete_by_negated_query_int', '{perf,planning}', pgmb.ia($q$
with d as (delete from g_ia_dml
           where id between :id and :id + 19 and a_plain operator(pgmb_intarray.@@) '!:v&!:w'
           returning *)
insert into g_ia_dml select * from d$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)');

------------------------------------------------------------------------------
-- ON CONFLICT DO UPDATE that changes the array
------------------------------------------------------------------------------
-- set union: bounded by the number of distinct values
call pgmb.reg('cte.intarray_dml_on_conflict_union', '{perf,planning,oltp}', pgmb.ia($q$
with ups as (insert into g_ia_dml (id, a_gin, a_gist, a_plain, a_big, n)
             values (:id, array[:v, :w], array[:v, :w], array[:v, :w], array[:v], 0)
             on conflict (id) do update
                 set a_gin = g_ia_dml.a_gin operator(pgmb_intarray.|) excluded.a_gin, n = g_ia_dml.n + 1
             returning a_gin, (xmax = 0) as inserted)
select inserted, pgmb_intarray.icount(a_gin) from ups$q$),
    kind => 'write', setup => E'\\set id random(1, 2 * :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)');

call pgmb.reg('cte.intarray_dml_on_conflict_append', '{perf,planning,oltp}', pgmb.ia($q$
with ups as (insert into g_ia_dml (id, a_gin, a_gist, a_plain, a_big, n)
             values (:id, array[:v], array[:v], array[:v], array[:v], 0)
             on conflict (id) do update
                 set a_plain = pgmb_intarray.subarray(g_ia_dml.a_plain, 2) operator(pgmb_intarray.+) excluded.a_plain
             returning a_plain)
select a_plain from ups$q$),
    kind => 'write', setup => E'\\set id random(1, 2 * :n_g_ia_dml)\n\\set v random(0, 99)');

-- DO UPDATE only when the array would change
call pgmb.reg('cte.intarray_dml_on_conflict_union_if_new', '{perf,planning,oltp}', pgmb.ia($q$
with ups as (insert into g_ia_dml (id, a_gin, a_gist, a_plain, a_big, n)
             values (:id, array[:v], array[:v], array[:v], array[:v], 0)
             on conflict (id) do update
                 set a_gin = g_ia_dml.a_gin operator(pgmb_intarray.|) excluded.a_gin
                 where not (g_ia_dml.a_gin operator(pgmb_intarray.@>) excluded.a_gin)
             returning id)
select count(*) from ups$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

------------------------------------------------------------------------------
-- RETURNING large arrays, several readers of a writer
------------------------------------------------------------------------------
call pgmb.reg('cte.intarray_dml_returning_big_arrays_aggregated', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set n = n + 1 where id between :id and :id + 99 returning a_big)
select count(*), sum(pgmb_intarray.icount(a_big)) from u$q$),
    kind => 'write', setup => '\set id random(1, :n_g_ia_dml)');

call pgmb.reg('cte.intarray_dml_returning_big_arrays_to_client', '{perf,planning}', $q$
with u as (update g_ia_dml set n = n + 1 where id between :id and :id + 9 returning id, a_big)
select id, a_big from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_ia_dml)');

-- the large array itself is rewritten, and returned sorted
call pgmb.reg('cte.intarray_dml_returning_big_array_modified', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set a_big = pgmb_intarray.subarray(a_big, 2) operator(pgmb_intarray.+) :v
           where id = :id returning a_big)
select pgmb_intarray.icount(a_big), (pgmb_intarray.sort(a_big))[1] from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99999)');

-- not asked for: the writer does not return the array at all
call pgmb.reg('cte.intarray_dml_returning_without_big_array', '{perf,planning}', $q$
with u as (update g_ia_dml set n = n + 1 where id between :id and :id + 99 returning id)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_ia_dml)');

-- one writer, three readers of the returned arrays: executed once
call pgmb.reg('cte.intarray_dml_returning_array_three_readers', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set a_plain = pgmb_intarray.subarray(a_plain, 2) operator(pgmb_intarray.+) :v
           where id between :id and :id + 49 returning id, a_plain)
select (select count(*) from u) as n,
       (select sum(x) from u, unnest(a_plain) x) as total,
       (select count(*) from u a join u b on b.id = a.id + 1 where a.a_plain operator(pgmb_intarray.&&) b.a_plain) as overlapping_neighbours$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

-- old and new array side by side (RETURNING old/new)
call pgmb.reg('cte.intarray_dml_returning_old_and_new_array', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_plain = pgmb_intarray.subarray(a_plain, 2) operator(pgmb_intarray.+) :v
           where id = :id returning old.a_plain as before, new.a_plain as after)
select before operator(pgmb_intarray.-) after as removed, after operator(pgmb_intarray.-) before as added from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

-- nobody reads the writer: it still runs
call pgmb.reg('cte.intarray_dml_unreferenced_writer', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 2) operator(pgmb_intarray.+) :v where id = :id)
select 1$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_unreferenced_writer_batch', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 2) operator(pgmb_intarray.+) :v
           where id between :id and :id + 99 returning a_gin)
select 1$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

------------------------------------------------------------------------------
-- what an update costs under each index, and when it can be HOT
-- (same statement, same new value, different column)
------------------------------------------------------------------------------
-- no indexed column changes: heap-only update
call pgmb.reg('cte.intarray_dml_hot_counter', '{perf,planning,oltp}', $q$
with u as (update g_ia_dml set n = n + 1 where id = :id returning id)
select count(*) from u$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_hot_unindexed_array', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_plain = pgmb_intarray.subarray(a_plain, 2) operator(pgmb_intarray.+) :v where id = :id returning id)
select count(*) from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

-- an indexed array changes: new entries in every index of the table
call pgmb.reg('cte.intarray_dml_not_hot_gin_array', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 2) operator(pgmb_intarray.+) :v where id = :id returning id)
select count(*) from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_not_hot_gist_array', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gist = pgmb_intarray.subarray(a_gist, 2) operator(pgmb_intarray.+) :v where id = :id returning id)
select count(*) from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_not_hot_both_indexed_arrays', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 2) operator(pgmb_intarray.+) :v,
                              a_gist = pgmb_intarray.subarray(a_gist, 2) operator(pgmb_intarray.+) :v
           where id = :id returning id)
select count(*) from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

-- the indexed column is assigned its own value: nothing changes for the index
call pgmb.reg('cte.intarray_dml_hot_indexed_array_same_value', '{perf,planning,oltp}', $q$
with u as (update g_ia_dml set a_gin = a_gin, n = n + 1 where id = :id returning id)
select count(*) from u$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

-- same set of keys in another order: a different value, the same index keys
call pgmb.reg('cte.intarray_dml_not_hot_gin_array_reordered', '{perf,planning,oltp}', $q$
with u as (update g_ia_dml set a_gin = array_reverse(a_gin) where id = :id returning id)
select count(*) from u$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_hot_counter_100_rows', '{perf,planning}', $q$
with u as (update g_ia_dml set n = n + 1 where id between :id and :id + 99 returning id)
select count(*) from u$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_not_hot_gin_array_100_rows', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 2) operator(pgmb_intarray.+) :v
           where id between :id and :id + 99 returning id)
select count(*) from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

call pgmb.reg('cte.intarray_dml_not_hot_gist_array_100_rows', '{perf,planning}', pgmb.ia($q$
with u as (update g_ia_dml set a_gist = pgmb_intarray.subarray(a_gist, 2) operator(pgmb_intarray.+) :v
           where id between :id and :id + 99 returning id)
select count(*) from u$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)');

-- reading through each index right after writing to it, in one statement
call pgmb.reg('cte.intarray_dml_update_then_search_gin', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gin = pgmb_intarray.subarray(a_gin, 2) operator(pgmb_intarray.+) :v where id = :id returning id)
select (select count(*) from u) as updated,
       (select count(*) from g_ia_dml where a_gin operator(pgmb_intarray.@>) array[:v, :w]) as found_in_snapshot$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)');

call pgmb.reg('cte.intarray_dml_update_then_search_gist', '{perf,planning,oltp}', pgmb.ia($q$
with u as (update g_ia_dml set a_gist = pgmb_intarray.subarray(a_gist, 2) operator(pgmb_intarray.+) :v where id = :id returning id)
select (select count(*) from u) as updated,
       (select count(*) from g_ia_dml where a_gist operator(pgmb_intarray.@>) array[:v, :w]) as found_in_snapshot$q$),
    kind => 'write', setup => E'\\set id random(1, :n_g_ia_dml)\n\\set v random(0, 99)\n\\set w random(0, 99)');

------------------------------------------------------------------------------
-- NULL: the array is NULL, or the array has a NULL element
------------------------------------------------------------------------------
-- a NULL array: the functions are strict and return NULL.
-- a NULL element: icount() counts it, everything else refuses the array.
call pgmb.reg('cte.intarray_null_array_vs_null_element', '{perf,planning,oltp}', pgmb.ia($q$
with c(null_array, null_element) as (select null::integer[], array[null::integer])
select pgmb_intarray.sort(null_array) is null as sort_of_null_array,
       pgmb_intarray.uniq(null_array) is null as uniq_of_null_array,
       pgmb_intarray.icount(null_array) is null as icount_of_null_array,
       (null_array operator(pgmb_intarray.+) 1) is null as append_to_null_array,
       (array[1, 2] operator(pgmb_intarray.+) null::integer) is null as append_null_value,
       pgmb_intarray.icount(null_element) as icount_of_null_element,
       cardinality(null_array) is null as cardinality_of_null_array,
       cardinality(null_element) as cardinality_of_null_element
from c$q$));

call pgmb.reg('cte.err_intarray_null_element_sort_in_cte', '{errors,needs_data}',
    pgmb.ia($q$with c as (select pgmb_intarray.sort(arr_nulls) as s from g_intarr) select max(s[1]) from c$q$), expect_error => '22004');
call pgmb.reg('cte.err_intarray_null_element_uniq_in_cte', '{errors,needs_data}',
    pgmb.ia($q$with c as (select pgmb_intarray.uniq(arr_nulls) as s from g_intarr) select max(s[1]) from c$q$), expect_error => '22004');
call pgmb.reg('cte.err_intarray_null_element_append_in_cte', '{errors,needs_data}',
    pgmb.ia($q$with c as (select arr_nulls operator(pgmb_intarray.+) 1 as s from g_intarr) select max(s[1]) from c$q$), expect_error => '22004');
call pgmb.reg('cte.err_intarray_null_element_remove_in_cte', '{errors,needs_data}',
    pgmb.ia($q$with c as (select arr_nulls operator(pgmb_intarray.-) 1 as s from g_intarr) select max(s[1]) from c$q$), expect_error => '22004');
call pgmb.reg('cte.err_intarray_null_element_union_in_cte', '{errors,needs_data}',
    pgmb.ia($q$with c as (select arr_nulls operator(pgmb_intarray.|) arr5 as s from g_intarr) select max(s[1]) from c$q$), expect_error => '22004');
call pgmb.reg('cte.err_intarray_null_element_literal', '{errors}',
    pgmb.ia($q$with c(a) as (select array[null::integer]) select pgmb_intarray.sort(a) from c$q$), expect_error => '22004');

-- icount() is the exception: it never looks at the elements
call pgmb.reg('cte.intarray_null_element_icount_allowed', '{perf,planning,olap}', pgmb.ia($q$
with c as (select pgmb_intarray.icount(arr_nulls) as n from g_intarr)
select count(*), count(n), sum(n) from c$q$));

------------------------------------------------------------------------------
-- keeping arrays with NULL elements away from the extension
------------------------------------------------------------------------------
-- CASE decides per row: the guarded branch is evaluated only for clean arrays
call pgmb.reg('cte.intarray_null_guard_case', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as (select case when array_position(arr_nulls, null) is null then pgmb_intarray.sort(arr_nulls) end as s from g_intarr)
select count(*) from c where s operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 999)', equiv => 'cte.intarray_null_guard');

-- the rows are filtered inside a MATERIALIZED CTE: the extension sees clean arrays only
call pgmb.reg('cte.intarray_null_guard_materialized_filter', '{perf,planning,consistency,olap}', pgmb.ia($q$
with clean as materialized (select arr_nulls from g_intarr where array_position(arr_nulls, null) is null)
select count(*) from clean where pgmb_intarray.sort(arr_nulls) operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 999)', equiv => 'cte.intarray_null_guard');

-- the same with an inlined CTE: both conditions end up in one WHERE and their
-- order is the planner's choice. It works here; nothing guarantees it.
call pgmb.reg('cte.intarray_null_guard_inlined_filter', '{perf,planning,consistency,olap}', pgmb.ia($q$
with clean as (select arr_nulls from g_intarr where array_position(arr_nulls, null) is null)
select count(*) from clean where pgmb_intarray.sort(arr_nulls) operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 999)', equiv => 'cte.intarray_null_guard');

-- OFFSET 0 keeps the filter below without storing the rows
call pgmb.reg('cte.intarray_null_guard_offset_0_filter', '{perf,planning,consistency,olap}', pgmb.ia($q$
with clean as (select arr_nulls from g_intarr where array_position(arr_nulls, null) is null offset 0)
select count(*) from clean where pgmb_intarray.sort(arr_nulls) operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 999)', equiv => 'cte.intarray_null_guard');

-- the NULL elements are removed instead of the rows: more rows qualify
call pgmb.reg('cte.intarray_null_removed_with_array_remove', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as (select pgmb_intarray.sort(array_remove(arr_nulls, null)) as s from g_intarr)
select count(*) from c where s operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 999)', equiv => 'cte.intarray_null_removed');

call pgmb.reg('cte.intarray_null_ignored_by_builtin_operator', '{perf,planning,consistency,olap}', $q$
with c as (select arr_nulls from g_intarr)
select count(*) from c where arr_nulls @> array[:v]$q$,
    setup => '\set v random(0, 999)', equiv => 'cte.intarray_null_removed');

-- a branch that is never taken, with a constant condition: removed before anything is evaluated
call pgmb.reg('cte.intarray_null_in_untaken_constant_case_branch', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select case when false then pgmb_intarray.sort(array[1, null]) else array[0] end as s)
select s from c$q$));

-- a branch that is never taken at run time, but whose constant content the
-- planner evaluates ahead of time: the error comes from planning
call pgmb.reg('cte.err_intarray_null_in_constant_folded_case_branch', '{errors}',
    pgmb.ia($q$with c as (select case when id > 0 then array[0] else pgmb_intarray.sort(array[1, null]) end as s from g_intarr where id = 1) select s from c$q$), expect_error => '22004');

-- the same branch made of a column: evaluated only when taken, so no error
call pgmb.reg('cte.intarray_null_in_untaken_column_case_branch', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select case when id > 0 then array[0] else pgmb_intarray.sort(arr_nulls) end as s from g_intarr where id = :id)
select s from c$q$),
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- materialization and the moment an error is raised
------------------------------------------------------------------------------
-- the failing column is never read. Inlined, it is never computed: no error
call pgmb.reg('cte.intarray_error_column_unused_inlined', '{perf,planning,olap}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr)
select count(*) from c$q$));

-- materialized, the column is computed for every row: the statement fails
call pgmb.reg('cte.err_intarray_error_column_unused_materialized', '{errors,needs_data}',
    pgmb.ia($q$with c as materialized (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr) select count(*) from c$q$), expect_error => '22004');

-- the reader stops before the first bad row (id 1 is clean, id 2 is not)
call pgmb.reg('cte.intarray_error_behind_limit_inlined', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr where id >= 1 order by id)
select s from c limit 1$q$));

-- a materialized CTE is filled on demand as well: still no error
call pgmb.reg('cte.intarray_error_behind_limit_materialized', '{perf,planning,oltp}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr where id >= 1 order by id)
select s from c limit 1$q$));

call pgmb.reg('cte.err_intarray_error_within_limit', '{errors,needs_data}',
    pgmb.ia($q$with c as (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr where id >= 1 order by id) select s from c limit 2$q$), expect_error => '22004');

-- sorting by the computed column needs all of them before the first row
call pgmb.reg('cte.err_intarray_error_before_limit_sorted_by_result', '{errors,needs_data}',
    pgmb.ia($q$with c as (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr) select s from c order by s limit 1$q$), expect_error => '22004');

-- two readers force materialization, one of them never touches the column
call pgmb.reg('cte.err_intarray_error_two_readers_one_ignores_column', '{errors,needs_data}',
    pgmb.ia($q$with c as (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr) select (select count(*) from c), (select max(id) from c)$q$), expect_error => '22004');

call pgmb.reg('cte.intarray_error_exists_stops_first', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr_nulls) as s from g_intarr where id >= 1 order by id)
select exists (select 1 from c where s is not null)$q$));

------------------------------------------------------------------------------
-- an error inside a recursive CTE
------------------------------------------------------------------------------
-- the array picks up a NULL element at depth 3 and the next step fails
call pgmb.reg('cte.err_intarray_recursive_null_element_at_depth', '{errors}', pgmb.ia($q$
with recursive r(n, a) as (
    select 1, array[1]
    union all
    select n + 1, array_append(pgmb_intarray.sort(a), case when n = 3 then null else n end) from r where n < 10)
select count(*) from r$q$), expect_error => '22004');

-- walking the table row by row: id 1 is clean, id 2 stops the recursion with an error
call pgmb.reg('cte.err_intarray_recursive_walk_hits_null_row', '{errors,needs_data}', pgmb.ia($q$
with recursive r(id, s) as (
    select id, pgmb_intarray.sort(arr_nulls) from g_intarr where id = 1
    union all
    select g.id, pgmb_intarray.sort(g.arr_nulls) from r join g_intarr g on g.id = r.id + 1 where r.id < 5)
select count(*) from r$q$), expect_error => '22004');

-- the same recursions without the NULL
call pgmb.reg('cte.intarray_recursive_sort_growing_array', '{perf,planning}', pgmb.ia($q$
with recursive r(n, a) as (
    select 1, array[:v]
    union all
    select n + 1, pgmb_intarray.sort(a operator(pgmb_intarray.+) ((n * 7919 + :v) % 1000)) from r where n < 200)
select count(*), max(pgmb_intarray.icount(a)) from r$q$),
    setup => '\set v random(0, 999)');

call pgmb.reg('cte.intarray_recursive_walk_clean_rows', '{perf,planning}', pgmb.ia($q$
with recursive r(id, s) as (
    select id, pgmb_intarray.sort(arr10) from g_intarr where id = :id
    union all
    select g.id, pgmb_intarray.sort(g.arr10) from r join g_intarr g on g.id = r.id + 1 where r.id < :id + 99)
select count(*), sum(s[1]) from r$q$),
    setup => '\set id random(1, :n_g_intarr)');

-- union of everything reachable: the accumulated array is the recursion state
call pgmb.reg('cte.intarray_recursive_accumulate_union', '{perf,planning}', pgmb.ia($q$
with recursive r(id, seen) as (
    select id, pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)) from g_intarr where id = :id
    union all
    select g.id, r.seen operator(pgmb_intarray.|) g.arr10_lowcard
    from r join g_intarr g on g.id = r.id + 1
    where r.id < :id + 49 and pgmb_intarray.icount(r.seen) < 20)
select count(*) as steps_until_all_20_values_seen, max(pgmb_intarray.icount(seen)) from r$q$),
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- an error in a writer: the whole statement is undone
------------------------------------------------------------------------------
-- the first writer has already updated its row when the second one fails
call pgmb.reg('cte.err_intarray_dml_second_writer_fails', '{errors,needs_data}', pgmb.ia($q$
with ok as (update g_ia_dml set n = n + 1 where id = 1 returning id),
     bad as (update g_ia_dml set a_plain = pgmb_intarray.sort(array_append(a_plain, null)) where id = 2 returning id)
select (select count(*) from ok), (select count(*) from bad)$q$), expect_error => '22004');

call pgmb.reg('cte.err_intarray_dml_error_in_returning', '{errors,needs_data}', pgmb.ia($q$
with u as (update g_ia_dml set n = n + 1 where id = 1
           returning pgmb_intarray.sort(array_append(a_plain, null)) as s)
select count(*) from u$q$), expect_error => '22004');

call pgmb.reg('cte.err_intarray_dml_error_in_reader', '{errors,needs_data}', pgmb.ia($q$
with u as (update g_ia_dml set n = n + 1 where id = 1 returning a_plain)
select pgmb_intarray.sort(array_append(a_plain, null)) from u$q$), expect_error => '22004');

-- pgbench drops a client on an error, so the failure is caught in a DO block:
-- 100 rows are updated by the first writer, then everything is rolled back
call pgmb.reg('cte.intarray_dml_error_rolls_back_100_rows', '{perf}', pgmb.ia($q$
do $do$
declare cnt bigint;
begin
    with ok as (update pgmb_data.g_ia_dml set n = n + 1 where id between 1 and 100 returning id),
         bad as (update pgmb_data.g_ia_dml set a_plain = pgmb_intarray.sort(array_append(a_plain, null)) where id = 101 returning id)
    select (select count(*) from ok) + (select count(*) from bad) into cnt;
exception when null_value_not_allowed then null;
end $do$$q$),
    kind => 'write');

-- the same statement without the failing writer
call pgmb.reg('cte.intarray_dml_no_error_commits_100_rows', '{perf}', pgmb.ia($q$
do $do$
declare cnt bigint;
begin
    with ok as (update pgmb_data.g_ia_dml set n = n + 1 where id between 1 and 100 returning id),
         fine as (update pgmb_data.g_ia_dml set a_plain = pgmb_intarray.sort(a_plain) where id = 101 returning id)
    select (select count(*) from ok) + (select count(*) from fine) into cnt;
exception when null_value_not_allowed then null;
end $do$$q$),
    kind => 'write');
\endif
