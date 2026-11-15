-- Topic: cte (part 23) - memory and temporary files of materialized CTEs.
-- The rows of a materialized CTE are kept in a tuple store: in memory up to
-- work_mem, in a temporary file beyond it. Every materialized CTE has its own
-- store, and sorts and hashes inside the CTE have their own work_mem on top.
-- Each test sets work_mem for its transaction. The report shows, per test, the
-- temporary bytes written per transaction (pgbench run) and the memory / disk
-- use of the plan nodes (tag "analyze"). Sizes follow data_scale: the whole of
-- g_narrow is about 1 MB at scale 0.01 and 100 MB at scale 1, so with
-- work_mem = 64kB everything spills and with 1GB nothing does (up to scale ~5).

------------------------------------------------------------------------------
-- one CTE, below and above work_mem
------------------------------------------------------------------------------
call pgmb.reg('cte.mem_one_cte_in_memory', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '1GB';
with c as materialized (select id, k_100, pad from g_narrow)
select count(*), sum(k_100) from c;
commit;$q$);

call pgmb.reg('cte.mem_one_cte_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100, pad from g_narrow)
select count(*), sum(k_100) from c;
commit;$q$);

-- not materialized: nothing is stored at all
call pgmb.reg('cte.mem_one_cte_inlined_no_store', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as (select id, k_100, pad from g_narrow)
select count(*), sum(k_100) from c;
commit;$q$);

-- a CTE that just fits, and the same with one more column
call pgmb.reg('cte.mem_small_cte_fits_64kb', '{perf,planning,analyze,oltp}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100 from g_narrow where id between :id and :id + 499)
select count(*), sum(k_100) from c;
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.mem_small_cte_exceeds_64kb', '{perf,planning,analyze,oltp}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100, pad || pad || pad as wide from g_narrow where id between :id and :id + 499)
select count(*), sum(k_100) from c;
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- several CTEs alive at the same time: N stores, N times work_mem
------------------------------------------------------------------------------
select format($f$call pgmb.reg('cte.mem_%1$s_ctes_at_once_%2$s', '{perf,planning,analyze,olap}', %3$L)$f$, n, lbl,
              format(E'begin;\nset local work_mem = %L;\nwith ', wm)
              || (select string_agg(format('c%s as materialized (select id, k_100, pad from g_narrow where id %% %s = %s)', i, n, i), E',\n     ' order by i) from generate_series(0, n - 1) i)
              || E'\nselect ' || (select string_agg(format('(select count(*) from c%s)', i), ' + ' order by i) from generate_series(0, n - 1) i)
              || E';\ncommit;')
from (values (2), (4), (8), (16)) v(n), (values ('in_memory', '1GB'), ('spilled', '64kB')) w(lbl, wm) \gexec

-- the same rows in one CTE read once
call pgmb.reg('cte.mem_same_rows_one_cte_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100, pad from g_narrow)
select count(*) from c;
commit;$q$);

-- 50 tiny CTEs: the fixed cost of a store
select E'begin;\nset local work_mem = ''64kB'';\nwith '
       || string_agg(format('c%s as materialized (select id, val from g_parent where id = :id + %s)', i, i), ', ' order by i)
       || E'\nselect ' || string_agg(format('(select val from c%s)', i), ' + ' order by i) || E';\ncommit;' as pgmb_sql
from generate_series(1, 50) i \gset
call pgmb.reg('cte.mem_50_tiny_ctes', '{perf,planning,analyze,oltp}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent - 50)');

------------------------------------------------------------------------------
-- what is stored: columns, width, unused columns
------------------------------------------------------------------------------
call pgmb.reg('cte.mem_narrow_columns_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100 from g_narrow)
select count(*), sum(k_100) from c;
commit;$q$);

call pgmb.reg('cte.mem_wide_columns_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100, pad || pad || pad || pad as wide from g_narrow)
select count(*), sum(k_100) from c;
commit;$q$);

-- select * although one column is used: every column is written to the store
call pgmb.reg('cte.mem_select_star_one_column_used', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select * from g_wide)
select count(*), sum(i3) from c;
commit;$q$);

call pgmb.reg('cte.mem_only_needed_column', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select i3 from g_wide)
select count(*), sum(i3) from c;
commit;$q$);

-- large values kept out of line are stored as pointers, not as copies
call pgmb.reg('cte.mem_toasted_values_as_pointers', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, a from g_array_big)
select count(*) from c;
commit;$q$);

-- ... until an expression makes new large values
call pgmb.reg('cte.mem_toasted_values_recomputed', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, array_reverse(a) as a from g_array_big)
select count(*) from c;
commit;$q$);

