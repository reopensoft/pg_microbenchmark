-- Topic: array (part 3) - the intarray extension's operators against the
-- built-in array operators: results, indexes, name resolution, edge cases.
-- Registered only with -v intarray=1 (see data/tables.sql). The extension is in
-- schema pgmb_intarray, off the search_path; operators are written as
-- OPERATOR(pgmb_intarray.@>). Indexes on g_intarr:
--   arr5    GIN array_ops (built-in operators) and GIN gin__int_ops (extension)
--   arr10   GIN array_ops and GiST gist__int_ops
--   arr100  GiST gist__intbig_ops as partial index "id <> -13" (see data/indexes.sql)
--   arr_n   GIN array_ops only; arr10_lowcard, arr10_skew: none
\if :pgmb_has_intarray

------------------------------------------------------------------------------
-- @> : built-in and extension operator, each with the index that serves it
------------------------------------------------------------------------------
call pgmb.reg('array.intarray_contains_builtin_gin', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 @> array[:v]$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_contains5');

call pgmb.reg('array.intarray_contains_extension_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_contains5');

-- the built-in operator named with its schema: same as the bare @> here
call pgmb.reg('array.intarray_contains_explicit_pg_catalog', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 operator(pg_catalog.@>) array[:v]$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_contains5');

call pgmb.reg('array.intarray_contains_builtin_gin_arr10', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr10 @> array[:v]$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_contains10');

call pgmb.reg('array.intarray_contains_extension_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_contains10');

-- 100 elements: signature GiST (lossy) against a sequential scan
call pgmb.reg('array.intarray_contains_builtin_seqscan_arr100', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr100 @> array[:v]$q$,
    setup => '\set v random(0, 99999)', equiv => 'array.intarray_contains100');

call pgmb.reg('array.intarray_contains_extension_gist_big', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -13$q$),
    setup => '\set v random(0, 99999)', equiv => 'array.intarray_contains100');

-- no index on either side: the cost of the operator function itself
call pgmb.reg('array.intarray_contains_builtin_no_index', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr10_lowcard @> array[:v, :w]$q$,
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)', equiv => 'array.intarray_contains_lc');

call pgmb.reg('array.intarray_contains_extension_no_index', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :w]$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)', equiv => 'array.intarray_contains_lc');

------------------------------------------------------------------------------
-- &&
------------------------------------------------------------------------------
call pgmb.reg('array.intarray_overlap_builtin_gin', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 && array[:v, :w, :x]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.intarray_overlap5');

call pgmb.reg('array.intarray_overlap_extension_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.&&) array[:v, :w, :x]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.intarray_overlap5');

call pgmb.reg('array.intarray_overlap_builtin_gin_arr10', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr10 && array[:v, :w, :x]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.intarray_overlap10');

call pgmb.reg('array.intarray_overlap_extension_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10 operator(pgmb_intarray.&&) array[:v, :w, :x]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.intarray_overlap10');

call pgmb.reg('array.intarray_overlap_builtin_no_index', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr10_skew && array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.intarray_overlap_sk');

call pgmb.reg('array.intarray_overlap_extension_no_index', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_skew operator(pgmb_intarray.&&) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.intarray_overlap_sk');

-- overlap between two columns of the same row
call pgmb.reg('array.intarray_overlap_two_columns_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr5 && arr10$q$, equiv => 'array.intarray_overlap_cols');

call pgmb.reg('array.intarray_overlap_two_columns_extension', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.&&) arr10$q$), equiv => 'array.intarray_overlap_cols');

------------------------------------------------------------------------------
-- <@
------------------------------------------------------------------------------
-- contained in half of the value domain: about 3% of the rows
call pgmb.reg('array.intarray_contained_by_builtin_gin', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr5 <@ array(select generate_series(:v, :v + 4999))$q$,
    setup => '\set v random(0, 5000)', equiv => 'array.intarray_contained5');

call pgmb.reg('array.intarray_contained_by_extension_gin', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.<@) array(select generate_series(:v, :v + 4999))$q$),
    setup => '\set v random(0, 5000)', equiv => 'array.intarray_contained5');

call pgmb.reg('array.intarray_contained_by_builtin_no_index', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr10_lowcard <@ array[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, :v]$q$,
    setup => '\set v random(15, 19)', equiv => 'array.intarray_contained_lc');

call pgmb.reg('array.intarray_contained_by_extension_no_index', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.<@) array[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, :v]$q$),
    setup => '\set v random(15, 19)', equiv => 'array.intarray_contained_lc');

