-- Topic: array (part 2) - integer[] columns of g_intarr.
-- One column per array length and value distribution, so the same query can be
-- repeated over 1, 5, 10 and 100 elements, over unique, low-cardinality and
-- skewed values, with GIN, with btree and without an index.
-- arr_n follows the run variables arr_len / arr_distinct
-- (:n_g_intarr_len, :n_g_intarr_distinct).

------------------------------------------------------------------------------
-- one element per array: four ways to ask the same question
------------------------------------------------------------------------------
call pgmb.reg('array.int_one_eq_btree', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr1 = array[:v]$q$,
    setup => '\set v random(0, 99)', equiv => 'array.int_one');

call pgmb.reg('array.int_one_contains_gin', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr1 @> array[:v]$q$,
    setup => '\set v random(0, 99)', equiv => 'array.int_one');

-- neither form can use an index condition: the predicate is a filter over a
-- full scan (of the table, or of the arr1 btree as an index-only scan)
call pgmb.reg('array.int_one_any_filter', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where :v = any (arr1)$q$,
    setup => '\set v random(0, 99)', equiv => 'array.int_one');

call pgmb.reg('array.int_one_subscript_filter', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr1[1] = :v$q$,
    setup => '\set v random(0, 99)', equiv => 'array.int_one');

call pgmb.reg('array.int_one_range_btree', '{perf,planning}', $q$
select count(*) from g_intarr where arr1 >= array[:v] and arr1 < array[:v + 5]$q$,
    setup => '\set v random(0, 95)');

