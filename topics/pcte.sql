-- Topic: pcte - materialized top-level CTEs as independent units of work.
-- Written for a patch that computes such CTEs in parallel workers while the
-- leader consumes the results, but nothing here needs the patch: every test is
-- plain SQL and runs on a stock server, where it gives the serial baseline.
--
-- Method: run the topic twice with different server settings and compare.
--   bench.sql -v topics=pcte -v label=off -v gucs='enable_parallel_cte=off'
--   bench.sql -v topics=pcte -v label=on  -v gucs='enable_parallel_cte=on,max_parallel_cte_workers=3' -v skip_ddl=1
--   report/compare.sql -v a=<run off> -v b=<run on>
-- and look at the plans with report/explain.sql -v test='^pcte\.' -v analyze=1 -v gucs=...
-- Each group has a consistency pair: the MATERIALIZED form must return the same
-- rows as the inlined, single-process form of the same question.
--
-- Sizes follow data_scale: g_narrow and g_child have 1M rows at scale 1, 10M at
-- scale 10, 60M at scale 60. Tests named after a row count (rows_10k ...) read
-- that many rows of g_narrow, or the whole table when it is smaller.
--
-- One unit of work, used all over: a grouped aggregate over the rows of g_narrow
-- in one residue class.  unit(i, n) scans the table and hashes 1/n of the rows.
-- Tags: pcte_mix marks the mixed workload for multi-session runs, pcte_oltp the
-- short indexed queries.

------------------------------------------------------------------------------
-- 1a. N independent CTEs of equal cost, N = 2, 3, 4, 8
------------------------------------------------------------------------------
select string_agg(n::text, ',') as pgmb_ns from (values (2), (3), (4), (8)) v(n) \gset
select format($f$call pgmb.reg('pcte.shape_independent_%1$s', '{perf,planning,consistency,olap,pcte_mix}', %2$L, equiv => 'pcte.independent_%1$s')$f$, n,
              'with ' || (select string_agg(format('c%s as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id %% %s = %s group by k_100)', i, n, i), E',\n     ' order by i) from generate_series(0, n - 1) i)
              || E'\nselect sum(n), sum(h) from (' || (select string_agg(format('select n, h from c%s', i), ' union all ' order by i) from generate_series(0, n - 1) i) || ') u')
from (values (2), (3), (4), (8)) v(n) \gexec

-- the same total work as one statement without CTEs: the serial reference
select format($f$call pgmb.reg('pcte.shape_independent_%1$s_single_scan', '{perf,planning,consistency,olap}', %2$L, equiv => 'pcte.independent_%1$s')$f$, n,
              'select sum(n), sum(h) from (select id % ' || n || ' as part, k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by 1, 2) s')
from (values (2), (3), (4), (8)) v(n) \gexec

------------------------------------------------------------------------------
-- 1b. unequal CTEs: one long, several short, in proportions 1:4, 1:10, 1:100
-- (the long one reads the whole table, each short one a fraction of it)
------------------------------------------------------------------------------
select format($f$call pgmb.reg('pcte.shape_unequal_1_to_%1$s', '{perf,planning,checksum,olap,pcte_mix}', %2$L)$f$, r,
              format($q$with long_one as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     short_a as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id <= :n_g_narrow / %1$s group by k_100),
     short_b as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id between :n_g_narrow / 2 and :n_g_narrow / 2 + :n_g_narrow / %1$s group by k_100),
     short_c as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id > :n_g_narrow - :n_g_narrow / %1$s group by k_100)
select (select sum(n) from long_one), (select sum(n) from short_a), (select sum(n) from short_b), (select sum(n) from short_c)$q$, r))
from (values (4), (10), (100)) v(r) \gexec

-- the long CTE written last and read last: its position should not matter
call pgmb.reg('pcte.shape_unequal_long_one_last', '{perf,planning,checksum,olap}', $q$
with short_a as materialized (select k_100, count(*) as n from g_narrow where id <= :n_g_narrow / 10 group by k_100),
     short_b as materialized (select k_100, count(*) as n from g_narrow where id > :n_g_narrow - :n_g_narrow / 10 group by k_100),
     long_one as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100)
select (select sum(n) from short_a), (select sum(n) from short_b), (select sum(n) from long_one)$q$);

------------------------------------------------------------------------------
-- 1c. diamond: A and B independent, C reads both
------------------------------------------------------------------------------
call pgmb.reg('pcte.shape_diamond', '{perf,planning,consistency,olap,pcte_mix}', $q$
with a as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 1 group by k_100),
     c as materialized (select a.k_100, a.n, b.h from a join b using (k_100))