-- the extension's query language: (v AND w) OR x in one index condition
call pgmb.reg('array.intarray_query_int_extension_gin', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@) (:v::text || '&' || :w::text || '|' || :x::text)::pgmb_intarray.query_int$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.intarray_query');

call pgmb.reg('array.intarray_query_int_as_builtin_operators', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr5 @> array[:v, :w] or arr5 @> array[:x]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.intarray_query');

------------------------------------------------------------------------------
-- name resolution: which @> is meant
-- With the extension's schema on the search_path, integer[] @> integer[] is an
-- exact match for the extension's operator and wins over the built-in
-- anyarray @> anyarray. Index operator classes follow the operator, not the name.
------------------------------------------------------------------------------
-- arr5 has an index for either operator: the plan switches index
call pgmb.reg('array.intarray_resolution_on_path_other_index', '{perf,oltp}', pgmb.ia($q$
begin;
set local search_path = pgmb_data, pgmb, pgmb_intarray, public;
select count(*) from g_intarr where arr5 @> array[:v];
commit;$q$),
    setup => '\set v random(0, 9999)');

-- arr_n has only the built-in GIN: the same text now scans the whole table
call pgmb.reg('array.intarray_resolution_on_path_index_lost', '{perf,olap}', pgmb.ia($q$
begin;
set local search_path = pgmb_data, pgmb, pgmb_intarray, public;
select count(*) from g_intarr where arr_n @> array[:v];
commit;$q$),
    setup => '\set v random(0, :n_g_intarr_distinct - 1)');

call pgmb.reg('array.intarray_resolution_off_path_index_kept', '{perf,oltp}', $q$
begin;
set local search_path = pgmb_data, pgmb, public;
select count(*) from g_intarr where arr_n @> array[:v];
commit;$q$,
    setup => '\set v random(0, :n_g_intarr_distinct - 1)');

-- naming pg_catalog brings the built-in operator and its index back
call pgmb.reg('array.intarray_resolution_on_path_explicit_pg_catalog', '{perf,oltp}', pgmb.ia($q$
begin;
set local search_path = pgmb_data, pgmb, pgmb_intarray, public;
select count(*) from g_intarr where arr_n operator(pg_catalog.@>) array[:v];
commit;$q$),
    setup => '\set v random(0, :n_g_intarr_distinct - 1)');

-- the position of the schema in the search_path does not matter: first ...
call pgmb.reg('array.intarray_resolution_on_path_schema_first', '{perf,olap}', pgmb.ia($q$
begin;
set local search_path = pgmb_intarray, pgmb_data, pgmb, public;
select count(*) from g_intarr where arr_n @> array[:v];
commit;$q$),
    setup => '\set v random(0, :n_g_intarr_distinct - 1)');

-- bigint[] has no extension operator: resolution falls back to the built-in one
call pgmb.reg('array.intarray_resolution_on_path_bigint_array', '{perf,olap}', pgmb.ia($q$
begin;
set local search_path = pgmb_data, pgmb, pgmb_intarray, public;
select count(*) from g_intarr where arr5::bigint[] @> array[:v::bigint];
commit;$q$),
    setup => '\set v random(0, 9999)');

-- an untyped literal on the right takes the type of the left side: extension again
call pgmb.reg('array.intarray_resolution_on_path_untyped_literal', '{perf,olap}', pgmb.ia($q$
begin;
set local search_path = pgmb_data, pgmb, pgmb_intarray, public;
select count(*) from g_intarr where arr_n @> '{:v}';
commit;$q$),
    setup => '\set v random(0, :n_g_intarr_distinct - 1)');

-- the same resolution inside one statement, so that results can be compared
call pgmb.reg('array.intarray_resolution_on_path_same_result', '{perf,planning,consistency}', $q$
select ia_on_path('select count(*) from g_intarr where arr5 @> array[' || :v || ']')$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_contains5');

-- smallint[] @> smallint[]: the built-in operator fits through polymorphism, the
-- extension's through an implicit cast, and neither is preferred
call pgmb.reg('array.err_intarray_resolution_smallint_ambiguous', '{errors}',
    $q$select ia_on_path('select count(*) from g_intarr where arr10_lowcard::smallint[] @> array[1]::smallint[]')$q$, expect_error => '42725');
call pgmb.reg('array.intarray_resolution_off_path_smallint_array', '{perf,planning,olap}', $q$
select count(*) from g_intarr where arr10_lowcard::smallint[] @> array[:v]::smallint[]$q$,
    setup => '\set v random(0, 19)');
call pgmb.reg('array.err_intarray_explicit_operator_bigint_array', '{errors}',
    pgmb.ia($q$select array[1::bigint] operator(pgmb_intarray.@>) array[1::bigint]$q$), expect_error => '42883');

------------------------------------------------------------------------------
-- NULL array against NULL element
------------------------------------------------------------------------------
-- a NULL array gives NULL from either operator (both are strict)
call pgmb.reg('array.intarray_null_array', '{perf,planning,oltp}', pgmb.ia($q$
select (null::integer[] @> array[1]) is null as builtin_left, (array[1] @> null::integer[]) is null as builtin_right,
       (null::integer[] operator(pgmb_intarray.@>) array[1]) is null as extension_left,
       (array[1] operator(pgmb_intarray.&&) null::integer[]) is null as extension_right$q$));

-- a NULL element: the built-in operators ignore it, the extension refuses the array
call pgmb.reg('array.intarray_null_element_builtin', '{perf,planning,oltp}', $q$
select array[1, null] @> array[1] as contains_value, array[1, null] @> array[null]::integer[] as contains_null,
       array[1, null] && array[null, 2] as overlap_by_null, array[null]::integer[] <@ array[1, null] as null_contained$q$);

call pgmb.reg('array.err_intarray_null_element_contains', '{errors}',
    pgmb.ia($q$select array[1, null] operator(pgmb_intarray.@>) array[1]$q$), expect_error => '22004');
call pgmb.reg('array.err_intarray_null_element_on_right', '{errors}',
    pgmb.ia($q$select array[1, 2] operator(pgmb_intarray.&&) array[null]::integer[]$q$), expect_error => '22004');
call pgmb.reg('array.err_intarray_null_element_sort', '{errors}',
    pgmb.ia($q$select pgmb_intarray.sort(array[1, null, 0])$q$), expect_error => '22004');
call pgmb.reg('array.err_intarray_null_element_in_table', '{errors}',
    pgmb.ia($q$select count(*) from g_intarr where arr_nulls operator(pgmb_intarray.@>) array[1]$q$), expect_error => '22004');

-- NULL elements removed first: both operators agree again
call pgmb.reg('array.intarray_null_elements_builtin_on_table', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr_nulls @> array[:v]$q$,
    setup => '\set v random(0, 999)', equiv => 'array.intarray_nulls');

call pgmb.reg('array.intarray_null_elements_removed_for_extension', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where array_remove(arr_nulls, null) operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 999)', equiv => 'array.intarray_nulls');

------------------------------------------------------------------------------
-- empty arrays on either side
------------------------------------------------------------------------------
call pgmb.reg('array.intarray_empty_arrays_literals', '{perf,planning,oltp}', pgmb.ia($q$
with e(x) as (select '{}'::integer[])
select x @> x as b_contains, array[1] @> x as b_contains_empty, x @> array[1] as b_empty_contains,
       x && x as b_overlap, x <@ array[1] as b_contained,
       x operator(pgmb_intarray.@>) x as e_contains, array[1] operator(pgmb_intarray.@>) x as e_contains_empty,
       x operator(pgmb_intarray.@>) array[1] as e_empty_contains,
       x operator(pgmb_intarray.&&) x as e_overlap, x operator(pgmb_intarray.<@) array[1] as e_contained,
       pgmb_intarray.sort(x) as sorted, pgmb_intarray.uniq(x) as deduped, pgmb_intarray.icount(x) as counted
from e$q$));

call pgmb.reg('array.intarray_empty_arrays_builtin_on_table', '{perf,planning,consistency,olap}', $q$
select count(*) filter (where arr_var @> '{}') as contain_empty, count(*) filter (where arr_var <@ '{}') as contained_in_empty,
       count(*) filter (where arr_var && '{}') as overlap_empty, count(*) filter (where '{}' @> arr_var) as empty_contains
from g_intarr$q$, equiv => 'array.intarray_empty');

call pgmb.reg('array.intarray_empty_arrays_extension_on_table', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) filter (where arr_var operator(pgmb_intarray.@>) '{}') as contain_empty,
       count(*) filter (where arr_var operator(pgmb_intarray.<@) '{}') as contained_in_empty,
       count(*) filter (where arr_var operator(pgmb_intarray.&&) '{}') as overlap_empty,
       count(*) filter (where '{}' operator(pgmb_intarray.@>) arr_var) as empty_contains
from g_intarr$q$), equiv => 'array.intarray_empty');

