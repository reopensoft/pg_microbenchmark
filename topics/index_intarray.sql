-- Topic: index (part 2) - GIN and GiST indexes with intarray's operator classes,
-- mostly behind CTEs. Registered only with -v intarray=1.
-- Index variants are partial indexes "WHERE id <> -K" that hold every row; a
-- query names its variant by repeating that predicate (data/indexes.sql):
--   arr1           v01 GiST gist__int_ops numranges 1
--   arr10_sorted   v02-v04 GiST gist__int_ops numranges 10/100/252, v05 GIN
--   arr10_lowcard  v06 GIN, v07 GiST gist__int_ops, v08 GiST gist__intbig_ops
--   arr10_unique   v09 GIN, v10 GiST gist__int_ops, v11 GiST gist__intbig_ops
--   arr100         v12-v16 GiST gist__intbig_ops siglen 1/16/32/128/2024, v17 GIN
-- Full indexes: arr5 GIN gin__int_ops and GIN array_ops, arr10 GiST gist__int_ops
-- and GIN array_ops. Build time and size of each index are in the DDL report.
-- Every group of variants is also a consistency group: lossy indexes must
-- return the same rows after recheck.
\if :pgmb_has_intarray

------------------------------------------------------------------------------
-- a CTE in front of the index: inlined, materialized, filter moved inside
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_cte_inlined_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with c as (select id, arr5 from g_intarr)
select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'index.intarray_cte');

call pgmb.reg('index.intarray_cte_inlined_gist', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select id, arr10 from g_intarr)
select count(*) from c where arr10 operator(pgmb_intarray.@>) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

-- the outer filter stays outside a materialized CTE: no index, full scan and store
call pgmb.reg('index.intarray_cte_materialized_filter_outside', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as materialized (select id, arr5 from g_intarr)
select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:v, :w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'index.intarray_cte');

-- the same filter written inside: the index is back
call pgmb.reg('index.intarray_cte_materialized_filter_inside', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with c as materialized (select id, arr5 from g_intarr where arr5 operator(pgmb_intarray.@>) array[:v, :w])
select count(*) from c$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'index.intarray_cte');

-- two readers make the CTE materialized by default, with the same effect
call pgmb.reg('index.intarray_cte_two_readers_filter_outside', '{perf,planning,olap}', pgmb.ia($q$
with c as (select id, arr5 from g_intarr)
select (select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:v]) as with_v,
       (select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:w]) as with_w$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

call pgmb.reg('index.intarray_cte_two_readers_not_materialized', '{perf,planning,oltp}', pgmb.ia($q$
with c as not materialized (select id, arr5 from g_intarr)
select (select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:v]) as with_v,
       (select count(*) from c where arr5 operator(pgmb_intarray.@>) array[:w]) as with_w$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

------------------------------------------------------------------------------
-- gin__int_ops against the built-in array_ops (both on arr5)
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_gin_int_ops_contains_3', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@>) array[:v, :w, :x]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'index.intarray_ops_contains');
call pgmb.reg('index.intarray_gin_array_ops_contains_3', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 @> array[:v, :w, :x]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'index.intarray_ops_contains');

call pgmb.reg('index.intarray_gin_int_ops_overlap_50', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 49))$q$),
    setup => '\set v random(0, 9950)', equiv => 'index.intarray_ops_overlap');
call pgmb.reg('index.intarray_gin_array_ops_overlap_50', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr5 && array(select generate_series(:v, :v + 49))$q$,
    setup => '\set v random(0, 9950)', equiv => 'index.intarray_ops_overlap');

------------------------------------------------------------------------------
-- GiST numranges: 10, 100, 252 ranges per key on 10-element arrays. A key holds
-- at most 2 * numranges - 1 elements, so numranges = 1 exists only for the
-- single-element column arr1.
-- 252 is the largest value this build accepts (the documentation says 253).
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_gist_numranges_1_single_element_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr1 operator(pgmb_intarray.@>) array[:v] and id <> -1$q$),
    setup => '\set v random(0, 99)', equiv => 'index.intarray_numranges_1');
call pgmb.reg('index.intarray_gist_numranges_1_single_element_overlap', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr where arr1 operator(pgmb_intarray.&&) array[:v, :v + 1, :v + 2] and id <> -1$q$),
    setup => '\set v random(0, 97)');