------------------------------------------------------------------------------
-- reading a store again
------------------------------------------------------------------------------
call pgmb.reg('cte.mem_three_readers_in_memory', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '1GB';
with c as materialized (select id, k_100, pad from g_narrow)
select (select count(*) from c), (select sum(k_100) from c), (select max(pad) from c);
commit;$q$);

call pgmb.reg('cte.mem_three_readers_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100, pad from g_narrow)
select (select count(*) from c), (select sum(k_100) from c), (select max(pad) from c);
commit;$q$);

-- rescanned once per outer row from a temporary file
call pgmb.reg('cte.mem_rescan_per_row_spilled', '{perf,planning,analyze}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100, pad from g_narrow where id between :id and :id + 1999)
select count(*) from (select k_100 from c limit 20) o where o.k_100 < (select avg(i.k_100) from c i where i.k_100 >= o.k_100);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.mem_rescan_per_row_in_memory', '{perf,planning,analyze}', $q$
begin;
set local work_mem = '1GB';
with c as materialized (select id, k_100, pad from g_narrow where id between :id and :id + 1999)
select count(*) from (select k_100 from c limit 20) o where o.k_100 < (select avg(i.k_100) from c i where i.k_100 >= o.k_100);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- the reader stops early: only what was read is written
call pgmb.reg('cte.mem_early_stop_writes_a_prefix', '{perf,planning,analyze,oltp}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, k_100, pad from g_narrow)
select count(*) from (select id from c limit 2000) s;
commit;$q$);

------------------------------------------------------------------------------
-- work inside the CTE has its own memory, on top of the store
------------------------------------------------------------------------------
call pgmb.reg('cte.mem_sort_inside_cte_spilled_twice', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, pad from g_narrow order by pad)
select count(*), max(pad) from c;
commit;$q$);

call pgmb.reg('cte.mem_sort_inside_cte_in_memory', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '1GB';
with c as materialized (select id, pad from g_narrow order by pad)
select count(*), max(pad) from c;
commit;$q$);

call pgmb.reg('cte.mem_hash_aggregate_inside_cte_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select k_uniq, count(*) as n from g_narrow group by k_uniq)
select count(*), sum(n) from c;
commit;$q$);

-- hash_mem_multiplier lets the hash, not the store, use more
call pgmb.reg('cte.mem_hash_aggregate_inside_cte_multiplier_64', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
set local hash_mem_multiplier = 64;
with c as materialized (select k_uniq, count(*) as n from g_narrow group by k_uniq)
select count(*), sum(n) from c;
commit;$q$);

-- store plus a sort of the store's content in the main query
call pgmb.reg('cte.mem_store_then_outer_sort_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id, pad from g_narrow)
select count(*) from (select id from c order by pad offset 0) s;
commit;$q$);

-- a chain of three materialized CTEs: three copies of nearly the same rows
call pgmb.reg('cte.mem_chain_three_copies_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with a as materialized (select id, k_100, pad from g_narrow),
     b as materialized (select id, k_100, pad from a where k_100 < 90),
     c as materialized (select id, k_100, pad from b where k_100 < 80)
select count(*) from c;
commit;$q$);

call pgmb.reg('cte.mem_chain_three_copies_in_memory', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '1GB';
with a as materialized (select id, k_100, pad from g_narrow),
     b as materialized (select id, k_100, pad from a where k_100 < 90),
     c as materialized (select id, k_100, pad from b where k_100 < 80)
select count(*) from c;
commit;$q$);

-- a recursive CTE keeps its working table and its result
call pgmb.reg('cte.mem_recursive_result_spilled', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '64kB';
with recursive r(n, pad) as (select 1, repeat('x', 100) union all select n + 1, pad from r where n < 20000)
select count(*), sum(length(pad)) from r;
commit;$q$);

call pgmb.reg('cte.mem_recursive_result_in_memory', '{perf,planning,analyze,olap}', $q$
begin;
set local work_mem = '1GB';
with recursive r(n, pad) as (select 1, repeat('x', 100) union all select n + 1, pad from r where n < 20000)
select count(*), sum(length(pad)) from r;
commit;$q$);

-- writers: RETURNING rows are stored like any other CTE result
call pgmb.reg('cte.mem_returning_rows_spilled', '{perf,planning,analyze}', $q$
begin;
set local work_mem = '64kB';
with u as (update g_parent set val = val + 1 where id between :id and :id + 1999 returning id, name, val)
select count(*), max(name) from u;
commit;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');