------------------------------------------------------------------------------
-- repeated elements
------------------------------------------------------------------------------
-- containment is about sets: how often a value repeats does not matter
call pgmb.reg('array.intarray_duplicates_literals', '{perf,planning,oltp}', pgmb.ia($q$
select array[1, 2] @> array[1, 1, 1] as b_contains_repeated, array[1, 1, 2] <@ array[2, 1] as b_contained_repeated,
       array[1, 2] operator(pgmb_intarray.@>) array[1, 1, 1] as e_contains_repeated,
       array[1, 1, 2] operator(pgmb_intarray.<@) array[2, 1] as e_contained_repeated,
       pgmb_intarray.uniq(array[1, 1, 2, 1]) as uniq_unsorted, pgmb_intarray.uniq(pgmb_intarray.sort(array[1, 1, 2, 1])) as uniq_sorted,
       pgmb_intarray.icount(array[1, 1, 2, 1]) as count_with_repeats,
       array[1, 1, 2] operator(pgmb_intarray.&) array[1, 1] as intersection,
       array[1, 1] operator(pgmb_intarray.|) array[1, 2] as union_,
       array[1, 1, 2, 3] operator(pgmb_intarray.-) array[1] as difference$q$));

call pgmb.reg('array.intarray_duplicates_builtin_on_table', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr10_lowcard @> array[:v, :v, :v, :w, :w]$q$,
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)', equiv => 'array.intarray_dups');