select count(*), sum(n), sum(h) from c$q$, equiv => 'pcte.diamond');

call pgmb.reg('pcte.shape_diamond_inlined', '{perf,planning,consistency,olap}', $q$
with a as (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as (select k_100, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 1 group by k_100),
     c as (select a.k_100, a.n, b.h from a join b using (k_100))
select count(*), sum(n), sum(h) from c$q$, equiv => 'pcte.diamond');

-- a common root above the two branches: root -> A, B -> C
call pgmb.reg('pcte.shape_diamond_with_shared_root', '{perf,planning,checksum,olap}', $q$
with root as materialized (select id, k_100, k_10k, hashtext(pad) as h from g_narrow where id % 4 = 0),
     a as materialized (select k_100, count(*) as n from root group by k_100),
     b as materialized (select k_10k % 100 as k_100, sum(h::bigint) as h from root group by 1),
     c as materialized (select a.k_100, a.n, b.h from a join b using (k_100))
select count(*), sum(n), sum(h) from c$q$);

------------------------------------------------------------------------------
-- 1d. one CTE read many times, by other CTEs and by the main query
------------------------------------------------------------------------------
call pgmb.reg('pcte.shape_one_source_many_readers', '{perf,planning,consistency,olap,pcte_mix}', $q$
with src as materialized (select k_100, k_10k, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100, k_10k),
     by_100 as materialized (select k_100, sum(n) as n from src group by k_100),
     by_10k as materialized (select k_10k, sum(h) as h from src group by k_10k),
     top as materialized (select max(n) as mx from src)
select (select count(*) from src), (select sum(n) from by_100), (select count(*) from by_10k), (select mx from top)$q$,
    equiv => 'pcte.many_readers');

call pgmb.reg('pcte.shape_one_source_many_readers_inlined', '{perf,planning,consistency,olap}', $q$
with src as not materialized (select k_100, k_10k, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100, k_10k),
     by_100 as (select k_100, sum(n) as n from src group by k_100),
     by_10k as (select k_10k, sum(h) as h from src group by k_10k),
     top as (select max(n) as mx from src)
select (select count(*) from src), (select sum(n) from by_100), (select count(*) from by_10k), (select mx from top)$q$,
    equiv => 'pcte.many_readers');

-- two independent sources, each with two readers
call pgmb.reg('pcte.shape_two_sources_two_readers_each', '{perf,planning,checksum,olap}', $q$
with s1 as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     s2 as materialized (select kind, sum(amount) as total from g_child group by kind)
select (select sum(n) from s1), (select max(n) from s1), (select sum(total) from s2), (select count(*) from s2)$q$);

------------------------------------------------------------------------------
-- 1e. mixed DAG: 8 CTEs on three levels
------------------------------------------------------------------------------
call pgmb.reg('pcte.shape_mixed_dag_8', '{perf,planning,consistency,olap,pcte_mix}', $q$
with n0 as materialized (select k_100, count(*) as n from g_narrow where id % 4 = 0 group by k_100),
     n1 as materialized (select k_100, count(*) as n from g_narrow where id % 4 = 1 group by k_100),
     n2 as materialized (select k_100, sum(hashtext(pad)::bigint) as h from g_narrow where id % 4 = 2 group by k_100),
     ch as materialized (select kind, count(*) as n, sum(amount) as total from g_child group by kind),
     ev as materialized (select cat, count(*) as n, avg(val) as v from g_events group by cat),
     l1 as materialized (select k_100, n0.n + n1.n as n from n0 join n1 using (k_100)),
     l2 as materialized (select l1.k_100, l1.n, n2.h from l1 join n2 using (k_100)),
     side as materialized (select ch.kind, ch.total, ev.v from ch join ev on ev.cat = ch.kind % 5)
select (select sum(n) from l2), (select sum(h) from l2), (select count(*) from side), (select sum(total) from side)$q$,
    equiv => 'pcte.mixed_dag');

call pgmb.reg('pcte.shape_mixed_dag_8_inlined', '{perf,planning,consistency,olap}', $q$
with n0 as (select k_100, count(*) as n from g_narrow where id % 4 = 0 group by k_100),
     n1 as (select k_100, count(*) as n from g_narrow where id % 4 = 1 group by k_100),
     n2 as (select k_100, sum(hashtext(pad)::bigint) as h from g_narrow where id % 4 = 2 group by k_100),
     ch as (select kind, count(*) as n, sum(amount) as total from g_child group by kind),
     ev as (select cat, count(*) as n, avg(val) as v from g_events group by cat),
     l1 as (select k_100, n0.n + n1.n as n from n0 join n1 using (k_100)),
     l2 as not materialized (select l1.k_100, l1.n, n2.h from l1 join n2 using (k_100)),
     side as not materialized (select ch.kind, ch.total, ev.v from ch join ev on ev.cat = ch.kind % 5)
select (select sum(n) from l2), (select sum(h) from l2), (select count(*) from side), (select sum(total) from side)$q$,
    equiv => 'pcte.mixed_dag');

------------------------------------------------------------------------------
-- 2. the planner should decline, or at least not lose
------------------------------------------------------------------------------
-- 2a. a pure chain: nothing can overlap
call pgmb.reg('pcte.decline_chain', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, k_100, hashtext(pad) as h from g_narrow where id % 2 = 0),
     b as materialized (select k_100, count(*) as n, sum(h::bigint) as h from a group by k_100),
     c as materialized (select count(*) as groups, sum(n) as n, sum(h) as h from b)
select * from c$q$);

