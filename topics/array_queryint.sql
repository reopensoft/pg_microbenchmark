-- Topic: array (part 4) - intarray's query_int and the @@ operator.
-- Registered only with -v intarray=1. A query_int is a boolean expression over
-- element values: & and, | or, ! not, parentheses. arr5 has a GIN index for it,
-- arr10 a GiST index; arr10_sorted has both as variants v05 (GIN, "id <> -5")
-- and v03 (GiST, "id <> -3"), see data/indexes.sql.
-- pgbench replaces :name inside quoted strings too, so ':v&:w' is a literal the
-- planner can see. Prepared statements need the text built from parameters.
\if :pgmb_has_intarray

------------------------------------------------------------------------------
-- the five basic shapes, GIN (arr5), each next to its built-in equivalent
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_single_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single');
call pgmb.reg('array.queryint_single_as_builtin_contains', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 @> array[:v]$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single');

call pgmb.reg('array.queryint_and_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&:w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and');
call pgmb.reg('array.queryint_and_as_builtin_contains', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 @> array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and');

call pgmb.reg('array.queryint_or_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v|:w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or');
call pgmb.reg('array.queryint_or_as_builtin_overlap', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 && array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or');

-- a bare negation matches almost every row and cannot use the index
call pgmb.reg('array.queryint_not_seqscan', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) '!:v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_not');
call pgmb.reg('array.queryint_not_as_builtin_not_contains', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where not (arr5 @> array[:v])$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_not');

call pgmb.reg('array.queryint_nested_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&(:w|:x)'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.queryint_nested');
call pgmb.reg('array.queryint_nested_as_builtin_contains_and_overlap', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 @> array[:v] and arr5 && array[:w, :x]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)', equiv => 'array.queryint_nested');

-- a negation beside a positive term: the positive term drives the index
call pgmb.reg('array.queryint_and_not_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&!:w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and_not');
call pgmb.reg('array.queryint_and_not_as_builtin', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr5 @> array[:v] and not (arr5 @> array[:w])$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and_not');

-- an OR with a negated side matches almost everything again
call pgmb.reg('array.queryint_or_not_seqscan', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v|!:w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or_not');
call pgmb.reg('array.queryint_or_not_as_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where arr5 @> array[:v] or not (arr5 @> array[:w])$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or_not');

------------------------------------------------------------------------------
-- the same shapes on GiST (arr10), and GIN against GiST on one column
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_single_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10 operator(pgmb_intarray.@@) ':v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single10');
call pgmb.reg('array.queryint_single_arr10_as_builtin', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr10 @> array[:v]$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single10');

call pgmb.reg('array.queryint_and_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10 operator(pgmb_intarray.@@) ':v&:w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and10');
call pgmb.reg('array.queryint_and_arr10_as_builtin', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr10 @> array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and10');

call pgmb.reg('array.queryint_or_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10 operator(pgmb_intarray.@@) ':v|:w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or10');
call pgmb.reg('array.queryint_or_arr10_as_builtin', '{perf,planning,consistency,oltp}', $q$
select count(*) from g_intarr where arr10 && array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or10');

call pgmb.reg('array.queryint_nested_gist', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10 operator(pgmb_intarray.@@) ':v&(:w|:x)'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)');

-- one column, one query, the index family chosen by the variant predicate
call pgmb.reg('array.queryint_or_same_column_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@@) ':v|:w|:x' and id <> -5$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'array.queryint_family_or');
call pgmb.reg('array.queryint_or_same_column_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@@) ':v|:w|:x' and id <> -3$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'array.queryint_family_or');
call pgmb.reg('array.queryint_or_same_column_no_index', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@@) ':v|:w|:x'$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)\n\\set x random(0, 99999)', equiv => 'array.queryint_family_or');

call pgmb.reg('array.queryint_and_not_same_column_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@@) ':v&!:w' and id <> -5$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'array.queryint_family_and_not');
call pgmb.reg('array.queryint_and_not_same_column_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10_sorted operator(pgmb_intarray.@@) ':v&!:w' and id <> -3$q$),
    setup => E'\\set v random(0, 99999)\n\\set w random(0, 99999)', equiv => 'array.queryint_family_and_not');

------------------------------------------------------------------------------
-- nesting depth
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_nested_6_levels', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@) '(((((:v|:w)&!:x)|:y)&!:z)|:v)&(:w|(:x&(:y|:z))|:v)'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)\n\\set y random(0, 9999)\n\\set z random(0, 9999)');

-- 200 redundant pairs of parentheses around one value
call pgmb.reg('array.queryint_parentheses_200_deep', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@) (repeat('(', 200) || :v::text || repeat(')', 200))::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single');

-- a chain nested to the right, 50 levels: v0|(v1&(v2|(v3&( ... ))))
call pgmb.reg('array.queryint_right_nested_50_levels', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@)
      ((select string_agg(g::text || case when g % 2 = 0 then '|(' else '&(' end, '' order by g)
        from generate_series(:v, :v + 49) g) || '0' || repeat(')', 50))::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 9900)');

-- parsing alone, without a table
call pgmb.reg('array.queryint_parse_only_2000_deep', '{perf,planning}', pgmb.ia($q$
select length((repeat('(', 2000) || :v::text || repeat(')', 2000))::pgmb_intarray.query_int::text)$q$),
    setup => '\set v random(0, 9999)');

------------------------------------------------------------------------------
-- the same value several times
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_repeated_value_and', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&:v&:v&:v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single');
call pgmb.reg('array.queryint_repeated_value_or', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v|:v|:v|:v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single');
-- absorption: v & (v | w) is just v
call pgmb.reg('array.queryint_repeated_value_absorbed', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&(:v|:w)'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_single');

------------------------------------------------------------------------------
-- values that occur in no array
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_absent_value_gin', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':a'$q$),
    setup => '\set a random(20000, 30000)');
call pgmb.reg('array.queryint_absent_value_gist', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr10 operator(pgmb_intarray.@@) ':a'$q$),
    setup => '\set a random(20000, 30000)');
call pgmb.reg('array.queryint_absent_value_negated', '{perf,planning,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) '!:a'$q$),
    setup => '\set a random(20000, 30000)');
-- present OR absent: the absent branch costs an index descent and adds nothing
call pgmb.reg('array.queryint_present_or_absent_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v|:a'$q$),
    setup => E'\\set v random(0, 9999)\n\\set a random(20000, 30000)', equiv => 'array.queryint_single');
call pgmb.reg('array.queryint_present_and_absent_gin', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&:a'$q$),
    setup => E'\\set v random(0, 9999)\n\\set a random(20000, 30000)');
call pgmb.reg('array.queryint_negative_value', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) '-:v|:w'$q$),
    setup => E'\\set v random(1, 9999)\n\\set w random(0, 9999)');

------------------------------------------------------------------------------
-- selective and unselective conditions (arr10_lowcard: 20 distinct values;
-- variant v06 is its GIN index)
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_unselective_single_gin', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) ':v' and id <> -6$q$),
    setup => '\set v random(0, 19)', equiv => 'array.queryint_unsel');
call pgmb.reg('array.queryint_unselective_single_no_index', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) ':v'$q$),
    setup => '\set v random(0, 19)', equiv => 'array.queryint_unsel');
call pgmb.reg('array.queryint_unselective_or_5_gin', '{perf,planning,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) ':v|:w|:x|:y|:z' and id <> -6$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)\n\\set y random(0, 19)\n\\set z random(0, 19)');
call pgmb.reg('array.queryint_selective_and_5_gin', '{perf,planning,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) ':v&:w&:x&:y&:z' and id <> -6$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)\n\\set y random(0, 19)\n\\set z random(0, 19)');
call pgmb.reg('array.queryint_very_selective_and_gin', '{perf,planning,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&:w&:x'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)');

------------------------------------------------------------------------------
-- query_int built in a CTE, shared by CTEs, joined as a table
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_built_in_cte', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with q as (select (:v::text || '|' || :w::text)::pgmb_intarray.query_int as q)
select count(*) from g_intarr, q where arr5 operator(pgmb_intarray.@@) q.q$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or');

call pgmb.reg('array.queryint_built_in_materialized_cte', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with q as materialized (select (:v::text || '|' || :w::text)::pgmb_intarray.query_int as q)
select count(*) from g_intarr, q where arr5 operator(pgmb_intarray.@@) q.q$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or');

call pgmb.reg('array.queryint_built_in_cte_as_scalar_subquery', '{perf,planning,consistency,oltp}', pgmb.ia($q$
with q as (select (:v::text || '|' || :w::text)::pgmb_intarray.query_int as q)
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) (select q from q)$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or');

-- one query_int, three CTEs applying it to different columns and indexes
call pgmb.reg('array.queryint_one_query_three_ctes', '{perf,planning}', pgmb.ia($q$
with q as (select (:v::text || '|' || :w::text || '|' || :x::text)::pgmb_intarray.query_int as q),
     in5 as (select id from g_intarr, q where arr5 operator(pgmb_intarray.@@) q.q),
     in10 as (select id from g_intarr, q where arr10 operator(pgmb_intarray.@@) q.q),
     in_skew as (select id from g_intarr, q where arr10_skew operator(pgmb_intarray.@@) q.q)
select (select count(*) from in5) as arr5_rows, (select count(*) from in10) as arr10_rows,
       (select count(*) from in_skew) as skew_rows,
       (select count(*) from in5 join in10 using (id)) as in_both$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)\n\\set x random(0, 9999)');

-- a CTE holding several named queries, joined to the table by @@
call pgmb.reg('array.queryint_join_table_with_queries', '{perf,planning}', pgmb.ia($q$
with qs(name, q) as (values ('single', ':v'::pgmb_intarray.query_int), ('and', ':v&:w'), ('or', ':v|:w'), ('and_not', ':v&!:w'))
select qs.name, count(i.id) from qs left join g_intarr i on i.arr5 operator(pgmb_intarray.@@) qs.q
group by qs.name order by qs.name$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

call pgmb.reg('array.queryint_join_table_with_20_queries', '{perf,planning}', pgmb.ia($q$
with qs as (select g as n, (g::text || '|' || (g + 5000)::text)::pgmb_intarray.query_int as q
            from generate_series(:v, :v + 19) g)
select count(*), count(distinct qs.n) from qs join g_intarr i on i.arr5 operator(pgmb_intarray.@@) qs.q$q$),
    setup => '\set v random(0, 4980)');

-- queries stored per row: every row checks its own array against its own query
call pgmb.reg('array.queryint_query_per_row', '{perf,planning}', pgmb.ia($q$
with c as (select arr10, (arr5[1]::text || '|' || arr5[2]::text)::pgmb_intarray.query_int as q
           from g_intarr where id between :id and :id + 999)
select count(*) from c where arr10 operator(pgmb_intarray.@@) q$q$),
    setup => '\set id random(1, :n_g_intarr)');

------------------------------------------------------------------------------
-- prepared statements: the query_int is a parameter the planner cannot see
-- once the generic plan takes over
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_cte_parameter_simple_protocol', '{perf,oltp}', pgmb.ia($q$
with q as (select (:v::text || '&' || :w::text)::pgmb_intarray.query_int as q)
select count(*) from g_intarr, q where arr5 operator(pgmb_intarray.@@) q.q$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', protocol => 'simple');

call pgmb.reg('array.queryint_cte_parameter_extended_protocol', '{perf,oltp}', pgmb.ia($q$
with q as (select (:v::text || '&' || :w::text)::pgmb_intarray.query_int as q)
select count(*) from g_intarr, q where arr5 operator(pgmb_intarray.@@) q.q$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', protocol => 'extended');

call pgmb.reg('array.queryint_cte_parameter_prepared', '{perf,oltp}', pgmb.ia($q$
with q as (select (:v::text || '&' || :w::text)::pgmb_intarray.query_int as q)
select count(*) from g_intarr, q where arr5 operator(pgmb_intarray.@@) q.q$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', protocol => 'prepared');

-- unselective parameter on a column without an index: only the estimate differs
call pgmb.reg('array.queryint_join_parameter_simple_protocol', '{perf,olap}', pgmb.ia($q$
with hits as (select id from g_intarr where arr10_skew operator(pgmb_intarray.@@) (:v::text || '|' || :w::text)::pgmb_intarray.query_int)
select count(*) from hits join g_narrow n on n.id = hits.id$q$),
    setup => E'\\set v random(0, 2)\n\\set w random(0, 2)', protocol => 'simple');

call pgmb.reg('array.queryint_join_parameter_prepared', '{perf,olap}', pgmb.ia($q$
with hits as (select id from g_intarr where arr10_skew operator(pgmb_intarray.@@) (:v::text || '|' || :w::text)::pgmb_intarray.query_int)
select count(*) from hits join g_narrow n on n.id = hits.id$q$),
    setup => E'\\set v random(0, 2)\n\\set w random(0, 2)', protocol => 'prepared');

------------------------------------------------------------------------------
-- what the extension's parser rejects
------------------------------------------------------------------------------
call pgmb.reg('array.err_queryint_dangling_operator', '{errors}', pgmb.ia($q$select '1&'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_unclosed_parenthesis', '{errors}', pgmb.ia($q$select '(1|2'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_unopened_parenthesis', '{errors}', pgmb.ia($q$select '1|2)'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_missing_operator', '{errors}', pgmb.ia($q$select '1 2'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_doubled_operator', '{errors}', pgmb.ia($q$select '1&&2'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_not_a_number', '{errors}', pgmb.ia($q$select 'a|1'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_empty', '{errors}', pgmb.ia($q$select ''::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_bare_negation', '{errors}', pgmb.ia($q$select '!'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_number_out_of_range', '{errors}', pgmb.ia($q$select '99999999999'::pgmb_intarray.query_int$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_in_cte', '{errors}',
    pgmb.ia($q$with q as (select '1&(2|'::pgmb_intarray.query_int as q) select count(*) from g_intarr, q where arr5 operator(pgmb_intarray.@@) q.q$q$), expect_error => '42601');
call pgmb.reg('array.err_queryint_null_element_in_array', '{errors}',
    pgmb.ia($q$select array[1, null] operator(pgmb_intarray.@@) '1'$q$), expect_error => '22004');

------------------------------------------------------------------------------
-- many conditions
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_or_200_values_gin', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@) (select string_agg(g::text, '|') from generate_series(:v, :v + 199) g)::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 9800)', equiv => 'array.queryint_or200');
call pgmb.reg('array.queryint_or_200_values_as_builtin_overlap', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where arr5 && array(select generate_series(:v, :v + 199))$q$,
    setup => '\set v random(0, 9800)', equiv => 'array.queryint_or200');
call pgmb.reg('array.queryint_or_200_values_gist', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr
where arr10 operator(pgmb_intarray.@@) (select string_agg(g::text, '|') from generate_series(:v, :v + 199) g)::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 9800)');

call pgmb.reg('array.queryint_or_2000_values_gin', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@) (select string_agg(g::text, '|') from generate_series(:v, :v + 1999) g)::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 8000)');

-- 50 groups (a|b|c|d) joined by AND
call pgmb.reg('array.queryint_and_of_50_or_groups', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr
where arr10_lowcard operator(pgmb_intarray.@@)
      (select string_agg(format('(%s|%s|%s|%s)', g % 20, (g + 5) % 20, (g + 10) % 20, (g + 15) % 20), '&')
       from generate_series(:v, :v + 49) g)::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 19)');

-- 100 groups (a&b) joined by OR
call pgmb.reg('array.queryint_or_of_100_and_groups', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@)
      (select string_agg(format('(%s&%s)', g, g + 5000), '|') from generate_series(:v, :v + 99) g)::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 4900)');

call pgmb.reg('array.queryint_and_20_values_no_match', '{perf,planning}', pgmb.ia($q$
select count(*) from g_intarr
where arr5 operator(pgmb_intarray.@@) (select string_agg(g::text, '&') from generate_series(:v, :v + 19) g)::pgmb_intarray.query_int$q$),
    setup => '\set v random(0, 9980)');

------------------------------------------------------------------------------
-- the commutator: query_int ~~ integer[]
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_commutator_gin', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where ':v&:w'::pgmb_intarray.query_int operator(pgmb_intarray.~~) arr5$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and');

call pgmb.reg('array.queryint_commutator_gist', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where ':v&:w'::pgmb_intarray.query_int operator(pgmb_intarray.~~) arr10$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and10');

call pgmb.reg('array.queryint_commutator_in_join', '{perf,planning}', pgmb.ia($q$
with qs(q) as (values (':v'::pgmb_intarray.query_int), (':w'), (':v&:w'))
select count(*) from qs join g_intarr i on qs.q operator(pgmb_intarray.~~) i.arr5$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

------------------------------------------------------------------------------
-- logically equivalent forms: nothing is simplified, every form is executed as written
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_double_negation', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) '!!:v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_single');

call pgmb.reg('array.queryint_tautology', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v|!:v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_all');
call pgmb.reg('array.queryint_all_rows_baseline', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_all');

call pgmb.reg('array.queryint_contradiction', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&!:v'$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_none');
call pgmb.reg('array.queryint_no_rows_baseline', '{perf,planning,consistency}', $q$
select count(*) from g_intarr where false$q$,
    setup => '\set v random(0, 9999)', equiv => 'array.queryint_none');

-- De Morgan: !(v|w) and !v&!w
call pgmb.reg('array.queryint_de_morgan_negated_or', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) '!(:v|:w)'$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)', equiv => 'array.queryint_de_morgan');
call pgmb.reg('array.queryint_de_morgan_and_of_negations', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) '!:v&!:w'$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)', equiv => 'array.queryint_de_morgan');
call pgmb.reg('array.queryint_de_morgan_as_builtin_not_overlap', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr where not (arr10_lowcard && array[:v, :w])$q$,
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)', equiv => 'array.queryint_de_morgan');

-- distribution: (v|w)&(v|x) and v|(w&x)
call pgmb.reg('array.queryint_distributed_form', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) '(:v|:w)&(:v|:x)' and id <> -6$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)', equiv => 'array.queryint_distribution');
call pgmb.reg('array.queryint_factored_form', '{perf,planning,consistency}', pgmb.ia($q$
select count(*) from g_intarr where arr10_lowcard operator(pgmb_intarray.@@) ':v|(:w&:x)' and id <> -6$q$),
    setup => E'\\set v random(0, 19)\n\\set w random(0, 19)\n\\set x random(0, 19)', equiv => 'array.queryint_distribution');

-- one @@ against the same condition split into two @@ joined by AND in SQL
call pgmb.reg('array.queryint_and_inside_query', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v&:w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and');
call pgmb.reg('array.queryint_and_between_two_queries', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v' and arr5 operator(pgmb_intarray.@@) ':w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_and');
call pgmb.reg('array.queryint_or_between_two_queries', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@@) ':v' or arr5 operator(pgmb_intarray.@@) ':w'$q$),
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)', equiv => 'array.queryint_or');

------------------------------------------------------------------------------
-- negation and row estimates: the join chosen for g_narrow shows the estimate
-- (arr10_skew: values 0..2 are in a large share of the rows, values above 5000
-- in almost none)
------------------------------------------------------------------------------
call pgmb.reg('array.queryint_estimate_negated_hot_value', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew operator(pgmb_intarray.@@) '!:v'$q$),
    setup => '\set v random(0, 2)', equiv => 'array.queryint_est_not_hot');
call pgmb.reg('array.queryint_estimate_negated_hot_value_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where not (i.arr10_skew @> array[:v])$q$,
    setup => '\set v random(0, 2)', equiv => 'array.queryint_est_not_hot');

call pgmb.reg('array.queryint_estimate_negated_rare_value', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew operator(pgmb_intarray.@@) '!:v'$q$),
    setup => '\set v random(5000, 9999)', equiv => 'array.queryint_est_not_rare');
call pgmb.reg('array.queryint_estimate_negated_rare_value_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where not (i.arr10_skew @> array[:v])$q$,
    setup => '\set v random(5000, 9999)', equiv => 'array.queryint_est_not_rare');

-- all three hot values negated: few rows remain
call pgmb.reg('array.queryint_estimate_negated_all_hot_values', '{perf,planning,consistency,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew operator(pgmb_intarray.@@) '!0&!1&!2&!3&!4&!5&!6&!7'$q$),
    equiv => 'array.queryint_est_not_all');
call pgmb.reg('array.queryint_estimate_negated_all_hot_values_builtin', '{perf,planning,consistency,olap}', $q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where not (i.arr10_skew && array[0, 1, 2, 3, 4, 5, 6, 7])$q$,
    equiv => 'array.queryint_est_not_all');

call pgmb.reg('array.queryint_estimate_hot_and_not_hot', '{perf,planning,olap}', pgmb.ia($q$
select count(*) from g_intarr i join g_narrow n on n.id = i.id where i.arr10_skew operator(pgmb_intarray.@@) ':v&!:w'$q$),
    setup => E'\\set v random(0, 2)\n\\set w random(3, 5)');

-- the negation inside a CTE, the join outside
call pgmb.reg('array.queryint_estimate_negation_in_cte', '{perf,planning,olap}', pgmb.ia($q$
with kept as (select id from g_intarr where arr10_skew operator(pgmb_intarray.@@) '!:v&!:w')
select count(*) from kept join g_narrow n on n.id = kept.id$q$),
    setup => E'\\set v random(0, 2)\n\\set w random(3, 5)');

call pgmb.reg('array.queryint_estimate_negation_in_materialized_cte', '{perf,planning,olap}', pgmb.ia($q$
with kept as materialized (select id from g_intarr where arr10_skew operator(pgmb_intarray.@@) '!:v&!:w')
select count(*) from kept join g_narrow n on n.id = kept.id$q$),
    setup => E'\\set v random(0, 2)\n\\set w random(3, 5)');
\endif