call pgmb.reg('index.intarray_btree_single_element_equality', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr1 = array[:v]$q$,
    setup => '\set v random(0, 99)', equiv => 'index.intarray_numranges_1');
call pgmb.reg('index.intarray_gin_array_ops_single_element_contains', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr1 @> array[:v]$q$,
    setup => '\set v random(0, 99)', equiv => 'index.intarray_numranges_1');

-- what the options refuse (the transaction of the check is rolled back)
call pgmb.reg('index.err_intarray_gist_numranges_1_on_10_elements', '{errors,needs_data}',
    pgmb.ia($q$create index g_intarr_err on g_intarr using gist (arr10_sorted pgmb_intarray.gist__int_ops (numranges = 1))$q$), expect_error => '54000');
call pgmb.reg('index.err_intarray_gist_numranges_10_on_100_elements', '{errors,needs_data}',
    pgmb.ia($q$create index g_intarr_err on g_intarr using gist (arr100 pgmb_intarray.gist__int_ops (numranges = 10))$q$), expect_error => '54000');
call pgmb.reg('index.err_intarray_gist_numranges_out_of_bounds', '{errors}',
    pgmb.ia($q$create index g_intarr_err on g_intarr using gist (arr10 pgmb_intarray.gist__int_ops (numranges = 253))$q$), expect_error => '22023');
call pgmb.reg('index.err_intarray_gist_siglen_out_of_bounds', '{errors}',
    pgmb.ia($q$create index g_intarr_err on g_intarr using gist (arr100 pgmb_intarray.gist__intbig_ops (siglen = 2025))$q$), expect_error => '22023');

call pgmb.reg('index.intarray_gist_numranges_10_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@>) array[:v] and id <> -2$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_numranges_contains');
call pgmb.reg('index.intarray_gist_numranges_100_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@>) array[:v] and id <> -3$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_numranges_contains');
call pgmb.reg('index.intarray_gist_numranges_252_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@>) array[:v] and id <> -4$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_numranges_contains');
call pgmb.reg('index.intarray_gin_small_arrays_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@>) array[:v] and id <> -5$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_numranges_contains');

call pgmb.reg('index.intarray_gist_numranges_10_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.&&) array[:v, :w, :x] and id <> -2$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_numranges_overlap');
call pgmb.reg('index.intarray_gist_numranges_100_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.&&) array[:v, :w, :x] and id <> -3$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_numranges_overlap');
call pgmb.reg('index.intarray_gist_numranges_252_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.&&) array[:v, :w, :x] and id <> -4$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_numranges_overlap');
call pgmb.reg('index.intarray_gin_small_arrays_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.&&) array[:v, :w, :x] and id <> -5$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_numranges_overlap');

------------------------------------------------------------------------------
-- GiST signature length on 100-element arrays: 1, 16, 32, 128, 2024 bytes.
-- A short signature saturates: more false positives, more heap rechecks.
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_gist_siglen_1_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -12$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_siglen_contains');
call pgmb.reg('index.intarray_gist_siglen_16_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -13$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_siglen_contains');
call pgmb.reg('index.intarray_gist_siglen_32_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -14$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_siglen_contains');
call pgmb.reg('index.intarray_gist_siglen_128_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -15$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_siglen_contains');
call pgmb.reg('index.intarray_gist_siglen_2024_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -16$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_siglen_contains');
call pgmb.reg('index.intarray_gin_large_arrays_contains', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -17$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_siglen_contains');
call pgmb.reg('index.intarray_no_index_large_arrays_contains', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 99999)', equiv => 'index.intarray_siglen_contains');

-- two keys must both be present: false positives multiply for short signatures
call pgmb.reg('index.intarray_gist_siglen_1_contains_2', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v, :w] and id <> -12$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_contains2');
call pgmb.reg('index.intarray_gist_siglen_16_contains_2', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v, :w] and id <> -13$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_contains2');
call pgmb.reg('index.intarray_gist_siglen_128_contains_2', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v, :w] and id <> -15$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_contains2');
call pgmb.reg('index.intarray_gist_siglen_2024_contains_2', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v, :w] and id <> -16$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_contains2');
call pgmb.reg('index.intarray_gin_large_arrays_contains_2', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v, :w] and id <> -17$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_contains2');

call pgmb.reg('index.intarray_gist_siglen_1_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.&&) array[:v, :w] and id <> -12$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_overlap');
call pgmb.reg('index.intarray_gist_siglen_16_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.&&) array[:v, :w] and id <> -13$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_overlap');
call pgmb.reg('index.intarray_gist_siglen_2024_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.&&) array[:v, :w] and id <> -16$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_overlap');
call pgmb.reg('index.intarray_gin_large_arrays_overlap', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.&&) array[:v, :w] and id <> -17$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'index.intarray_siglen_overlap');

