-- Topic: sequential reads. Whole-table scans with different row widths,
-- filters, early termination, parallelism, TOAST, block ranges and sampling.
-- Predicates use columns without an index (or "+ 0") so the scan stays sequential.

------------------------------------------------------------------------------
-- reading everything
------------------------------------------------------------------------------
call pgmb.reg('seqscan.count_narrow', '{perf,planning,olap}', $q$
select count(*) from g_events$q$);

call pgmb.reg('seqscan.count_wide', '{perf,planning,olap}', $q$
select count(*) from g_wide$q$);

call pgmb.reg('seqscan.count_small_table', '{perf,planning,oltp}', $q$
select count(*), max(category) from g_dim$q$);

call pgmb.reg('seqscan.aggregate_one_column', '{perf,planning,olap}', $q$
select sum(val), min(val), max(val) from g_events$q$);

call pgmb.reg('seqscan.aggregate_all_columns', '{perf,planning,olap}', $q$
select sum(i1), sum(i2), sum(i3), sum(i4), sum(i5), sum(i6), sum(i7), sum(i8),
       sum(length(t1)), sum(length(t2)), sum(length(t3)), sum(n1), max(d1), count(*) filter (where b1)
from g_wide$q$);

call pgmb.reg('seqscan.group_by_few_groups', '{perf,planning,olap}', $q$
select cat, count(*), avg(val) from g_events group by cat$q$);

------------------------------------------------------------------------------
-- filters: selectivity and position of the tested column in the row
------------------------------------------------------------------------------
call pgmb.reg('seqscan.filter_matches_1_percent', '{perf,planning,olap}', $q$
select count(*), sum(val) from g_events where val < 10$q$);

call pgmb.reg('seqscan.filter_matches_half', '{perf,planning,olap}', $q$
select count(*), sum(val) from g_events where val < 500$q$);

call pgmb.reg('seqscan.filter_matches_nothing', '{perf,planning,olap}', $q$
select count(*) from g_events where val < 0$q$);

call pgmb.reg('seqscan.filter_first_column', '{perf,planning,olap}', $q$
select count(*) from g_wide where i1 + 0 = 1$q$);

call pgmb.reg('seqscan.filter_last_column', '{perf,planning,olap}', $q$
select count(*) from g_wide where b1$q$);

call pgmb.reg('seqscan.filter_text_infix', '{perf,planning,olap}', $q$
select count(*) from g_wide where t3 like '%abc%'$q$);

call pgmb.reg('seqscan.filter_regex', '{perf,planning,olap}', $q$
select count(*) from g_wide where t2 ~ '^[0-9a-c]{4}.*f$'$q$);

call pgmb.reg('seqscan.filter_eight_quals', '{perf,planning,olap}', $q$
select count(*) from g_wide
where i1 + 0 = 1 and i2 < 8 and i7 >= 0 and i8 > 1000 and n1 > 10 and d1 > date '2001-01-01'
  and length(t1) = 10 and b1 is not null$q$);

call pgmb.reg('seqscan.filter_parameter', '{perf,planning,olap}', $q$
select count(*), max(amount) from g_child where kind = :k and amount > :a$q$,
    setup => E'\\set k random(0, 7)\n\\set a random(0, 900)');

------------------------------------------------------------------------------
-- stopping early
------------------------------------------------------------------------------
call pgmb.reg('seqscan.limit_first_rows', '{perf,planning,oltp}', $q$
select * from g_events limit 100$q$);

call pgmb.reg('seqscan.limit_common_match', '{perf,planning,oltp}', $q$
select * from g_events where cat = :c limit 10$q$,
    setup => '\set c random(0, 4)');

call pgmb.reg('seqscan.limit_rare_match', '{perf,planning,olap}', $q$
select * from g_events where val < 0.01 limit 1$q$);

call pgmb.reg('seqscan.exists_any_row', '{perf,planning,oltp}', $q$
select exists (select 1 from g_events where cat = :c and val > 990)$q$,
    setup => '\set c random(0, 4)');

------------------------------------------------------------------------------
-- serial vs. parallel (the same statement under two settings)
------------------------------------------------------------------------------
call pgmb.reg('seqscan.aggregate_serial', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 0;
select cat, count(*), avg(val) from g_events where val > 1 group by cat;
commit;$q$);

call pgmb.reg('seqscan.aggregate_parallel_4', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
select cat, count(*), avg(val) from g_events where val > 1 group by cat;
commit;$q$);

------------------------------------------------------------------------------
-- TOAST: out-of-line values are only read when the column is used
------------------------------------------------------------------------------
call pgmb.reg('seqscan.toast_not_touched', '{perf,planning}', $q$
select count(*), max(id) from g_array_big$q$);

call pgmb.reg('seqscan.toast_detoasted', '{perf,planning,olap}', $q$
select count(*), sum(a[1000]) from g_array_big$q$);

------------------------------------------------------------------------------
-- part of a table: block ranges and sampling
------------------------------------------------------------------------------
call pgmb.reg('seqscan.tid_range_first_blocks', '{perf,planning}', $q$
select count(*), sum(val) from g_events where ctid < '(100,0)'::tid$q$);

call pgmb.reg('seqscan.tid_range_middle', '{perf,planning}', $q$
select count(*), sum(val) from g_events where ctid >= '(20,0)'::tid and ctid < '(40,0)'::tid$q$);

call pgmb.reg('seqscan.sample_system_blocks', '{perf,planning}', $q$
select count(*), avg(val) from g_events tablesample system (5)$q$);

call pgmb.reg('seqscan.sample_bernoulli_rows', '{perf,planning,olap}', $q$
select count(*), avg(val) from g_events tablesample bernoulli (5)$q$);

call pgmb.reg('seqscan.sample_repeatable', '{perf,planning}', $q$
select count(*), avg(val) from g_events tablesample system (5) repeatable (42)$q$);

------------------------------------------------------------------------------
-- sequential scans feeding joins
------------------------------------------------------------------------------
call pgmb.reg('seqscan.hash_join_two_scans', '{perf,planning,olap}', $q$
select count(*), sum(c.amount) from g_child c join g_parent p on p.id = c.parent_id where p.val > 100 and c.amount > 10$q$);

call pgmb.reg('seqscan.self_join_no_index', '{perf,planning,olap}', $q$
select count(*) from g_graph a join g_graph b on a.w = b.w and a.src = b.dst where a.w < 3$q$);

call pgmb.reg('seqscan.err_sample_percentage', '{errors}',
    $q$select count(*) from g_events tablesample system (101)$q$, expect_error => '2202H');