call pgmb.reg('array.intarray_duplicates_extension_on_table', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :v, :v, :w, :w]$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)', equiv => 'array.intarray_dups');

call pgmb.reg('array.intarray_duplicates_counted', '{perf,planning,olap}', pgmb.ia($q$
select sum(pgmb_intarray.icount(arr10_lowcard)) as elements,
       sum(pgmb_intarray.icount(pgmb_intarray.uniq(pgmb_intarray.sort(arr10_lowcard)))) as distinct_elements,
       sum(pgmb_intarray.icount(pgmb_intarray.uniq(arr10_lowcard))) as after_uniq_without_sort
from g_intarr$q$));

call pgmb.reg('array.intarray_duplicates_set_operators', '{perf,planning}', pgmb.ia($q$
select sum(pgmb_intarray.icount(arr10_lowcard operator(pgmb_intarray.&) arr10_lowcard)) as self_intersection,
       sum(pgmb_intarray.icount(arr10_lowcard operator(pgmb_intarray.|) arr10_lowcard)) as self_union,
       sum(pgmb_intarray.icount(arr10_lowcard operator(pgmb_intarray.-) array[:v])) as without_one_value
from g_intarr where id between :id and :id + 999$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 19)');

------------------------------------------------------------------------------
-- negative values and the limits of integer
------------------------------------------------------------------------------
call pgmb.reg('array.intarray_negative_values_literals', '{perf,planning,oltp}', pgmb.ia($q$
select pgmb_intarray.sort(array[3, -1, 0, -5]) as sorted, pgmb_intarray.sort(array[3, -1, 0, -5], 'desc') as sorted_desc,
       array[-1, 2] operator(pgmb_intarray.@>) array[-1] as contains_negative,
       array[-1, -2] operator(pgmb_intarray.&&) array[-2, 5] as overlap_negative,
       array[-3, -2] operator(pgmb_intarray.<@) array[-1, -2, -3] as contained_negative,
       pgmb_intarray.uniq(pgmb_intarray.sort(array[-1, -1, 1, 1])) as uniq_mixed_signs,
       pgmb_intarray.idx(array[5, -7, 9], -7) as position_of_negative$q$));

call pgmb.reg('array.intarray_negative_values_builtin_on_table', '{perf,planning,consistency}', $q$
select count(*) as n, count(*) filter (where array[arr5[1] - 5000, arr5[2] - 5000, -arr5[3], arr5[4]] @> array[:v - 5000]) as found,
       sum((array_sort(array[arr5[1] - 5000, arr5[2] - 5000, -arr5[3], arr5[4]]))[1]) as smallest
from g_intarr where id between :id and :id + 999$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 9999)', equiv => 'array.intarray_negative');

call pgmb.reg('array.intarray_negative_values_extension_on_table', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) as n, count(*) filter (where array[arr5[1] - 5000, arr5[2] - 5000, -arr5[3], arr5[4]] operator(pgmb_intarray.@>) array[:v - 5000]) as found,
       sum((pgmb_intarray.sort(array[arr5[1] - 5000, arr5[2] - 5000, -arr5[3], arr5[4]]))[1]) as smallest
from g_intarr where id between :id and :id + 999$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 9999)', equiv => 'array.intarray_negative');