-- unique single-element arrays
call pgmb.reg('array.int_unique_eq_btree', '{perf,planning,consistency,oltp}', $q$
select id from g_intarr where arr1_unique = array[:u]::int[]$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set u :id * 2654435761 % 2147483647', equiv => 'array.int_unique');

call pgmb.reg('array.int_unique_any_seqscan', '{perf,planning,consistency}', $q$
select id from g_intarr where :u = any (arr1_unique)$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set u :id * 2654435761 % 2147483647', equiv => 'array.int_unique');

call pgmb.reg('array.int_unique_by_pk', '{perf,planning,consistency,oltp}', $q$
select id from g_intarr where id = :id and arr1_unique[1] = :u$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set u :id * 2654435761 % 2147483647', equiv => 'array.int_unique');

call pgmb.reg('array.int_unique_in_list_btree', '{perf,planning,oltp}', $q$
select id from g_intarr where arr1_unique in (array[:u]::int[], array[:u2]::int[], array[:u3]::int[])$q$,
    setup => E'\\set id random(1, :n_g_intarr - 2)\n\\set u :id * 2654435761 % 2147483647\n\\set u2 (:id + 1) * 2654435761 % 2147483647\n\\set u3 (:id + 2) * 2654435761 % 2147483647');

------------------------------------------------------------------------------
-- containment and overlap: 5, 10, 100 and arr_len elements
------------------------------------------------------------------------------
call pgmb.reg('array.int_arr5_contains_gin', '{perf,planning,consistency,oltp}', $q$
select id from g_intarr where arr5 @> array[:v]$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.int_arr5');

call pgmb.reg('array.int_arr5_any_seqscan', '{perf,planning,consistency}', $q$
select id from g_intarr where :v = any (arr5)$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.int_arr5');

call pgmb.reg('array.int_arr5_overlap_10_gin', '{perf,planning}', $q$
select count(*) from g_intarr
where arr5 && array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6, :v + 7, :v + 8, :v + 9]$q$,
    setup => '\set v random(0, 9990)');

call pgmb.reg('array.int_arr10_contains_gin', '{perf,planning,oltp}', $q$
select id from g_intarr where arr10 @> array[:v]$q$,
    setup => '\set v random(0, 9999)');

-- two keys: the bitmaps are intersected, almost nothing matches
call pgmb.reg('array.int_arr10_contains_2_gin', '{perf,planning}', $q$
select count(*) from g_intarr where arr10 @> array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

-- contains its own array: always at least the row itself
call pgmb.reg('array.int_arr10_contains_own_row_gin', '{perf,planning,oltp}', $q$
select count(*) from g_intarr where arr10 @> (select arr10 from g_intarr where id = :id)$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- rows sharing at least one number with a given row
call pgmb.reg('array.int_arr10_similar_rows_gin', '{perf,planning}', $q$
select count(*) from g_intarr a join g_intarr b on b.arr10 && a.arr10 where a.id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_arr10_similar_rows_ranked', '{perf,planning}', $q$
select b.id, (select count(*) from unnest(b.arr10) v where v = any (a.arr10)) as shared
from g_intarr a join g_intarr b on b.arr10 && a.arr10 and b.id <> a.id
where a.id = :id order by shared desc, b.id limit 10$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- no index: 20 distinct values, most rows qualify
call pgmb.reg('array.int_lowcard_contains_seqscan', '{perf,planning,olap}', $q$
select count(*) from g_intarr where arr10_lowcard @> array[:v, :w]$q$,
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)');

call pgmb.reg('array.int_lowcard_contained_by_seqscan', '{perf,planning,olap}', $q$
select count(*) from g_intarr where arr10_lowcard <@ array[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, :v]$q$,
    setup => '\set v random(15, 19)');

-- skewed values: the same query on a hot and on a rare value
call pgmb.reg('array.int_skew_contains_hot_value', '{perf,planning,olap}', $q$
select count(*) from g_intarr where arr10_skew @> array[:v]$q$,
    setup => '\set v random(0, 2)');

call pgmb.reg('array.int_skew_contains_rare_value', '{perf,planning,olap}', $q$
select count(*) from g_intarr where arr10_skew @> array[:v]$q$,
    setup => '\set v random(5000, 9999)');

call pgmb.reg('array.int_arr100_contains_seqscan', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr100 @> array[:v]$q$,
    setup => '\set v random(0, 99999)', equiv => 'array.int_arr100');

call pgmb.reg('array.int_arr100_any_seqscan', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where :v = any (arr100)$q$,
    setup => '\set v random(0, 99999)', equiv => 'array.int_arr100');

-- a number that occurs exactly once in the table: three ways to find its row
call pgmb.reg('array.int_unique10_contains_seqscan', '{perf,planning,consistency,olap}', $q$
select id from g_intarr where arr10_unique @> array[:v]$q$,
    setup => '\set v random(1, 10 * :n_g_intarr)', equiv => 'array.int_unique10');

call pgmb.reg('array.int_unique10_bounds_seqscan', '{perf,planning,consistency,olap}', $q$
select id from g_intarr where arr10_unique[1] <= :v and arr10_unique[10] >= :v$q$,
    setup => '\set v random(1, 10 * :n_g_intarr)', equiv => 'array.int_unique10');

call pgmb.reg('array.int_unique10_computed_pk', '{perf,planning,consistency,oltp}', $q$
select id from g_intarr where id = (:v - 1) / 10 + 1 and :v = any (arr10_unique)$q$,
    setup => '\set v random(1, 10 * :n_g_intarr)', equiv => 'array.int_unique10');

------------------------------------------------------------------------------
-- parameterized column arr_n (arr_len elements over arr_distinct values)
------------------------------------------------------------------------------
call pgmb.reg('array.int_n_contains_gin', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr_n @> array[:v]$q$,
    setup => '\set v random(0, :n_g_intarr_distinct - 1)', equiv => 'array.int_n');

call pgmb.reg('array.int_n_any_seqscan', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where :v = any (arr_n)$q$,
    setup => '\set v random(0, :n_g_intarr_distinct - 1)', equiv => 'array.int_n');

call pgmb.reg('array.int_n_overlap_3_gin', '{perf,planning}', $q$
select count(*) from g_intarr where arr_n && array[:v, :w, :x]$q$,
    setup => E'\\set v random(0, :n_g_intarr_distinct - 1)\n\\set w random(0, :n_g_intarr_distinct - 1)\n\\set x random(0, :n_g_intarr_distinct - 1)');

call pgmb.reg('array.int_n_contains_3_gin', '{perf,planning}', $q$
select count(*) from g_intarr where arr_n @> array[:v, :w, :x]$q$,
    setup => E'\\set v random(0, :n_g_intarr_distinct - 1)\n\\set w random(0, :n_g_intarr_distinct - 1)\n\\set x random(0, :n_g_intarr_distinct - 1)');

call pgmb.reg('array.int_n_fetch_by_pk', '{perf,planning,oltp}', $q$
select arr_n from g_intarr where id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_n_subscript_by_pk', '{perf,planning,oltp}', $q$
select arr_n[:k], arr_n[:n_g_intarr_len], cardinality(arr_n) from g_intarr where id = :id$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, greatest(1, :n_g_intarr_len))');

call pgmb.reg('array.int_n_unnest_sum_1000_rows', '{perf,planning}', $q$
select count(*), sum(v) from g_intarr, unnest(arr_n) v where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_n_top_values', '{perf,planning,olap}', $q$
select v, count(*) as n from g_intarr, unnest(arr_n) v group by v order by n desc, v limit 10$q$);

call pgmb.reg('array.int_n_sort_each_1000_rows', '{perf,planning}', $q$
select sum((array_sort(arr_n))[1]) from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_n_distinct_per_row', '{perf,planning,olap}', $q$
select avg((select count(distinct v) from unnest(arr_n) v)) from g_intarr$q$);

------------------------------------------------------------------------------
-- one row by primary key: fetching and taking arrays apart
------------------------------------------------------------------------------
call pgmb.reg('array.int_pk_fetch_all_columns', '{perf,planning,oltp}', $q$
select * from g_intarr where id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_pk_fetch_arr1', '{perf,planning,oltp}', $q$
select arr1 from g_intarr where id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_pk_fetch_arr100', '{perf,planning,oltp}', $q$
select arr100 from g_intarr where id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_pk_subscript_arr100', '{perf,planning,oltp}', $q$
select arr100[:k] from g_intarr where id = :id$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, 100)');

call pgmb.reg('array.int_pk_slice_arr100', '{perf,planning,oltp}', $q$
select arr100[:k : :k + 9] from g_intarr where id = :id$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, 91)');

call pgmb.reg('array.int_pk_scalar_functions', '{perf,planning,oltp}', $q$
select cardinality(arr_var), array_length(arr10, 1), array_position(arr10, arr10[5]),
       array_positions(arr10_lowcard, arr10_lowcard[1]), arr5 || arr10, array_remove(arr10_lowcard, :v),
       array_replace(arr10_lowcard, :v, -1), array_to_string(arr5, ','), arr10 = arr10_sorted, arr5 < arr10
from g_intarr where id = :id$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set v random(0, 19)');

call pgmb.reg('array.int_pk_sort_reverse', '{perf,planning,oltp}', $q$
select array_sort(arr10), array_reverse(arr10_sorted), array_sort(arr100) from g_intarr where id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_pk_distinct_elements', '{perf,planning,oltp}', $q$
select array(select distinct v from unnest(arr10_lowcard) v order by v) from g_intarr where id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_pk_intersection_of_two_rows', '{perf,planning,oltp}', $q$
select array(select unnest(a.arr10_lowcard) intersect select unnest(b.arr10_lowcard) order by 1)
from g_intarr a, g_intarr b where a.id = :id and b.id = :id2$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set id2 random(1, :n_g_intarr)');

call pgmb.reg('array.int_pk_aggregates_over_elements', '{perf,planning,oltp}', $q$
select (select sum(v) from unnest(arr100) v), (select max(v) from unnest(arr100) v),
       (select count(distinct v) from unnest(arr100) v)
from g_intarr where id = :id$q$,
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- unnest: the cost per element for 5, 10 and 100 elements
------------------------------------------------------------------------------
call pgmb.reg('array.int_unnest_sum_arr5_1000_rows', '{perf,planning}', $q$
select count(*), sum(v) from g_intarr, unnest(arr5) v where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_unnest_sum_arr10_1000_rows', '{perf,planning}', $q$
select count(*), sum(v) from g_intarr, unnest(arr10) v where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_unnest_sum_arr100_1000_rows', '{perf,planning}', $q$
select count(*), sum(v) from g_intarr, unnest(arr100) v where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- the same sum as a per-row subquery and in the select list
call pgmb.reg('array.int_unnest_subquery_per_row', '{perf,planning}', $q$
select sum((select sum(v) from unnest(arr100) v)) from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_unnest_in_select_list', '{perf,planning}', $q$
select count(*), sum(v) from (select unnest(arr100) as v from g_intarr where id between :id and :id + 999) s$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_unnest_two_columns_in_step', '{perf,planning}', $q$
select count(*), count(a), count(b) from g_intarr, unnest(arr5, arr10) as u(a, b) where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_unnest_with_ordinality', '{perf,planning,olap}', $q$
select ord, avg(v) as avg_value from g_intarr, unnest(arr10_sorted) with ordinality as u(v, ord) group by ord order by ord$q$);

call pgmb.reg('array.int_unnest_top_values_skewed', '{perf,planning,olap}', $q$
select v, count(*) as n from g_intarr, unnest(arr10_skew) v group by v order by n desc, v limit 10$q$);

call pgmb.reg('array.int_unnest_count_distinct_lowcard', '{perf,planning,olap}', $q$
select count(distinct v) from g_intarr, unnest(arr10_lowcard) v$q$);

call pgmb.reg('array.int_unnest_count_distinct_arr100', '{perf,planning,olap}', $q$
select count(distinct v) from g_intarr, unnest(arr100) v$q$);

-- sorting every array: built-in function against unnest + ORDER BY
call pgmb.reg('array.int_sort_each_builtin', '{perf,planning,consistency}', $q$
select id, array_sort(arr10) from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.int_sort');

call pgmb.reg('array.int_sort_each_unnest', '{perf,planning,consistency}', $q$
select id, array(select v from unnest(arr10) v order by v) from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.int_sort');

------------------------------------------------------------------------------
-- variable length and empty arrays
------------------------------------------------------------------------------
call pgmb.reg('array.int_var_length_histogram', '{perf,planning,olap}', $q$
select cardinality(arr_var) as len, count(*) from g_intarr group by len order by len$q$);

call pgmb.reg('array.int_var_empty_by_equality', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr_var = '{}'$q$, equiv => 'array.int_empty');

call pgmb.reg('array.int_var_empty_by_cardinality', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where cardinality(arr_var) = 0$q$, equiv => 'array.int_empty');

call pgmb.reg('array.int_var_empty_by_array_length', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where array_length(arr_var, 1) is null$q$, equiv => 'array.int_empty');

call pgmb.reg('array.int_var_unnest_drops_empty_rows', '{perf,planning}', $q$
select count(distinct id) as rows_with_elements, count(*) as elements
from g_intarr, unnest(arr_var) v where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_var_left_join_keeps_empty_rows', '{perf,planning}', $q$
select count(distinct id) as all_rows, count(v) as elements
from g_intarr left join lateral unnest(arr_var) v on true where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- NULL arrays and NULL elements
------------------------------------------------------------------------------
call pgmb.reg('array.int_nulls_column_is_null', '{perf,planning,olap}', $q$
select count(*) from g_intarr where arr_nulls is null$q$);

call pgmb.reg('array.int_nulls_has_null_element', '{perf,planning,olap}', $q$
select count(*) from g_intarr where array_position(arr_nulls, null) is not null$q$);

-- = ANY is three-valued: true, false, or NULL when a NULL element hides the answer
call pgmb.reg('array.int_nulls_any_three_valued', '{perf,planning,olap}', $q$
select count(*) filter (where :v = any (arr_nulls)) as is_true,
       count(*) filter (where not (:v = any (arr_nulls))) as is_false,
       count(*) filter (where (:v = any (arr_nulls)) is null) as is_unknown
from g_intarr$q$,
    setup => '\set v random(0, 999)');

call pgmb.reg('array.int_nulls_contains_ignores_nulls', '{perf,planning,olap}', $q$
select count(*) from g_intarr where arr_nulls @> array[:v]$q$,
    setup => '\set v random(0, 999)');

call pgmb.reg('array.int_nulls_remove_and_count', '{perf,planning,olap}', $q$
select sum(cardinality(arr_nulls)) as elements, sum(cardinality(array_remove(arr_nulls, null))) as not_null from g_intarr$q$);

call pgmb.reg('array.int_nulls_unnest_count', '{perf,planning,olap}', $q$
select count(*) as elements, count(v) as not_null from g_intarr, unnest(arr_nulls) v$q$);

call pgmb.reg('array.int_nulls_coalesce_to_empty', '{perf,planning,olap}', $q$
select sum(cardinality(coalesce(arr_nulls, '{}'))) from g_intarr$q$);

------------------------------------------------------------------------------
-- arrays as values: comparing, ordering, grouping, joining
------------------------------------------------------------------------------
call pgmb.reg('array.int_order_by_arr1_btree_limit', '{perf,planning,oltp}', $q$
select id, arr1 from g_intarr where arr1 >= array[:v] order by arr1 limit 20$q$,
    setup => '\set v random(0, 99)');

call pgmb.reg('array.int_order_by_arr10_top_n', '{perf,planning,olap}', $q$
select id from g_intarr order by arr10, id limit 20$q$);

call pgmb.reg('array.int_order_by_arr100_full_sort', '{perf,planning,olap}', $q$
select count(*) from (select id from g_intarr order by arr100 offset 0) s$q$);

call pgmb.reg('array.int_group_by_arr1', '{perf,planning,olap}', $q$
select arr1, count(*) from g_intarr group by arr1 order by arr1$q$);

call pgmb.reg('array.int_group_by_sorted_lowcard', '{perf,planning,olap}', $q$
select count(*) from (select array_sort(arr10_lowcard) from g_intarr group by 1) s$q$);

call pgmb.reg('array.int_distinct_arr5', '{perf,planning,olap}', $q$
select count(*) from (select distinct arr5 from g_intarr) s$q$);

call pgmb.reg('array.int_join_on_arr1_equality', '{perf,planning}', $q$
select count(*) from g_intarr a join g_intarr b on b.arr1 = a.arr1 where a.id between :id and :id + 9$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_join_on_unique_equality', '{perf,planning,oltp}', $q$
select count(*) from g_intarr a join g_intarr b on b.arr1_unique = a.arr1_unique where a.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_intarr)');

-- elements used as keys of another table
call pgmb.reg('array.int_elements_join_other_table', '{perf,planning}', $q$
select count(*), sum(n.k_100) from g_intarr a, unnest(a.arr5) v join g_narrow n on n.id = v
where a.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_elements_as_any_keys', '{perf,planning,oltp}', $q$
select count(*) from g_narrow where id = any ((select arr10::bigint[] from g_intarr where id = :id)::bigint[])$q$,
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_elements_as_any_keys_100', '{perf,planning}', $q$
select count(*) from g_narrow where id = any ((select arr100::bigint[] from g_intarr where id = :id)::bigint[])$q$,
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- writes. Every update keeps the length and the value domain of its column.
------------------------------------------------------------------------------
-- column with a GIN index: one key leaves the index, one enters
call pgmb.reg('array.int_update_element_gin', '{perf,planning,oltp}', $q$
update g_intarr set arr10[:k] = :v where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, 10)\n\\set v random(0, 9999)');

-- column without an index
call pgmb.reg('array.int_update_element_no_index', '{perf,planning,oltp}', $q$
update g_intarr set arr10_lowcard[:k] = :v where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, 10)\n\\set v random(0, 19)');

call pgmb.reg('array.int_update_element_arr100', '{perf,planning,oltp}', $q$
update g_intarr set arr100[:k] = :v where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, 100)\n\\set v random(0, 99999)');

-- same set of keys, new array value: the GIN index still has to be visited
call pgmb.reg('array.int_update_rotate_gin', '{perf,planning,oltp}', $q$
update g_intarr set arr5 = arr5[2:5] || arr5[1:1] where id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_update_rotate_no_index', '{perf,planning,oltp}', $q$
update g_intarr set arr_var = arr_var[2:] || arr_var[1:1] where id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_update_arr1_btree_and_gin', '{perf,planning,oltp}', $q$
update g_intarr set arr1 = array[(arr1[1] + 1) % 100] where id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_update_n_element', '{perf,planning,oltp}', $q$
update g_intarr set arr_n[:k] = :v where id = :id and cardinality(arr_n) >= :k$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, greatest(1, :n_g_intarr_len))\n\\set v random(0, :n_g_intarr_distinct - 1)');

call pgmb.reg('array.int_update_sort_in_place_100_rows', '{perf,planning}', $q$
update g_intarr set arr10_lowcard = array_reverse(arr10_lowcard) where id between :id and :id + 99$q$,
    kind => 'write', setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('array.int_update_returning_elements', '{perf,planning,oltp}', $q$
with u as (update g_intarr set arr10[:k] = :v where id = :id returning arr10)
select count(*), sum(e) from u, unnest(arr10) e$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_intarr)\n\\set k random(1, 10)\n\\set v random(0, 9999)');