------------------------------------------------------------------------------
-- many duplicates (arr10_lowcard: 20 distinct values, every key is in ~40% of rows)
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_duplicates_gin_contains_4', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :w, :x, :y] and id <> -6$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)\n\\set y random(0, 19)', equiv => 'index.intarray_dup_contains');
call pgmb.reg('index.intarray_duplicates_gist_int_contains_4', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :w, :x, :y] and id <> -7$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)\n\\set y random(0, 19)', equiv => 'index.intarray_dup_contains');
call pgmb.reg('index.intarray_duplicates_gist_big_contains_4', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :w, :x, :y] and id <> -8$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)\n\\set y random(0, 19)', equiv => 'index.intarray_dup_contains');
call pgmb.reg('index.intarray_duplicates_no_index_contains_4', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :w, :x, :y]$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)\n\\set y random(0, 19)', equiv => 'index.intarray_dup_contains');

-- seven keys: very few rows, but every posting list is long
call pgmb.reg('index.intarray_duplicates_gin_contains_7', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6] and id <> -6$q$),
    setup => '\set v random(0, 13)', equiv => 'index.intarray_dup_contains7');
call pgmb.reg('index.intarray_duplicates_gist_int_contains_7', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6] and id <> -7$q$),
    setup => '\set v random(0, 13)', equiv => 'index.intarray_dup_contains7');
call pgmb.reg('index.intarray_duplicates_gist_big_contains_7', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@>) array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6] and id <> -8$q$),
    setup => '\set v random(0, 13)', equiv => 'index.intarray_dup_contains7');

------------------------------------------------------------------------------
-- strongly correlated elements (arr10_unique: ten consecutive numbers, each
-- number in exactly one row; one range describes a whole array)
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_correlated_gin_contains', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select id from g_intarr where arr10_unique operator(pgmb_intarray.@>) array[:v] and id <> -9$q$),
    setup => '\set v random(1, 10 * :n_g_intarr)', equiv => 'index.intarray_corr_contains');
call pgmb.reg('index.intarray_correlated_gist_int_contains', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select id from g_intarr where arr10_unique operator(pgmb_intarray.@>) array[:v] and id <> -10$q$),
    setup => '\set v random(1, 10 * :n_g_intarr)', equiv => 'index.intarray_corr_contains');
call pgmb.reg('index.intarray_correlated_gist_big_contains', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select id from g_intarr where arr10_unique operator(pgmb_intarray.@>) array[:v] and id <> -11$q$),
    setup => '\set v random(1, 10 * :n_g_intarr)', equiv => 'index.intarray_corr_contains');
call pgmb.reg('index.intarray_correlated_by_computed_pk', '{perf,planning,consistency,oltp}', $q$
select id from g_intarr where id = (:v - 1) / 10 + 1$q$,
    setup => '\set v random(1, 10 * :n_g_intarr)', equiv => 'index.intarray_corr_contains');

-- 100 consecutive numbers overlap ten or eleven neighbouring rows
call pgmb.reg('index.intarray_correlated_gin_overlap_100', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_unique operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 99)) and id <> -9$q$),
    setup => '\set v random(1, 10 * :n_g_intarr - 100)', equiv => 'index.intarray_corr_overlap');
call pgmb.reg('index.intarray_correlated_gist_int_overlap_100', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_unique operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 99)) and id <> -10$q$),
    setup => '\set v random(1, 10 * :n_g_intarr - 100)', equiv => 'index.intarray_corr_overlap');
call pgmb.reg('index.intarray_correlated_gist_big_overlap_100', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_unique operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 99)) and id <> -11$q$),
    setup => '\set v random(1, 10 * :n_g_intarr - 100)', equiv => 'index.intarray_corr_overlap');