-- a comparator written as a - b would overflow here
call pgmb.reg('array.intarray_integer_limits_literals', '{perf,planning,oltp}', pgmb.ia($q$
select pgmb_intarray.sort(array[2147483647, -2147483648, 0, -1, 1]) as sorted,
       pgmb_intarray.sort(array[2147483647, -2147483648, 0], 'desc') as sorted_desc,
       pgmb_intarray.uniq(pgmb_intarray.sort(array[2147483647, 2147483647, -2147483648, -2147483648])) as deduped,
       array[2147483647, -2147483648] operator(pgmb_intarray.@>) array[-2147483648] as contains_min,
       array[2147483647] operator(pgmb_intarray.&&) array[-2147483648, 2147483647] as overlap_max,
       array[-2147483648] operator(pgmb_intarray.<@) array[2147483647, 0, -2147483648] as contained_min,
       pgmb_intarray.idx(array[0, 2147483647, -2147483648], -2147483648) as position_of_min,
       array[-2147483648, 2147483647] @> array[2147483647] as builtin_contains_max$q$));

call pgmb.reg('array.intarray_integer_limits_sorted_on_table', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) as n,
       count(*) filter (where (pgmb_intarray.sort(arr5 || array[2147483647, -2147483648]))[1] = -2147483648
                          and (pgmb_intarray.sort(arr5 || array[2147483647, -2147483648]))[7] = 2147483647) as limits_at_the_ends
from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_limits');

