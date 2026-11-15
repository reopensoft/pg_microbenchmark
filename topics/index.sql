-- Topic: indexes. Build times come from data/indexes.sql (DDL phase);
-- here: access paths over one and several columns, different operators, maintenance on write.

call pgmb.reg('index.pk_point', '{perf,planning,oltp}', $q$
select * from g_narrow where id = :id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('index.unique_point', '{perf,planning,oltp}', $q$
select * from g_narrow where k_uniq = :id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('index.range_100', '{perf,planning,oltp}', $q$
select * from g_narrow where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('index.in_list', '{perf,planning,oltp}', $q$
select * from g_narrow where id in (:id, :id + 3, :id + 17, :id + 250, :id + 4001)$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- several columns
call pgmb.reg('index.multi_both_columns', '{perf,planning,oltp}', $q$
select count(*) from g_narrow where k_100 = :a and k_10k = :b$q$,
    setup => E'\\set a random(0, 99)\n\\set b random(0, 9999)');

call pgmb.reg('index.multi_order_limit', '{perf,planning,oltp}', $q$
select id, k_10k from g_narrow where k_100 = :a order by k_10k limit 20$q$,
    setup => '\set a random(0, 99)');

call pgmb.reg('index.multi_range_second', '{perf,planning}', $q$
select count(*) from g_narrow where k_100 = :a and k_10k between :b and :b + 500$q$,
    setup => E'\\set a random(0, 99)\n\\set b random(0, 9499)');

-- leading column missing: btree skip scan (PostgreSQL 18)
call pgmb.reg('index.skip_scan', '{perf,planning}', $q$
select count(*) from g_wide where i4 = :a and i5 = :b$q$,
    setup => E'\\set a random(0, 999)\n\\set b random(0, 9999)');

call pgmb.reg('index.skip_scan_range', '{perf,planning}', $q$
select count(*) from g_wide where i3 between :c and :c + 4 and i4 = :a$q$,
    setup => E'\\set a random(0, 999)\n\\set c random(0, 95)');

-- index-only, partial, expression, pattern
call pgmb.reg('index.include_index_only', '{perf,planning,oltp}', $q$
select k_10k, k_100 from g_narrow where k_10k = :b$q$,
    setup => '\set b random(0, 9999)');

call pgmb.reg('index.partial', '{perf,planning}', $q$
select count(*) from g_narrow where k_skew = :s and k_null is not null$q$,
    setup => '\set s random(100, 999)');

call pgmb.reg('index.expression', '{perf,planning}', $q$
select count(*), max(id) from g_narrow where (k_uniq % 1000) = :m$q$,
    setup => '\set m random(0, 999)');

call pgmb.reg('index.like_prefix', '{perf,planning}', $q$
select count(*) from g_narrow where pad like :p::text || '%'$q$,
    setup => '\set p random(100, 999)');

call pgmb.reg('index.desc_nulls_last', '{perf,planning,oltp}', $q$
select id, k_null from g_narrow order by k_null desc nulls last, id limit 20$q$);

-- other access methods
call pgmb.reg('index.hash_equal', '{perf,planning,oltp}', $q$
select id, i6 from g_wide where i6 = :v$q$,
    setup => '\set v random(0, 99999)');

call pgmb.reg('index.brin_time_range', '{perf,planning}', $q$
select count(*) from g_narrow
where ts >= timestamptz '2020-01-01 00:00:00+00' + :id * interval '1 second'
  and ts <  timestamptz '2020-01-01 00:00:00+00' + (:id + 3600) * interval '1 second'$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('index.brin_correlated', '{perf,planning}', $q$
select count(*) from g_narrow where k_corr between :c and :c + 100$q$,
    setup => '\set c random(0, :n_g_narrow / 10)');

-- combining indexes
call pgmb.reg('index.bitmap_or', '{perf,planning,oltp}', $q$
select count(*) from g_narrow where k_10k = :b or k_uniq = :id$q$,
    setup => E'\\set b random(0, 9999)\n\\set id random(1, :n_g_narrow)');

call pgmb.reg('index.bitmap_and', '{perf,planning}', $q$
select count(*) from g_narrow where k_10k between :b and :b + 200 and (k_uniq % 1000) = :m$q$,
    setup => E'\\set b random(0, 9799)\n\\set m random(0, 999)');

-- no usable index
call pgmb.reg('index.seqscan_filter', '{perf,planning,olap}', $q$
select count(*) from g_narrow where k_corr % 1000 = :m$q$,
    setup => '\set m random(0, 999)');

-- index maintenance on write
call pgmb.reg('index.update_indexed_column', '{perf,planning,oltp}', $q$
update g_narrow set k_10k = :b where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_narrow)\n\\set b random(0, 9999)');

call pgmb.reg('index.update_hot', '{perf,planning,oltp}', $q$
update g_wide set t1 = t1 where id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('index.update_gin', '{perf,planning,oltp}', $q$
update g_array set tags = array['tag' || :v::text, 'tag' || (:v + 1)::text] where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_array)\n\\set v random(0, 48)');

call pgmb.reg('index.err_unique_violation', '{errors,needs_data}',
    $q$insert into g_dim (id, code, category, name) select id, code, category, name from g_dim where id = 1$q$,
    expect_error => '23505');

------------------------------------------------------------------------------
-- B-tree skip scan (PostgreSQL 18) beyond the basic case.
-- g_wide has one index on (i3, i4, i5): 100, 1000 and 10000 distinct values.
------------------------------------------------------------------------------
call pgmb.reg('index.skip_scan_two_leading_columns', '{perf,planning}', $q$
select count(*) from g_wide where i5 = :b$q$,
    setup => '\set b random(0, 9999)');

call pgmb.reg('index.skip_scan_range_on_second', '{perf,planning}', $q$
select count(*) from g_wide where i4 between :a and :a + 5$q$,
    setup => '\set a random(0, 994)');

call pgmb.reg('index.skip_scan_gap_in_middle', '{perf,planning}', $q$
select count(*) from g_wide where i3 in (:c, :c + 3, :c + 7) and i5 = :b$q$,
    setup => E'\\set c random(0, 92)\n\\set b random(0, 9999)');

call pgmb.reg('index.skip_scan_in_list_on_second', '{perf,planning}', $q$
select count(*) from g_wide where i4 in (:a, :a + 11, :a + 23)$q$,
    setup => '\set a random(0, 976)');

call pgmb.reg('index.skip_scan_with_order', '{perf,planning}', $q$
select i3, i4, i5 from g_wide where i4 = :a order by i3, i4, i5 limit 20$q$,
    setup => '\set a random(0, 999)');

-- skip scan against the alternative of reading everything; results must agree
call pgmb.reg('index.skip_scan_count', '{perf,planning,consistency}', $q$
select count(*), min(i3), max(i3) from g_wide where i4 = :a$q$,
    setup => '\set a random(0, 999)', equiv => 'index.skip_scan');

call pgmb.reg('index.skip_scan_defeated_by_expression', '{perf,planning,consistency,olap}', $q$
select count(*), min(i3), max(i3) from g_wide where i4 + 0 = :a$q$,
    setup => '\set a random(0, 999)', equiv => 'index.skip_scan');

------------------------------------------------------------------------------
-- other non-standard uses of a B-tree
------------------------------------------------------------------------------
-- backward scan
call pgmb.reg('index.btree_backward_limit', '{perf,planning,oltp}', $q$
select id, k_uniq from g_narrow where id < :id order by id desc limit 20$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('index.btree_backward_second_column', '{perf,planning,oltp}', $q$
select id, k_10k from g_narrow where k_100 = :a order by k_10k desc limit 20$q$,
    setup => '\set a random(0, 99)');

-- min/max answered from the ends of an index range
call pgmb.reg('index.btree_min_max_endpoints', '{perf,planning,oltp}', $q$
select min(k_10k), max(k_10k) from g_narrow where k_100 = :a$q$,
    setup => '\set a random(0, 99)');

call pgmb.reg('index.btree_min_max_whole_table', '{perf,planning,oltp}', $q$
select min(id), max(id), min(k_uniq), max(k_uniq) from g_narrow$q$);

-- several array conditions resolved in one index descent pattern
call pgmb.reg('index.btree_two_in_lists', '{perf,planning}', $q$
select count(*) from g_narrow
where k_100 in (:a, :a + 1, :a + 2, :a + 3, :a + 4)
  and k_10k in (:b, :b + 100, :b + 200, :b + 300, :b + 400)$q$,
    setup => E'\\set a random(0, 95)\n\\set b random(0, 9599)');

call pgmb.reg('index.btree_in_list_with_range', '{perf,planning}', $q$
select count(*) from g_narrow where k_100 in (:a, :a + 10, :a + 20) and k_10k between :b and :b + 300$q$,
    setup => E'\\set a random(0, 79)\n\\set b random(0, 9699)');

-- OR on one column, rewritten to an array condition
call pgmb.reg('index.btree_or_same_column', '{perf,planning,oltp}', $q$
select count(*) from g_narrow where k_10k = :b or k_10k = :b + 17 or k_10k = :b + 4001$q$,
    setup => '\set b random(0, 5998)');

-- row comparison as an index boundary (keyset pagination)
call pgmb.reg('index.btree_row_comparison', '{perf,planning,oltp}', $q$
select k_100, k_10k, id from g_narrow where (k_100, k_10k) > (:a, :b) order by k_100, k_10k limit 20$q$,
    setup => E'\\set a random(0, 99)\n\\set b random(0, 9999)');

-- NULL tests answered by the index
call pgmb.reg('index.btree_is_null', '{perf,planning,oltp}', $q$
select id from g_narrow where k_null is null order by id limit 20$q$);

call pgmb.reg('index.btree_nulls_first_backward', '{perf,planning,oltp}', $q$
select id, k_null from g_narrow order by k_null asc nulls first, id desc limit 20$q$);

-- index-only scans: counting, and filtering on an INCLUDE column
call pgmb.reg('index.btree_index_only_count', '{perf,planning}', $q$
select count(*) from g_narrow where k_100 = :a$q$,
    setup => '\set a random(0, 99)');

call pgmb.reg('index.btree_filter_on_include_column', '{perf,planning,oltp}', $q$
select count(*) from g_narrow where k_10k = :b and k_100 < 50$q$,
    setup => '\set b random(0, 9999)');

-- partial index usable only through predicate implication
call pgmb.reg('index.btree_partial_implied_predicate', '{perf,planning}', $q$
select count(*) from g_narrow where k_skew = :s and k_null > 500$q$,
    setup => '\set s random(100, 999)');

-- range over an expression index
call pgmb.reg('index.btree_expression_range', '{perf,planning}', $q$
select count(*) from g_narrow where (k_uniq % 1000) between :m and :m + 1$q$,
    setup => '\set m random(0, 998)');

-- comparison with a different integer type
call pgmb.reg('index.btree_cross_type', '{perf,planning,oltp}', $q$
select id, k_100 from g_narrow where id = any (array[:id, :id + 1, :id + 2]::int[]) and k_uniq > 0::smallint$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- ordered inputs from two indexes merged without sorting
call pgmb.reg('index.btree_merge_join_no_sort', '{perf,planning}', $q$
select count(*), sum(e.val) from g_narrow n join g_events e on e.id = n.id
where n.id between :id and :id + 20000 and e.id between :id and :id + 20000$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- uniqueness proven by the index removes work
call pgmb.reg('index.btree_unique_group_by_removed', '{perf,planning}', $q$
select id, k_uniq, count(*) from g_narrow where id between :id and :id + 2000 group by id, k_uniq$q$,
    setup => '\set id random(1, :n_g_narrow)');
