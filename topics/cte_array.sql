-- Topic: cte (part 16) - CTEs that return integer[] values.
-- Literals, empty and NULL arrays, NULL elements, dimensions and lower bounds,
-- element types and overload resolution, array_agg as a CTE source, unnest and
-- re-aggregation, large (TOASTed) and wide arrays, whole-array comparison in
-- UNION / DISTINCT / GROUP BY. Tables: g_intarr, g_array_big.

------------------------------------------------------------------------------
-- array literals returned by a CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.array_literal', '{perf,planning,oltp}', $q$
with c(a) as (select array[1, 2, 3])
select a, a[2], cardinality(a) from c$q$);

-- the literal as a search key: the reader gets a constant
call pgmb.reg('cte.array_literal_as_overlap_key', '{perf,planning,consistency,oltp}', $q$
with c(a) as (select array[:v, :v + 1, :v + 2])
select count(*) from g_intarr, c where arr5 && c.a$q$,
    setup => '\set v random(0, 9997)', equiv => 'cte.array_key');

call pgmb.reg('cte.array_literal_as_overlap_key_materialized', '{perf,planning,consistency,oltp}', $q$
with c(a) as materialized (select array[:v, :v + 1, :v + 2])
select count(*) from g_intarr, c where arr5 && c.a$q$,
    setup => '\set v random(0, 9997)', equiv => 'cte.array_key');

call pgmb.reg('cte.array_literal_inline_baseline', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 && array[:v, :v + 1, :v + 2]$q$,
    setup => '\set v random(0, 9997)', equiv => 'cte.array_key');