------------------------------------------------------------------------------
-- which operators an operator class can index: @> && <@ @@ and =
-- GIN gin__int_ops: all five. GiST classes: no <@ (it was removed, it needed a
-- full index scan), so <@ falls back to a sequential scan there.
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_operator_contained_by_gin', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.<@) array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6, :v + 7] and id <> -6$q$),
    setup => '\set v random(0, 12)', equiv => 'index.intarray_op_contained');
call pgmb.reg('index.intarray_operator_contained_by_gist_not_indexable', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.<@) array[:v, :v + 1, :v + 2, :v + 3, :v + 4, :v + 5, :v + 6, :v + 7] and id <> -7$q$),
    setup => '\set v random(0, 12)', equiv => 'index.intarray_op_contained');
call pgmb.reg('index.intarray_operator_contained_by_builtin_gin', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr5 <@ array(select generate_series(:v, :v + 4999))$q$,
    setup => '\set v random(0, 5000)', equiv => 'index.intarray_op_contained5');
call pgmb.reg('index.intarray_operator_contained_by_extension_gin', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.<@) array(select generate_series(:v, :v + 4999))$q$),
    setup => '\set v random(0, 5000)', equiv => 'index.intarray_op_contained5');

call pgmb.reg('index.intarray_operator_query_gin', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@@) ':v|(:w&!:x)' and id <> -5$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_op_query');
call pgmb.reg('index.intarray_operator_query_gist', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@@) ':v|(:w&!:x)' and id <> -3$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_op_query');
call pgmb.reg('index.intarray_operator_query_gist_big', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@@) ':v|(:w&!:x)' and id <> -13$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_op_query100');
call pgmb.reg('index.intarray_operator_query_gin_large_arrays', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@@) ':v|(:w&!:x)' and id <> -17$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'index.intarray_op_query100');

-- equality of whole arrays: btree, the built-in GIN, and the extension's classes
call pgmb.reg('index.intarray_equality_btree', '{perf,planning,oltp}', $q$
select count(*) from g_intarr where arr1 = array[:v]$q$,
    setup => '\set v random(0, 99)');
call pgmb.reg('index.intarray_equality_gin_on_arr5', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 = (select arr5 from g_intarr where id = :id)$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_eq5');
call pgmb.reg('index.intarray_equality_no_index_on_arr5', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr5::text = (select arr5::text from g_intarr where id = :id)$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_eq5');
call pgmb.reg('index.intarray_equality_gin_int_ops', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr10_sorted = (select arr10_sorted from g_intarr where id = :id) and id <> -5$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_eq10');
call pgmb.reg('index.intarray_equality_gist_int_ops', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr10_sorted = (select arr10_sorted from g_intarr where id = :id) and id <> -3$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_eq10');
call pgmb.reg('index.intarray_equality_gist_big_large_arrays', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr100 = (select arr100 from g_intarr where id = :id) and id <> -13$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_eq100');
call pgmb.reg('index.intarray_equality_gin_large_arrays', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr100 = (select arr100 from g_intarr where id = :id) and id <> -17$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_eq100');

------------------------------------------------------------------------------
-- bitmap scans and recheck
------------------------------------------------------------------------------
-- exact bitmap: GIN returns exact matches, the heap is only fetched
call pgmb.reg('index.intarray_bitmap_exact_gin', '{perf,olap}', pgmb.ia($q$
begin;
set local work_mem = '64MB';
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.&&) array[:v, :w] and id <> -6;
commit;$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)');

-- lossy bitmap: too little work_mem to remember rows, so whole pages are
-- flagged and every row on them is rechecked against the predicate
call pgmb.reg('index.intarray_bitmap_lossy_gin', '{perf,olap}', pgmb.ia($q$
begin;
set local work_mem = '64kB';
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.&&) array[:v, :w] and id <> -6;
commit;$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)');

-- GiST signatures are lossy by nature: recheck happens at any work_mem
call pgmb.reg('index.intarray_bitmap_recheck_gist_big', '{perf,olap}', pgmb.ia($q$
begin;
set local work_mem = '64MB';
set local enable_indexscan = off;
select count(*) from g_intarr where arr100 operator(pgmb_intarray.@>) array[:v] and id <> -13;
commit;$q$),
    setup => '\set v random(0, 99999)');

call pgmb.reg('index.intarray_bitmap_and_two_indexes', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 199))
  and arr10 operator(pgmb_intarray.&&) array(select generate_series(:w, :w + 199))$q$),
    setup => E'\\set v random(0, 9800)\n\\set w random(0, 9800)');

call pgmb.reg('index.intarray_bitmap_or_two_indexes', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@>) array[:v] or arr10 operator(pgmb_intarray.@>) array[:w]$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

------------------------------------------------------------------------------
-- CTEs with several indexable predicates, joins, the same table several times
------------------------------------------------------------------------------
call pgmb.reg('index.intarray_cte_two_indexable_predicates', '{perf,planning,consistency}', pgmb.ia($q$
with c as (select id, arr5, arr10 from g_intarr)
select count(*) from c
where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 199))
  and arr10 operator(pgmb_intarray.&&) array(select generate_series(:w, :w + 199))$q$),
    setup => E'\\set v random(0, 9800)\n\\set w random(0, 9800)', equiv => 'index.intarray_two_preds');

call pgmb.reg('index.intarray_cte_two_indexable_predicates_builtin', '{perf,planning,consistency}', $q$
with c as (select id, arr5, arr10 from g_intarr)
select count(*) from c
where arr5 && array(select generate_series(:v, :v + 199))
  and arr10 && array(select generate_series(:w, :w + 199))$q$,
    setup => E'\\set v random(0, 9800)\n\\set w random(0, 9800)', equiv => 'index.intarray_two_preds');

-- one predicate inside the CTE, one outside
call pgmb.reg('index.intarray_cte_predicate_inside_and_outside', '{perf,planning,consistency}', pgmb.ia($q$
with c as (select id, arr5, arr10 from g_intarr
           where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 199)))
select count(*) from c where arr10 operator(pgmb_intarray.&&) array(select generate_series(:w, :w + 199))$q$),
    setup => E'\\set v random(0, 9800)\n\\set w random(0, 9800)', equiv => 'index.intarray_two_preds');