-- 2b. one real CTE, the other read only under LIMIT or EXISTS
call pgmb.reg('pcte.decline_second_cte_under_limit', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     b as materialized (select id, hashtext(pad) as h from g_narrow)
select (select sum(n) from a), (select count(*) from (select h from b limit 10) s)$q$);

call pgmb.reg('pcte.decline_second_cte_under_exists', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     b as materialized (select id, hashtext(pad) as h from g_narrow)
select (select sum(n) from a), exists (select 1 from b where h is not null)$q$);

call pgmb.reg('pcte.decline_second_cte_unreferenced', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     b as materialized (select id, hashtext(pad) as h from g_narrow)
select sum(n) from a$q$);

-- 2c. one CTE for a worker, one that only the leader may run (parallel
-- restricted), both read completely. Two read orders. random() >= 0 is always
-- true: it makes the CTE restricted without making the result random.
call pgmb.reg('pcte.restricted_random_worker_cte_read_first', '{perf,planning,checksum,olap}', $q$
with safe as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     restricted as materialized (select k_100, count(*) as n from g_narrow where random() >= 0 group by k_100)
select 'safe' as part, sum(n) from safe union all select 'restricted', sum(n) from restricted$q$);

call pgmb.reg('pcte.restricted_random_leader_cte_read_first', '{perf,planning,checksum,olap}', $q$
with safe as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     restricted as materialized (select k_100, count(*) as n from g_narrow where random() >= 0 group by k_100)
select 'restricted' as part, sum(n) from restricted union all select 'safe', sum(n) from safe$q$);

-- the restricted part is a temporary table (only the leader can read it)
call pgmb.reg('pcte.restricted_temp_table_worker_cte_read_first', '{perf,checksum,olap}', $q$
begin;
create temp table pgmb_tmp on commit drop as select id, k_100, pad from g_narrow where id % 2 = 0;
with safe as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 1 group by k_100),
     restricted as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from pgmb_tmp group by k_100)
select 'safe' as part, sum(n) from safe union all select 'restricted', sum(n) from restricted;
commit;$q$);

call pgmb.reg('pcte.restricted_temp_table_leader_cte_read_first', '{perf,checksum,olap}', $q$
begin;
create temp table pgmb_tmp on commit drop as select id, k_100, pad from g_narrow where id % 2 = 0;
with safe as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 1 group by k_100),
     restricted as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from pgmb_tmp group by k_100)
select 'restricted' as part, sum(n) from restricted union all select 'safe', sum(n) from safe;
commit;$q$);

-- both CTEs restricted: nothing for a worker
call pgmb.reg('pcte.restricted_both', '{perf,planning,checksum,olap}', $q$
with r1 as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 and random() >= 0 group by k_100),
     r2 as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 1 and random() >= 0 group by k_100)
select (select sum(n) from r1), (select sum(n) from r2)$q$);

-- parallel unsafe anywhere: the whole statement stays in one process
call pgmb.reg('pcte.unsafe_function_in_one_cte', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, count(*) as n, sum(noop_par_unsafe(k_100)) as u from g_narrow where id % 2 = 1 group by k_100)
select (select sum(n) from a), (select sum(n) from b)$q$);

-- a writer among the CTEs
call pgmb.reg('pcte.writer_among_ctes', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 1 group by k_100),
     w as (update g_parent set updated_at = now() where id = :id returning id)