call pgmb.reg('array.intarray_integer_limits_builtin_sorted_on_table', '{perf,planning,consistency}', $q$
select count(*) as n,
       count(*) filter (where (array_sort(arr5 || array[2147483647, -2147483648]))[1] = -2147483648
                          and (array_sort(arr5 || array[2147483647, -2147483648]))[7] = 2147483647) as limits_at_the_ends
from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_limits');

------------------------------------------------------------------------------
-- more than one dimension, lower bounds other than 1
------------------------------------------------------------------------------
-- both families of operators look at the elements only
call pgmb.reg('array.intarray_dimensions_literals', '{perf,planning,oltp}', pgmb.ia($q$
with m(sq, flat) as (select array[[1, 2], [3, 4]], array[4, 3, 2, 1])
select sq @> array[3] as b_contains, sq && array[[4]] as b_overlap, sq <@ flat as b_contained, sq = flat as b_equal,
       sq operator(pgmb_intarray.@>) array[3] as e_contains, sq operator(pgmb_intarray.&&) array[[4]] as e_overlap,
       sq operator(pgmb_intarray.<@) flat as e_contained,
       pgmb_intarray.sort(array[[4, 3], [2, 1]]) as sort_keeps_shape, pgmb_intarray.icount(sq) as counted,
       array_dims(sq operator(pgmb_intarray.|) flat) as union_is_flat
from m$q$));

call pgmb.reg('array.intarray_dimensions_builtin_on_table', '{perf,planning,consistency}', $q$
select count(*) from g_intarr
where id between :id and :id + 999 and array[arr10[1:5], arr10[6:10]] && array[[:v, :v + 1], [:v + 2, :v + 3]]$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 9996)', equiv => 'array.intarray_dims');

call pgmb.reg('array.intarray_dimensions_extension_on_table', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr
where id between :id and :id + 999 and array[arr10[1:5], arr10[6:10]] operator(pgmb_intarray.&&) array[[:v, :v + 1], [:v + 2, :v + 3]]$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 9996)', equiv => 'array.intarray_dims');

call pgmb.reg('array.intarray_dimensions_flat_baseline', '{perf,planning,consistency}', $q$
select count(*) from g_intarr
where id between :id and :id + 999 and arr10 && array[:v, :v + 1, :v + 2, :v + 3]$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 9996)', equiv => 'array.intarray_dims');

-- lower bound 0: operators agree; sort() keeps the bounds, idx() counts from 1
call pgmb.reg('array.intarray_lower_bound_literals', '{perf,planning,oltp}', pgmb.ia($q$
with z(a) as (select '[0:2]={3,1,2}'::integer[])
select a @> array[1] as b_contains, a operator(pgmb_intarray.@>) array[1] as e_contains,
       a operator(pgmb_intarray.&&) array[2, 9] as e_overlap, a operator(pgmb_intarray.<@) array[1, 2, 3] as e_contained,
       pgmb_intarray.sort(a) as sorted, array_dims(pgmb_intarray.sort(a)) as sorted_dims,
       pgmb_intarray.idx(a, 1) as idx_is_one_based, a[1] as subscript_is_bound_based,
       array_dims(pgmb_intarray.uniq(pgmb_intarray.sort(a))) as uniq_dims,
       pgmb_intarray.sort(a) = array[1, 2, 3] as equals_plain_array
from z$q$));

call pgmb.reg('array.intarray_lower_bound_builtin_on_table', '{perf,planning,consistency}', $q$
select count(*) from g_intarr
where id between :id and :id + 999 and ('[0:4]=' || arr5::text)::integer[] && array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6, :v + 7, :v + 8, :v + 9]$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 9990)', equiv => 'array.intarray_bounds');

call pgmb.reg('array.intarray_lower_bound_extension_on_table', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr
where id between :id and :id + 999 and ('[0:4]=' || arr5::text)::integer[] operator(pgmb_intarray.&&) array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6, :v + 7, :v + 8, :v + 9]$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 9990)', equiv => 'array.intarray_bounds');