-- an array predicate, a primary key range and a scalar expression together
call pgmb.reg('index.intarray_cte_array_and_pk_range', '{perf,planning,oltp}', pgmb.ia($q$
with c as (select id, arr5, arr1 from g_intarr)
select count(*) from c
where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 999))
  and id between :id and :id + 999 and arr1[1] < 50$q$),
    setup => E'\\set v random(0, 9000)\n\\set id random(1, :n_g_intarr)');

-- @@ in the CTE, an extra join condition outside
call pgmb.reg('index.intarray_cte_query_int_then_join', '{perf,planning,consistency}', pgmb.ia($q$
with hits as (select id from g_intarr where arr5 operator(pgmb_intarray.@@) ':v|:w|:x')
select count(*) from hits join g_narrow n on n.id = hits.id where n.k_100 < 50$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'index.intarray_join');

call pgmb.reg('index.intarray_cte_query_int_then_join_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with hits as materialized (select id from g_intarr where arr5 operator(pgmb_intarray.@@) ':v|:w|:x')
select count(*) from hits join g_narrow n on n.id = hits.id where n.k_100 < 50$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'index.intarray_join');

-- the join condition itself is the indexable operator
call pgmb.reg('index.intarray_cte_join_on_overlap', '{perf,planning}', pgmb.ia($q$
with probe as (select id, arr5 from g_intarr where id between :id and :id + 19)
select count(*) from probe p join g_intarr i on i.arr5 operator(pgmb_intarray.&&) p.arr5 and i.id <> p.id$q$),
    setup => '\set id random(1, :n_g_intarr)');

call pgmb.reg('index.intarray_cte_join_on_overlap_gist', '{perf,planning}', pgmb.ia($q$
with probe as (select id, arr10 from g_intarr where id between :id and :id + 19)
select count(*) from probe p join g_intarr i on i.arr10 operator(pgmb_intarray.&&) p.arr10 and i.id <> p.id$q$),
    setup => '\set id random(1, :n_g_intarr)');

-- three CTEs over the same table, each through a different index
call pgmb.reg('index.intarray_cte_same_table_three_indexes', '{perf,planning}', pgmb.ia($q$
with a as (select id from g_intarr where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 199))),
     b as (select id from g_intarr where arr10 operator(pgmb_intarray.&&) array(select generate_series(:w, :w + 199))),
     c as (select id from g_intarr where arr10_sorted operator(pgmb_intarray.&&) array(select generate_series(:x, :x + 1999)) and id <> -5)
select (select count(*) from a join b using (id)) as a_and_b,
       (select count(*) from a join c using (id)) as a_and_c,
       (select count(*) from (select id from a union select id from b union select id from c) u) as any_of_three$q$),
    setup => E'\\set v random(0, 9800)\n\\set w random(0, 9800)\n\\set x random(0, 98000)');