select (select sum(n) from a), (select sum(n) from b), (select count(*) from w)$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- 2d. cheap CTEs: input from 10k rows up, where starting workers stops paying off
select format($f$call pgmb.reg('pcte.threshold_rows_%1$s', '{perf,planning,checksum,olap}', %2$L)$f$, lbl,
              format($q$with a as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id <= %1$s and id %% 2 = 0 group by k_100),
     b as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id <= %1$s and id %% 2 = 1 group by k_100)
select (select sum(n) from a), (select sum(n) from b)$q$, n))
from (values ('10k', 10000), ('30k', 30000), ('100k', 100000), ('300k', 300000), ('1m', 1000000), ('10m', 10000000), ('60m', 60000000)) v(lbl, n) \gexec

------------------------------------------------------------------------------
-- 3. together with parallel query
------------------------------------------------------------------------------
-- 3a. a CTE that would get its own Gather, next to an ordinary one
call pgmb.reg('pcte.gather_inside_one_cte', '{perf,planning,checksum,olap}', $q$
with big as materialized (select cat, count(*) as n, avg(val) as v from g_events group by cat),
     other as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100)
select (select sum(n) from big), (select sum(n) from other)$q$);

call pgmb.reg('pcte.gather_inside_every_cte', '{perf,planning,checksum,olap}', $q$
with e as materialized (select cat, count(*) as n from g_events group by cat),
     n as materialized (select k_100, count(*) as n from g_narrow group by k_100),
     c as materialized (select kind, count(*) as n from g_child group by kind)
select (select sum(n) from e), (select sum(n) from n), (select sum(n) from c)$q$);

-- 3b. the main query has a parallel plan of its own
call pgmb.reg('pcte.gather_in_main_query', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 1 group by k_100)
select e.cat, count(*), avg(e.val), (select sum(n) from a), (select sum(n) from b)
from g_events e group by e.cat order by e.cat$q$);

-- the parallel settings forced low enough to plan Gather at any scale
call pgmb.reg('pcte.gather_forced_in_cte_and_main', '{perf,checksum,olap}', $q$
begin;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with a as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select kind, count(*) as n from g_child group by kind)
select e.cat, count(*), avg(e.val), (select sum(n) from a), (select sum(n) from b)
from g_events e group by e.cat order by e.cat;
commit;$q$);

------------------------------------------------------------------------------
-- 4. what the main query does
------------------------------------------------------------------------------
-- 4a. read order: the longer CTE first, or the shorter one first
call pgmb.reg('pcte.main_reads_long_cte_first', '{perf,planning,checksum,olap}', $q$
with long_one as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     short_one as materialized (select k_100, count(*) as n from g_narrow where id <= :n_g_narrow / 10 group by k_100)
select 'long' as part, sum(n) from long_one union all select 'short', sum(n) from short_one$q$);

call pgmb.reg('pcte.main_reads_short_cte_first', '{perf,planning,checksum,olap}', $q$
with long_one as materialized (select k_100, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_100),
     short_one as materialized (select k_100, count(*) as n from g_narrow where id <= :n_g_narrow / 10 group by k_100)
select 'short' as part, sum(n) from short_one union all select 'long', sum(n) from long_one$q$);

-- 4b. the main query has heavy work of its own before it needs any CTE
call pgmb.reg('pcte.main_heavy_join_then_ctes', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 1 group by k_100)
select count(*), sum(c.amount), (select sum(n) from a), (select sum(n) from b)
from g_child c join g_parent p on p.id = c.parent_id where p.grp < 50$q$);

call pgmb.reg('pcte.main_heavy_sort_then_ctes', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 1 group by k_100)
select count(*), (select sum(n) from a), (select sum(n) from b)
from (select id from g_child order by amount, note offset 0) s$q$);

-- the main query joins the CTE results into its own large scan
call pgmb.reg('pcte.main_joins_cte_into_large_scan', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, count(*) as n from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 1 group by k_100)
select count(*), sum(a.n), sum(b.h) from g_narrow t join a using (k_100) join b using (k_100) where t.id % 10 = 0$q$);

-- 4c. the reader stops early: is the work done ahead of time wasted, and at what price
-- which ten rows come back is not defined, so this one has no checksum
call pgmb.reg('pcte.early_stop_outer_limit', '{perf,planning,olap}', $q$
with a as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 0),
     b as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 1)
select * from (select id, h from a union all select id, h from b) u limit 10$q$);