call pgmb.reg('cte.array_literal_as_any_keys', '{perf,planning,oltp}', $q$
with c(a) as (select array[:id, :id + 1, :id + 2, :id + 3, :id + 4])
select count(*) from g_intarr where id = any ((select a from c)::int[])$q$,
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- empty array, NULL array, NULL elements
------------------------------------------------------------------------------
call pgmb.reg('cte.array_empty', '{perf,planning,oltp}', $q$
with c(a) as (select array[]::integer[])
select cardinality(a), a = '{}', array_length(a, 1) is null, a[1] is null, (select count(*) from unnest(a)) from c$q$);

call pgmb.reg('cte.array_empty_as_any_keys', '{perf,planning,oltp}', $q$
with c(a) as (select array[]::integer[])
select count(*) from g_intarr where id = any ((select a from c)::int[])$q$);

call pgmb.reg('cte.array_empty_as_overlap_key', '{perf,planning,oltp}', $q$
with c(a) as (select array[]::integer[])
select count(*) from g_intarr, c where arr5 && c.a$q$);

call pgmb.reg('cte.array_null', '{perf,planning,oltp}', $q$
with c(a) as (select null::integer[])
select a is null, cardinality(a), :v = any (a), coalesce(a, '{}'), (select count(*) from unnest(a)) from c$q$,
    setup => '\set v random(0, 99)');

call pgmb.reg('cte.array_null_as_any_keys', '{perf,planning,oltp}', $q$
with c(a) as (select null::integer[])
select count(*) from g_intarr where id = any ((select a from c)::int[])$q$);

call pgmb.reg('cte.array_null_elements', '{perf,planning,oltp}', $q$
with c(a) as (select array[1, null, 3])
select cardinality(a), array_position(a, null), 1 = any (a) as found, 2 = any (a) as unknown,
       array_remove(a, null), a = array[1, null, 3] as equal_with_nulls, (select count(x) from unnest(a) x) from c$q$);

call pgmb.reg('cte.array_null_elements_from_table', '{perf,planning}', $q$
with c as (select id, arr_nulls as a from g_intarr where id between :id and :id + 999)
select count(*) as n, count(a) as not_null_arrays,
       count(*) filter (where array_position(a, null) is not null) as with_null_element,
       sum(cardinality(array_remove(a, null))) as elements
from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_null_empty_and_filled_together', '{perf,planning,oltp}', $q$
with c(tag, a) as (values ('null', null::integer[]), ('empty', '{}'), ('nulls', array[null, null]::integer[]), ('filled', array[1, 2]))
select tag, a is null, cardinality(a), array_length(a, 1), coalesce(a, '{}') = '{}' from c$q$);

------------------------------------------------------------------------------
-- dimensions and lower bounds
------------------------------------------------------------------------------
call pgmb.reg('cte.array_two_dimensional_literal', '{perf,planning,oltp}', $q$
with c(m) as (select array[[1, 2, 3], [4, 5, 6]])
select array_ndims(m), array_dims(m), cardinality(m), m[2][3], m[1:2][2:3], m[2:2], (select sum(x) from unnest(m) x) from c$q$);

-- array_agg over arrays builds a matrix with one row per input row
call pgmb.reg('cte.array_two_dimensional_from_rows', '{perf,planning}', $q$
with c as (select array_agg(arr5 order by id) as m from g_intarr where id between :id and :id + 99)
select array_ndims(m), array_dims(m), cardinality(m), m[1][1], m[array_upper(m, 1)][5] from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_three_dimensional_literal', '{perf,planning,oltp}', $q$
with c(t) as (select array[[[1, 2], [3, 4]], [[5, 6], [7, 8]]])
select array_ndims(t), array_dims(t), t[2][1][2], cardinality(t) from c$q$);

call pgmb.reg('cte.array_lower_bound_zero', '{perf,planning,oltp}', $q$
with c(z) as (select '[0:2]={10,20,30}'::integer[])
select z[0], z[3] is null, array_lower(z, 1), array_upper(z, 1), array_dims(z), cardinality(z),
       z[1:2] as slice_is_one_based, array_dims(z || 40) as append_keeps_bound from c$q$);

call pgmb.reg('cte.array_lower_bound_zero_from_table', '{perf,planning}', $q$
with c as (select id, ('[0:4]=' || arr5::text)::integer[] as z, arr5 from g_intarr where id between :id and :id + 999)
select count(*), sum(z[0] - arr5[1]) as same_first, count(*) filter (where z = arr5) as equal_arrays,
       count(*) filter (where array(select unnest(z)) = arr5) as equal_elements
from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- the same four numbers in four shapes: equality looks at dimensions and bounds too
call pgmb.reg('cte.array_same_elements_different_shape', '{perf,planning,oltp}', $q$
with c(flat, square, shifted, one_row) as (
    select array[1, 2, 3, 4], array[[1, 2], [3, 4]], '[0:3]={1,2,3,4}'::integer[], array[[1, 2, 3, 4]])
select flat = square, flat = shifted, flat = one_row, square = one_row,
       flat < square, flat < shifted,
       array(select unnest(square)) = flat, array(select unnest(shifted)) = flat,
       flat @> square and square @> flat as contain_each_other
from c$q$);

call pgmb.reg('cte.array_shape_comparison_from_table', '{perf,planning}', $q$
with c as (select arr10 as flat, array[arr10[1:5], arr10[6:10]] as two_rows
           from g_intarr where id between :id and :id + 999)
select count(*) as n, count(*) filter (where flat = two_rows) as equal,
       count(*) filter (where flat < two_rows) as flat_sorts_first,
       count(*) filter (where flat @> two_rows and two_rows @> flat) as same_element_sets,
       count(*) filter (where array(select unnest(two_rows)) = flat) as equal_after_flattening
from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- ordering and grouping see the shapes as different values
call pgmb.reg('cte.array_shape_group_by', '{perf,planning}', $q$
with c as (select arr10_lowcard[1:4] as a from g_intarr where id between :id and :id + 499),
     shapes as (select a from c union all select array[a[1:2], a[3:4]] from c)
select count(*) as arrays, count(distinct a) as distinct_values,
       count(distinct array(select unnest(a))) as distinct_after_flattening
from shapes$q$,
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- element types: integer[] against bigint[] and smallint[]
------------------------------------------------------------------------------
-- bigint column = ANY (integer[]): a cross-type operator, the index is used
call pgmb.reg('cte.array_int_keys_on_bigint_column_implicit', '{perf,planning,consistency,oltp}', $q$
with c as (select arr10 from g_intarr where id = :id)
select count(*) from g_narrow where id = any ((select arr10 from c)::integer[])$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_cast');

call pgmb.reg('cte.array_int_keys_on_bigint_column_cast', '{perf,planning,consistency,oltp}', $q$
with c as (select arr10::bigint[] as keys from g_intarr where id = :id)
select count(*) from g_narrow where id = any ((select keys from c)::bigint[])$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_cast');

-- the cast on the column side instead: no index
call pgmb.reg('cte.array_int_keys_column_cast_to_int', '{perf,planning,consistency,olap}', $q$
with c as (select arr10 from g_intarr where id = :id)
select count(*) from g_narrow where id::integer = any ((select arr10 from c)::integer[])$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_cast');

-- integer column = ANY (bigint[]) built by array_agg over a bigint column
call pgmb.reg('cte.array_bigint_keys_on_int_column', '{perf,planning,oltp}', $q$
with k as (select array_agg(id) as ids from g_parent where id between :id and :id + 9)
select count(*) from g_intarr where id = any ((select ids from k)::bigint[])$q$,
    setup => '\set id random(1, :n_g_parent)');

-- converting every element: integer[] to bigint[] and back
call pgmb.reg('cte.array_cast_elements_1000_rows', '{perf,planning}', $q$
with c as (select arr100::bigint[] as wide from g_intarr where id between :id and :id + 999),
     d as (select wide::integer[] as narrow from c)
select count(*), sum(narrow[1]), sum(cardinality(narrow)) from d$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- whole arrays of different element types compare only after a cast
call pgmb.reg('cte.array_int_vs_bigint_compared_after_cast', '{perf,planning,oltp}', $q$
with c(i, b) as (select array[1, 2, 3], array[1, 2, 3]::bigint[])
select i::bigint[] = b, i = b::integer[], pg_typeof(i || b[1]::integer), pg_typeof(i::bigint[] || b) from c$q$);

call pgmb.reg('cte.err_array_int_equals_bigint_array', '{errors}',
    $q$with c(i, b) as (select array[1, 2, 3], array[1, 2, 3]::bigint[]) select i = b from c$q$, expect_error => '42883');
call pgmb.reg('cte.err_array_int_overlaps_bigint_array', '{errors}',
    $q$with c(i, b) as (select array[1, 2, 3], array[1, 2, 3]::bigint[]) select i && b from c$q$, expect_error => '42883');

-- smallint[]: which overload is chosen, and what type comes back
call pgmb.reg('cte.array_smallint_overload_resolution', '{perf,planning,oltp}', $q$
with c(s, i) as (select array[1, 2, 3]::smallint[], array[1, 2, 3])
select pg_typeof(array_append(s, 4)) as append_int, pg_typeof(array_append(s, 4::smallint)) as append_smallint,
       pg_typeof(s || i) as concat_mixed, pg_typeof(array_cat(s, i)) as cat_mixed,
       array_position(s, 2) as position_int_arg, pg_typeof((select sum(x) from unnest(s) x)) as sum_smallint,
       pg_typeof((select sum(x) from unnest(i) x)) as sum_int, s::integer[] = i as equal_after_cast
from c$q$);

call pgmb.reg('cte.array_smallint_vs_int_from_table', '{perf,planning}', $q$
with c as (select arr10_lowcard::smallint[] as s, arr10_lowcard as i from g_intarr where id between :id and :id + 999)
select count(*) filter (where s::integer[] = i) as equal_after_cast, sum(cardinality(s || i)) as concatenated,
       sum(array_position(s, 5)) as positions, sum(pg_column_size(s)) as smallint_bytes, sum(pg_column_size(i)) as int_bytes
from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.err_array_smallint_contains_int_array', '{errors}',
    $q$with c(s, i) as (select array[1, 2, 3]::smallint[], array[1, 2, 3]) select s @> i from c$q$, expect_error => '42883');

------------------------------------------------------------------------------
-- how the array type is decided in VALUES, UNION, CASE and COALESCE
------------------------------------------------------------------------------
call pgmb.reg('cte.array_typing_values', '{perf,planning,oltp}', $q$
with c(a) as (values (array[1, 2]), (array[3::bigint]), (null), ('{4,5}'))
select pg_typeof(a), a from c$q$);

call pgmb.reg('cte.array_typing_union', '{perf,planning,oltp}', $q$
with c(a) as (select array[1::smallint] union all select array[2] union all select '{3}' union all select null)
select pg_typeof(a), a from c$q$);

call pgmb.reg('cte.array_typing_case_coalesce', '{perf,planning,oltp}', $q$
with c(a, b, d) as (
    select case when :v > 50 then array[1, 2] else '{}' end,
           coalesce(null::integer[], '{7}'),
           coalesce(null, array[1::bigint], array[2]))
select pg_typeof(a), a, pg_typeof(b), b, pg_typeof(d), d from c$q$,
    setup => '\set v random(0, 99)');

call pgmb.reg('cte.array_typing_from_table', '{perf,planning}', $q$
with c as (select case when cardinality(arr_var) = 0 then null else arr_var end as a,
                  coalesce(arr_nulls, '{}') as b
           from g_intarr where id between :id and :id + 999),
     u(x) as (select a from c union all select b from c union all select array[]::integer[])
select count(*), count(x), sum(cardinality(coalesce(x, '{}'))) from u$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.err_array_typing_values_text_element', '{errors}',
    $q$with c(a) as (values (array[1, 2]), ('{x}')) select * from c$q$, expect_error => '22P02');
call pgmb.reg('cte.err_array_typing_union_text_array', '{errors}',
    $q$with c(a) as (select array[1, 2] union all select array['x']) select * from c$q$, expect_error => '42846');
call pgmb.reg('cte.err_array_typing_case_scalar_and_array', '{errors}',
    $q$with c(a) as (select case when true then array[1] else 2 end) select * from c$q$, expect_error => '42804');

------------------------------------------------------------------------------
-- array_agg as the source of a CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.array_agg_source', '{perf,planning}', $q$
with c as (select array_agg(id order by id) as ids from g_intarr where id between :id and :id + 999)
select cardinality(ids), ids[1], ids[cardinality(ids)] from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- aggregated keys used to look the rows up again
call pgmb.reg('cte.array_agg_source_as_any_keys', '{perf,planning}', $q$
with c as (select array_agg(id) as ids from g_intarr where arr1 = array[:v])
select count(*), sum(cardinality(arr5)) from g_intarr where id = any ((select ids from c)::integer[])$q$,
    setup => '\set v random(0, 99)');

call pgmb.reg('cte.array_agg_source_per_group', '{perf,planning,olap}', $q$
with c as (select arr1[1] as k, array_agg(id) as ids from g_intarr group by arr1[1])
select count(*) as groups, sum(cardinality(ids)) as members, max(cardinality(ids)) as biggest from c$q$);

call pgmb.reg('cte.array_agg_source_two_readers', '{perf,planning}', $q$
with c as (select array_agg(arr5[1] order by id) as firsts from g_intarr where id between :id and :id + 999)
select (select cardinality(firsts) from c) as n, (select max(x) from c, unnest(firsts) x) as mx$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- DISTINCT and ORDER BY inside the aggregate, against sorting outside it
call pgmb.reg('cte.array_agg_distinct_ordered', '{perf,planning,consistency}', $q$
with c as (select array_agg(distinct v order by v) as vals
           from g_intarr, unnest(arr10_lowcard) v where id between :id and :id + 999)
select vals from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_distinct');

call pgmb.reg('cte.array_agg_distinct_then_array_sort', '{perf,planning,consistency}', $q$
with c as (select array_sort(array_agg(distinct v)) as vals
           from g_intarr, unnest(arr10_lowcard) v where id between :id and :id + 999)
select vals from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_distinct');

call pgmb.reg('cte.array_agg_over_distinct_subquery', '{perf,planning,consistency}', $q$
with d as (select distinct v from g_intarr, unnest(arr10_lowcard) v where id between :id and :id + 999),
     c as (select array_agg(v order by v) as vals from d)
select vals from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_distinct');

call pgmb.reg('cte.array_agg_distinct_ordered_per_group', '{perf,planning,olap}', $q$
with c as (select arr1[1] as k, array_agg(distinct v order by v) as vals
           from g_intarr, unnest(arr10_lowcard) v group by arr1[1])
select count(*), sum(cardinality(vals)), min(vals) from c$q$);

call pgmb.reg('cte.array_agg_distinct_ordered_high_cardinality', '{perf,planning,olap}', $q$
with c as (select array_agg(distinct v order by v) as vals from g_intarr, unnest(arr10) v)
select cardinality(vals), vals[1], vals[cardinality(vals)] from c$q$);

------------------------------------------------------------------------------
-- unnest and aggregate again; WITH ORDINALITY keeps the element order
------------------------------------------------------------------------------
-- without ordinality the original order is not guaranteed, so compare sorted
call pgmb.reg('cte.array_unnest_reaggregate_sorted', '{perf,planning,consistency}', $q$
with c as (select id, arr10 from g_intarr where id between :id and :id + 499),
     e as (select id, v from c, unnest(arr10) v),
     r as (select id, array_agg(v order by v) as arr from e group by id)
select count(*) from r join c using (id) where r.arr = array_sort(c.arr10)$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_roundtrip');

call pgmb.reg('cte.array_unnest_ordinality_reaggregate_exact', '{perf,planning,consistency}', $q$
with c as (select id, arr10 from g_intarr where id between :id and :id + 499),
     e as (select id, v, ord from c, unnest(arr10) with ordinality as u(v, ord)),
     r as (select id, array_agg(v order by ord) as arr from e group by id)
select count(*) from r join c using (id) where r.arr = c.arr10$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_roundtrip');

call pgmb.reg('cte.array_unnest_ordinality_reversed', '{perf,planning,consistency}', $q$
with c as (select id, arr10 from g_intarr where id between :id and :id + 499),
     e as (select id, v, ord from c, unnest(arr10) with ordinality as u(v, ord)),
     r as (select id, array_agg(v order by ord desc) as arr from e group by id)
select count(*) from r join c using (id) where r.arr = array_reverse(c.arr10)$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_roundtrip');

call pgmb.reg('cte.array_roundtrip_row_count_baseline', '{perf,planning,consistency}', $q$
with c as (select id, arr10 from g_intarr where id between :id and :id + 499)
select count(*) from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_roundtrip');

-- filter the elements, keep their order, build the array again
call pgmb.reg('cte.array_unnest_filter_reaggregate', '{perf,planning}', $q$
with e as (select id, v, ord from g_intarr, unnest(arr100) with ordinality as u(v, ord)
           where id between :id and :id + 99),
     r as (select id, array_agg(v order by ord) filter (where v % 2 = 0) as evens from e group by id)
select count(*), sum(cardinality(evens)) from r$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- position of the largest element, through ordinality
call pgmb.reg('cte.array_ordinality_position_of_max', '{perf,planning}', $q$
with e as (select id, v, ord from g_intarr, unnest(arr10) with ordinality as u(v, ord)
           where id between :id and :id + 499),
     top as (select distinct on (id) id, ord from e order by id, v desc, ord)
select ord, count(*) from top group by ord order by ord$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- two arrays of one row unnested side by side, in step
call pgmb.reg('cte.array_ordinality_two_arrays_zipped', '{perf,planning}', $q$
with c as (select id, arr10, arr10_sorted from g_intarr where id between :id and :id + 499),
     z as (select id, a, b, ord from c, unnest(arr10, arr10_sorted) with ordinality as u(a, b, ord))
select count(*), count(*) filter (where a = b) as already_in_place from z$q$,
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- very large arrays (TOAST)
------------------------------------------------------------------------------
call pgmb.reg('cte.array_toast_one_row_one_reader', '{perf,planning,oltp}', $q$
with c as (select a from g_array_big where id = :id)
select cardinality(a), a[1], a[2000] from c$q$,
    setup => '\set id random(1, :n_g_array_big)');

call pgmb.reg('cte.array_toast_one_row_materialized_three_readers', '{perf,planning,oltp}', $q$
with c as materialized (select a from g_array_big where id = :id)
select (select cardinality(a) from c), (select a[1000] from c), (select max(x) from c, unnest(a) x)$q$,
    setup => '\set id random(1, :n_g_array_big)');

-- the CTE stores the TOAST pointer; nothing is fetched until an element is needed
call pgmb.reg('cte.array_toast_materialized_not_detoasted', '{perf,planning}', $q$
with c as materialized (select id, a from g_array_big)
select count(*) from c$q$);

call pgmb.reg('cte.array_toast_materialized_all_detoasted', '{perf,planning,olap}', $q$
with c as materialized (select id, a from g_array_big)
select count(*), sum(cardinality(a)), sum(a[2000]) from c$q$);

call pgmb.reg('cte.array_toast_inlined_all_detoasted', '{perf,planning,olap}', $q$
with c as (select id, a from g_array_big)
select count(*), sum(cardinality(a)), sum(a[2000]) from c$q$);

-- a large array built inside the CTE: one element per row of a table
call pgmb.reg('cte.array_toast_built_by_agg', '{perf,planning,olap}', $q$
with c as materialized (select array_agg(id) as ids from g_parent)
select cardinality(ids), ids[1], ids[cardinality(ids) / 2 + 1], pg_column_size(ids) from c$q$);

call pgmb.reg('cte.array_toast_built_by_agg_two_readers', '{perf,planning,olap}', $q$
with c as (select array_agg(id) as ids from g_parent)
select (select cardinality(ids) from c), (select count(*) from c, unnest(ids) x where x % 1000 = 0)$q$);

-- concatenating big arrays row after row
call pgmb.reg('cte.array_toast_concatenate_10_rows', '{perf,planning}', $q$
with c as (select a from g_array_big where id between :id and :id + 9),
     joined as (select array_agg(x) as all_elements from c, unnest(a) x)
select cardinality(all_elements) from joined$q$,
    setup => '\set id random(1, :n_g_array_big)');

------------------------------------------------------------------------------
-- many wide integer[] columns through a CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.array_wide_materialized_all_columns_one_used', '{perf,planning,consistency}', $q$
with c as materialized (select * from g_intarr where id between :id and :id + 999)
select count(*), sum(arr1[1]) from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_wide');

call pgmb.reg('cte.array_wide_materialized_one_column', '{perf,planning,consistency}', $q$
with c as materialized (select arr1 from g_intarr where id between :id and :id + 999)
select count(*), sum(arr1[1]) from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_wide');

call pgmb.reg('cte.array_wide_inlined_all_columns_one_used', '{perf,planning,consistency}', $q$
with c as (select * from g_intarr where id between :id and :id + 999)
select count(*), sum(arr1[1]) from c$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_wide');

call pgmb.reg('cte.array_wide_materialized_all_columns_all_used', '{perf,planning}', $q$
with c as materialized (select * from g_intarr where id between :id and :id + 999)
select count(*), sum(cardinality(arr1) + cardinality(arr1_unique) + cardinality(arr5) + cardinality(arr10)
                     + cardinality(arr10_lowcard) + cardinality(arr10_skew) + cardinality(arr10_unique)
                     + cardinality(arr10_sorted) + cardinality(arr_var) + coalesce(cardinality(arr_nulls), 0)
                     + cardinality(arr100) + cardinality(arr_n)) as elements
from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_wide_returned_to_client', '{perf,planning}', $q$
with c as (select * from g_intarr where id between :id and :id + 99)
select * from c$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_wide_sorted_materialized', '{perf,planning}', $q$
with c as materialized (select * from g_intarr where id between :id and :id + 999)
select count(*) from (select * from c order by arr10 offset 0) s$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_wide_self_join', '{perf,planning}', $q$
with c as (select id, arr5, arr10, arr100 from g_intarr where id between :id and :id + 499)
select count(*), sum(cardinality(a.arr100 || b.arr100)) from c a join c b on b.id = a.id + 1$q$,
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- whole arrays as values: UNION, DISTINCT, GROUP BY
------------------------------------------------------------------------------
-- UNION removes equal arrays, not arrays with equal sets of elements:
-- every array and its reverse both survive (unless it is a palindrome)
call pgmb.reg('cte.array_union_keeps_reordered_arrays', '{perf,planning}', $q$
with a as (select arr10_lowcard as arr from g_intarr where id between :id and :id + 499),
     u as (select arr from a union select array_reverse(arr) from a)
select count(*) from u$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- sorted first, the reverse is the same value and UNION removes it
call pgmb.reg('cte.array_union_of_sorted_arrays', '{perf,planning}', $q$
with a as (select arr10_lowcard as arr from g_intarr where id between :id and :id + 499),
     u as (select array_sort(arr) as arr from a union select array_sort(array_reverse(arr)) from a)
select count(*) from u$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_union_all_baseline', '{perf,planning}', $q$
with a as (select arr10_lowcard as arr from g_intarr where id between :id and :id + 499),
     u as (select arr from a union all select array_reverse(arr) from a)
select count(*) from u$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_union_low_cardinality', '{perf,planning}', $q$
with u as (select arr1 from g_intarr where id between :id and :id + 499
           union
           select arr1 from g_intarr where id between :id + 500 and :id + 999)
select count(*) from u$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_intersect_and_except', '{perf,planning}', $q$
with a as (select arr1 from g_intarr where id between :id and :id + 499),
     b as (select arr1 from g_intarr where id between :id + 500 and :id + 999)
select (select count(*) from (select arr1 from a intersect select arr1 from b) s) as in_both,
       (select count(*) from (select arr1 from a except select arr1 from b) s) as only_first$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- DISTINCT and GROUP BY: three notions of "the same array"
call pgmb.reg('cte.array_distinct_as_is', '{perf,planning,consistency}', $q$
with c as (select arr10_lowcard[1:3] as a from g_intarr where id between :id and :id + 999),
     both_orders as (select a from c union all select array_reverse(a) from c)
select count(*) from (select distinct a from both_orders) s$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_same_as_is');

call pgmb.reg('cte.array_group_by_as_is', '{perf,planning,consistency}', $q$
with c as (select arr10_lowcard[1:3] as a from g_intarr where id between :id and :id + 999),
     both_orders as (select a from c union all select array_reverse(a) from c)
select count(*) from (select a from both_orders group by a) s$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_same_as_is');

-- same elements in another order count once after sorting
call pgmb.reg('cte.array_distinct_sorted', '{perf,planning,consistency}', $q$
with c as (select arr10_lowcard[1:3] as a from g_intarr where id between :id and :id + 999),
     both_orders as (select a from c union all select array_reverse(a) from c)
select count(*) from (select distinct array_sort(a) from both_orders) s$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_same_sorted');

call pgmb.reg('cte.array_group_by_sorted', '{perf,planning,consistency}', $q$
with c as (select arr10_lowcard[1:3] as a from g_intarr where id between :id and :id + 999),
     both_orders as (select a from c union all select array_reverse(a) from c)
select count(*) from (select array_sort(a) from both_orders group by 1) s$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'cte.array_same_sorted');

-- as sets: duplicates inside the array are dropped as well
call pgmb.reg('cte.array_distinct_as_sets', '{perf,planning}', $q$
with c as (select arr10_lowcard[1:3] as a from g_intarr where id between :id and :id + 999),
     both_orders as (select a from c union all select array_reverse(a) from c)
select count(*) from (select distinct array(select distinct x from unnest(a) x order by x) from both_orders) s$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_three_notions_side_by_side', '{perf,planning}', $q$
with c as (select arr10_lowcard[1:3] as a from g_intarr where id between :id and :id + 999),
     both_orders as (select a from c union all select array_reverse(a) from c)
select count(*) as arrays, count(distinct a) as as_is, count(distinct array_sort(a)) as sorted,
       count(distinct array(select distinct x from unnest(a) x order by x)) as as_sets
from both_orders$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('cte.array_group_by_whole_array_with_counts', '{perf,planning,olap}', $q$
with c as (select arr10_lowcard[1:2] as a from g_intarr)
select a, count(*) as n from c group by a order by n desc, a limit 10$q$);