-- the same CTE (same index) read three times: inlined, three index scans
call pgmb.reg('index.intarray_cte_same_index_three_readers_inlined', '{perf,planning,consistency}', pgmb.ia($q$
with hits as not materialized (select id, arr5 from g_intarr where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 199)))
select (select count(*) from hits), (select min(id) from hits), (select max(arr5[1]) from hits)$q$),
    setup => '\set v random(0, 9800)', equiv => 'index.intarray_three_readers');

call pgmb.reg('index.intarray_cte_same_index_three_readers_materialized', '{perf,planning,consistency}', pgmb.ia($q$
with hits as (select id, arr5 from g_intarr where arr5 operator(pgmb_intarray.&&) array(select generate_series(:v, :v + 199)))
select (select count(*) from hits), (select min(id) from hits), (select max(arr5[1]) from hits)$q$),
    setup => '\set v random(0, 9800)', equiv => 'index.intarray_three_readers');

------------------------------------------------------------------------------
-- expression and partial indexes over transformed arrays
------------------------------------------------------------------------------
-- btree on sort(arr5): finds an array whatever the order of its elements
call pgmb.reg('index.intarray_expression_sorted_btree', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with c as (select id, pgmb_intarray.sort(arr5) as s from g_intarr)
select count(*) from c
where s = (select pgmb_intarray.sort(array_reverse(arr5)) from g_intarr where id = :id)$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_expr_sorted');

-- the expression hidden behind a materialized CTE
call pgmb.reg('index.intarray_expression_sorted_materialized', '{perf,planning,consistency,olap}', pgmb.ia($q$
with c as materialized (select id, pgmb_intarray.sort(arr5) as s from g_intarr)
select count(*) from c
where s = (select pgmb_intarray.sort(array_reverse(arr5)) from g_intarr where id = :id)$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_expr_sorted');

-- a slightly different expression does not match the index
call pgmb.reg('index.intarray_expression_sorted_other_expression', '{perf,planning,consistency,olap}', $q$
with c as (select id, array_sort(arr5) as s from g_intarr)
select count(*) from c
where s = (select array_sort(array_reverse(arr5)) from g_intarr where id = :id)$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'index.intarray_expr_sorted');

-- GIN on (arr5 || arr10): a value found in either column with one index
call pgmb.reg('index.intarray_expression_concat_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with c as (select id, arr5 || arr10 as both_arrays from g_intarr)
select count(*) from c where both_arrays operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'index.intarray_expr_concat');

call pgmb.reg('index.intarray_expression_concat_as_two_indexes', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@>) array[:v] or arr10 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'index.intarray_expr_concat');

-- partial index (every tenth row): usable when the CTE carries its predicate
call pgmb.reg('index.intarray_partial_predicate_in_cte', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with tenth as (select id, arr10_skew from g_intarr where id % 10 = 0)
select count(*) from tenth where arr10_skew operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(100, 9999)', equiv => 'index.intarray_partial');

call pgmb.reg('index.intarray_partial_predicate_in_materialized_cte', '{perf,planning,consistency,olap}', pgmb.ia($q$
with tenth as materialized (select id, arr10_skew from g_intarr where id % 10 = 0)
select count(*) from tenth where arr10_skew operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(100, 9999)', equiv => 'index.intarray_partial');

-- a predicate the planner cannot prove from the index's: no partial index
call pgmb.reg('index.intarray_partial_predicate_not_implied', '{perf,planning,consistency,olap}', pgmb.ia($q$
with tenth as (select id, arr10_skew from g_intarr where id % 20 in (0, 10))
select count(*) from tenth where arr10_skew operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(100, 9999)', equiv => 'index.intarray_partial');
\endif