call pgmb.reg('pcte.early_stop_exists_on_both', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 0),
     b as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 1)
select exists (select 1 from a), exists (select 1 from b)$q$);

call pgmb.reg('pcte.early_stop_cursor_fetch_10', '{perf,olap}', $q$
begin;
declare pgmb_cur cursor for
    with a as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 0),
         b as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 1)
    select a.id, a.h, b.h from a join b on b.id = a.id + 1;
fetch 10 from pgmb_cur;
close pgmb_cur;
commit;$q$);

call pgmb.reg('pcte.early_stop_cursor_fetch_in_tens', '{perf,olap}', $q$
begin;
declare pgmb_cur cursor for
    with a as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 0),
         b as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 1)
    select a.id, a.h, b.h from a join b on b.id = a.id + 1;
fetch 10 from pgmb_cur;
fetch 10 from pgmb_cur;
fetch 10 from pgmb_cur;
fetch 10 from pgmb_cur;
fetch 10 from pgmb_cur;
close pgmb_cur;
commit;$q$);

-- the same statement read to the end
call pgmb.reg('pcte.early_stop_none_full_read', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 0),
     b as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 1)
select count(*), sum(a.h::bigint + b.h) from a join b on b.id = a.id + 1$q$);

call pgmb.reg('pcte.early_stop_cursor_rollback', '{perf,olap}', $q$
begin;
declare pgmb_cur cursor for
    with a as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 0),
         b as materialized (select id, hashtext(pad) as h from g_narrow where id % 2 = 1)
    select a.id, a.h, b.h from a join b on b.id = a.id + 1;
fetch 10 from pgmb_cur;
rollback;$q$);