------------------------------------------------------------------------------
-- equal arrays against arrays that contain each other
------------------------------------------------------------------------------
-- each 3-element array against its reverse: equal only for palindromes, mutual
-- containment always; after sort() equal always
call pgmb.reg('array.intarray_equality_vs_mutual_containment_builtin', '{perf,planning,consistency}', $q$
with p as (select arr10_lowcard[1:3] as a, array_reverse(arr10_lowcard[1:3]) as b from g_intarr where id between :id and :id + 999)
select count(*) as pairs, count(*) filter (where a = b) as equal,
       count(*) filter (where a @> b and b @> a) as contain_each_other,
       count(*) filter (where array_sort(a) = array_sort(b)) as equal_when_sorted
from p$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_equality');

call pgmb.reg('array.intarray_equality_vs_mutual_containment_extension', '{perf,planning,consistency}', pgmb.ia($q$
with p as (select arr10_lowcard[1:3] as a, array_reverse(arr10_lowcard[1:3]) as b from g_intarr where id between :id and :id + 999)
select count(*) as pairs, count(*) filter (where a = b) as equal,
       count(*) filter (where a operator(pgmb_intarray.@>) b and b operator(pgmb_intarray.@>) a) as contain_each_other,
       count(*) filter (where pgmb_intarray.sort(a) = pgmb_intarray.sort(b)) as equal_when_sorted
from p$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_equality');

-- different lengths: {1,1,2} and {1,2} contain each other and are never equal,
-- not even sorted; only uniq(sort()) makes them the same value
call pgmb.reg('array.intarray_equality_after_uniq', '{perf,planning}', pgmb.ia($q$
with p as (select arr10_lowcard as a, arr10_lowcard || arr10_lowcard[1:3] as b from g_intarr where id between :id and :id + 999)
select count(*) as pairs, count(*) filter (where a = b) as equal,
       count(*) filter (where a operator(pgmb_intarray.@>) b and b operator(pgmb_intarray.@>) a) as contain_each_other,
       count(*) filter (where pgmb_intarray.sort(a) = pgmb_intarray.sort(b)) as equal_when_sorted,
       count(*) filter (where pgmb_intarray.uniq(pgmb_intarray.sort(a)) = pgmb_intarray.uniq(pgmb_intarray.sort(b))) as equal_as_sets
from p$q$),
    setup => '\set id random(1, :n_g_intarr)');

-- finding the rows with the same set of elements as a given row
call pgmb.reg('array.intarray_same_set_as_row_extension_gin', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr a join g_intarr b
  on b.arr5 operator(pgmb_intarray.@>) a.arr5 and b.arr5 operator(pgmb_intarray.<@) a.arr5
where a.id = :id$q$),
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- selectivity estimates: the plan around the predicate shows what was expected
------------------------------------------------------------------------------
-- a value present in most rows, and a rare one, under each operator; the join
-- strategy chosen for g_narrow follows the estimated number of rows
-- (the extension's estimators use the same element statistics as the built-in ones)
call pgmb.reg('array.intarray_estimate_hot_value_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew @> array[:v]$q$,
    setup => '\set v random(0, 2)', equiv => 'array.intarray_est_hot');

call pgmb.reg('array.intarray_estimate_hot_value_extension', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 2)', equiv => 'array.intarray_est_hot');

call pgmb.reg('array.intarray_estimate_rare_value_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew @> array[:v]$q$,
    setup => '\set v random(5000, 9999)', equiv => 'array.intarray_est_rare');

call pgmb.reg('array.intarray_estimate_rare_value_extension', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(5000, 9999)', equiv => 'array.intarray_est_rare');

call pgmb.reg('array.intarray_estimate_overlap_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_lowcard && array[:v]$q$,
    setup => '\set v random(0, 19)', equiv => 'array.intarray_est_overlap');

call pgmb.reg('array.intarray_estimate_overlap_extension', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_lowcard operator(pgmb_intarray.&&) array[:v]$q$),
    setup => '\set v random(0, 19)', equiv => 'array.intarray_est_overlap');

call pgmb.reg('array.intarray_estimate_query_int', '{perf,planning,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id
where i.arr10_skew operator(pgmb_intarray.@@) (:v::text || '&' || :w::text)::pgmb_intarray.query_int$q$),
    setup => E'\\set v random(0, 2)\n\\set w random(0, 2)');

-- the value comes from a subquery: no constant to estimate with
call pgmb.reg('array.intarray_estimate_unknown_value_extension', '{perf,planning,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id
where i.arr10_skew operator(pgmb_intarray.@>) (select array[arr10_skew[1]] from g_intarr where id = :id)$q$),
    setup => '\set id random(1, :n_g_intarr)');
\endif