------------------------------------------------------------------------------
-- 5b. short indexed queries with CTEs: planning and start-up overhead
-- (5a, the mixed workload, is the tests tagged pcte_mix run with mode=mixed)
------------------------------------------------------------------------------
call pgmb.reg('pcte.oltp_two_pk_lookups', '{perf,planning,checksum,oltp,pcte_oltp}', $q$
with p as materialized (select id, val, grp from g_parent where id = :id),
     c as materialized (select parent_id, count(*) as n, sum(amount) as total from g_child where parent_id = :id group by parent_id)
select p.id, p.val, c.n, c.total from p left join c on c.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('pcte.oltp_two_pk_lookups_inlined', '{perf,planning,checksum,oltp,pcte_oltp}', $q$
with p as (select id, val, grp from g_parent where id = :id),
     c as (select parent_id, count(*) as n, sum(amount) as total from g_child where parent_id = :id group by parent_id)
select p.id, p.val, c.n, c.total from p left join c on c.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('pcte.oltp_three_small_ranges', '{perf,planning,checksum,oltp,pcte_oltp}', $q$
with a as materialized (select count(*) as n, sum(val) as total from g_parent where id between :id and :id + 99),
     b as materialized (select count(*) as n from g_narrow where id between :id and :id + 99),
     c as materialized (select count(*) as n from g_events where id between :id and :id + 99)
select a.n, a.total, b.n, c.n from a, b, c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('pcte.oltp_diamond_small', '{perf,planning,checksum,oltp,pcte_oltp}', $q$
with a as materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as materialized (select grp, count(*) as n from a group by grp),
     c as materialized (select grp, sum(val) as total from a group by grp)
select count(*), sum(b.n), sum(c.total) from b join c using (grp)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('pcte.oltp_single_cte', '{perf,planning,checksum,oltp,pcte_oltp}', $q$
with p as materialized (select id, val from g_parent where id = :id)
select * from p$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('pcte.oltp_no_cte_baseline', '{perf,planning,checksum,oltp,pcte_oltp}', $q$
select id, val from g_parent where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 6. kind of work inside the CTEs (always two independent CTEs)
------------------------------------------------------------------------------
-- bound by the scan: a count, nearly no computation per row
call pgmb.reg('pcte.work_scan_bound', '{perf,planning,checksum,olap,pcte_mix}', $q$
with a as materialized (select count(*) as n from g_narrow where k_null is not null),
     b as materialized (select count(*) as n from g_child where amount >= 0)
select a.n, b.n from a, b$q$);

-- bound by CPU: hashing every row, a large hash aggregate
call pgmb.reg('pcte.work_cpu_hash_aggregate', '{perf,planning,checksum,olap,pcte_mix}', $q$
with a as materialized (select k_10k, count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow group by k_10k),
     b as materialized (select parent_id, count(*) as n, sum(amount) as total from g_child group by parent_id)
select (select count(*) from a), (select sum(h) from a), (select count(*) from b), (select sum(total) from b)$q$);

call pgmb.reg('pcte.work_cpu_sort', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, pad from g_narrow order by pad),
     b as materialized (select id, note from g_child order by note)
select (select count(*) from a), (select count(*) from b)$q$);

call pgmb.reg('pcte.work_cpu_expensive_expressions', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as l from g_narrow where id % 2 = 0),
     b as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as l from g_narrow where id % 2 = 1)
select a.n, a.l, b.n, b.l from a, b$q$);

-- more memory than work_mem: both CTEs spill
call pgmb.reg('pcte.work_spill_sort_4mb', '{perf,checksum,olap}', $q$
begin;
set local work_mem = '4MB';
with a as materialized (select id, pad from g_narrow order by pad),
     b as materialized (select id, note from g_child order by note)
select (select count(*) from a), (select count(*) from b);
commit;$q$);

call pgmb.reg('pcte.work_spill_hash_aggregate_4mb', '{perf,checksum,olap}', $q$
begin;
set local work_mem = '4MB';
with a as materialized (select k_uniq, count(*) as n from g_narrow group by k_uniq),
     b as materialized (select id, count(*) as n from g_child group by id)
select (select count(*) from a), (select count(*) from b);
commit;$q$);

call pgmb.reg('pcte.work_no_spill_256mb', '{perf,checksum,olap}', $q$
begin;
set local work_mem = '256MB';
with a as materialized (select id, pad from g_narrow order by pad),
     b as materialized (select id, note from g_child order by note)
select (select count(*) from a), (select count(*) from b);
commit;$q$);

------------------------------------------------------------------------------
-- result size: rows x width of what each CTE hands over
-- (two CTEs; rows are capped by the size of g_narrow)
------------------------------------------------------------------------------
select format($f$call pgmb.reg('pcte.transfer_%1$s_rows_%2$s_bytes', '{perf,planning,checksum,olap}', %3$L)$f$, lbl, w,
              format($q$with a as materialized (select id, repeat('a', %2$s) as pad from g_narrow where id <= %1$s and id %% 2 = 0),
     b as materialized (select id, repeat('b', %2$s) as pad from g_narrow where id <= %1$s and id %% 2 = 1)
select (select count(*) from a), (select sum(length(pad)) from a), (select count(*) from b), (select sum(length(pad)) from b)$q$, n, greatest(w - 16, 0)))
from (values ('10k', 10000), ('1m', 1000000), ('10m', 10000000)) r(lbl, n), (values (16), (100), (1000)) v(w)
where n::bigint * w < 1000000000 \gexec

-- a gigabyte or more of temporary files per CTE: only with -v tags=optin_bigtransfer
-- (and a temp_file_limit, see README)
select format($f$call pgmb.reg('pcte.transfer_%1$s_rows_%2$s_bytes', '{perf,planning,checksum,olap,optin_bigtransfer}', %3$L)$f$, lbl, w,
              format($q$with a as materialized (select id, repeat('a', %2$s) as pad from g_narrow where id <= %1$s and id %% 2 = 0),
     b as materialized (select id, repeat('b', %2$s) as pad from g_narrow where id <= %1$s and id %% 2 = 1)
select (select count(*) from a), (select sum(length(pad)) from a), (select count(*) from b), (select sum(length(pad)) from b)$q$, n, greatest(w - 16, 0)))
from (values ('10k', 10000), ('1m', 1000000), ('10m', 10000000)) r(lbl, n), (values (16), (100), (1000)) v(w)
where n::bigint * w >= 1000000000 \gexec

-- one row out, whatever went in
call pgmb.reg('pcte.transfer_1_row', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 0),
     b as materialized (select count(*) as n, sum(hashtext(pad)::bigint) as h from g_narrow where id % 2 = 1)
select a.n, a.h, b.n, b.h from a, b$q$);

-- large results read twice by the main query
call pgmb.reg('pcte.transfer_wide_result_two_readers', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, pad || pad as pad from g_narrow where id % 2 = 0),
     b as materialized (select id, pad || pad as pad from g_narrow where id % 2 = 1)
select (select count(*) from a), (select max(pad) from a), (select count(*) from b), (select max(pad) from b)$q$);

-- a small temp_file_limit against a result that has to go to disk is a
-- per-run setting: -v gucs='temp_file_limit=1GB'
