-- Topic: cte (part 25) - parallel query inside and around CTEs.
-- A CTE Scan is parallel restricted: it runs in the leader, above any Gather.
-- The body of a materialized CTE is planned on its own and may contain a
-- Gather; an inlined CTE simply becomes part of the outer parallel plan.
-- Every test forces cheap parallel plans for its transaction, so the shapes
-- appear at any data_scale (the workers still have to be available:
-- max_worker_processes, max_parallel_workers). Forms of one query are a
-- consistency group; sums are over numeric or integer columns so that the order
-- in which workers deliver rows cannot change the result.
-- Elsewhere: cte.parallel_* (serial / inlined / materialized, unsafe functions),
-- cte.mix_parallel_*, and the topic pcte.

\set pgmb_par2 'begin;\nset local max_parallel_workers_per_gather = 2;\nset local min_parallel_table_scan_size = 0;\nset local min_parallel_index_scan_size = 0;\nset local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\n'
\set pgmb_par0 'begin;\nset local max_parallel_workers_per_gather = 0;\n'
\set pgmb_end ';\ncommit;'

------------------------------------------------------------------------------
-- scan and aggregate: partial aggregation below Gather
------------------------------------------------------------------------------
call pgmb.reg('cte.par_aggregate_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as (select kind, count(*) as n, sum(amount) as total from g_child group by kind)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end', equiv => 'cte.par_aggregate');

call pgmb.reg('cte.par_aggregate_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as materialized (select kind, count(*) as n, sum(amount) as total from g_child group by kind)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end', equiv => 'cte.par_aggregate');

call pgmb.reg('cte.par_aggregate_serial', '{perf,planning,analyze,consistency,olap}', :'pgmb_par0' || $q$
with c as materialized (select kind, count(*) as n, sum(amount) as total from g_child group by kind)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end', equiv => 'cte.par_aggregate');

-- the CTE hands over rows, the aggregate is outside: materialized, every row
-- crosses Gather and is stored before the leader aggregates alone
call pgmb.reg('cte.par_rows_out_aggregate_outside_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as (select kind, amount from g_child where amount > 100)
select kind, count(*), sum(amount) from c group by kind$q$ || :'pgmb_end', equiv => 'cte.par_rows_out');

call pgmb.reg('cte.par_rows_out_aggregate_outside_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as materialized (select kind, amount from g_child where amount > 100)
select kind, count(*), sum(amount) from c group by kind$q$ || :'pgmb_end', equiv => 'cte.par_rows_out');

call pgmb.reg('cte.par_rows_out_aggregate_outside_serial', '{perf,planning,analyze,consistency,olap}', :'pgmb_par0' || $q$
with c as materialized (select kind, amount from g_child where amount > 100)
select kind, count(*), sum(amount) from c group by kind$q$ || :'pgmb_end', equiv => 'cte.par_rows_out');

------------------------------------------------------------------------------
-- Parallel Hash Join in the CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.par_hash_join_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
set local enable_nestloop = off;
set local enable_mergejoin = off;
with c as (select p.grp, count(*) as n, sum(ch.amount) as total from g_child ch join g_parent p on p.id = ch.parent_id group by p.grp)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end', equiv => 'cte.par_hash_join');

call pgmb.reg('cte.par_hash_join_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
set local enable_nestloop = off;
set local enable_mergejoin = off;
with c as materialized (select p.grp, count(*) as n, sum(ch.amount) as total from g_child ch join g_parent p on p.id = ch.parent_id group by p.grp)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end', equiv => 'cte.par_hash_join');

-- every worker builds its own hash table instead of sharing one
call pgmb.reg('cte.par_hash_join_private_hash_tables', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
set local enable_nestloop = off;
set local enable_mergejoin = off;
set local enable_parallel_hash = off;
with c as materialized (select p.grp, count(*) as n, sum(ch.amount) as total from g_child ch join g_parent p on p.id = ch.parent_id group by p.grp)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end', equiv => 'cte.par_hash_join');

call pgmb.reg('cte.par_hash_join_serial', '{perf,planning,analyze,consistency,olap}', :'pgmb_par0' || $q$
set local enable_nestloop = off;
set local enable_mergejoin = off;
with c as materialized (select p.grp, count(*) as n, sum(ch.amount) as total from g_child ch join g_parent p on p.id = ch.parent_id group by p.grp)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end', equiv => 'cte.par_hash_join');

-- the join is between two CTEs: inlined they join in the workers,
-- materialized each is gathered first and the join runs in the leader
call pgmb.reg('cte.par_join_of_two_ctes_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with ch as (select parent_id, amount from g_child where kind < 4),
     p as (select id, grp from g_parent where grp < 50)
select count(*), sum(ch.amount) from ch join p on p.id = ch.parent_id$q$ || :'pgmb_end', equiv => 'cte.par_two_ctes');

call pgmb.reg('cte.par_join_of_two_ctes_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with ch as materialized (select parent_id, amount from g_child where kind < 4),
     p as materialized (select id, grp from g_parent where grp < 50)
select count(*), sum(ch.amount) from ch join p on p.id = ch.parent_id$q$ || :'pgmb_end', equiv => 'cte.par_two_ctes');

------------------------------------------------------------------------------
-- Gather Merge: sorted output of a parallel plan
------------------------------------------------------------------------------
call pgmb.reg('cte.par_gather_merge_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as (select id, amount from g_child order by amount desc, id)
select count(*), sum(amount) from (select amount from c limit 1000) s$q$ || :'pgmb_end', equiv => 'cte.par_gather_merge');

call pgmb.reg('cte.par_gather_merge_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as materialized (select id, amount from g_child order by amount desc, id)
select count(*), sum(amount) from (select amount from c limit 1000) s$q$ || :'pgmb_end', equiv => 'cte.par_gather_merge');

call pgmb.reg('cte.par_gather_merge_serial', '{perf,planning,analyze,consistency,olap}', :'pgmb_par0' || $q$
with c as materialized (select id, amount from g_child order by amount desc, id)
select count(*), sum(amount) from (select amount from c limit 1000) s$q$ || :'pgmb_end', equiv => 'cte.par_gather_merge');

-- the whole sorted result is read: every row crosses the merge
call pgmb.reg('cte.par_gather_merge_full_read_materialized', '{perf,planning,analyze,olap}', :'pgmb_par2' || $q$
with c as materialized (select id, amount from g_child order by amount desc, id)
select count(*), sum(amount) from c$q$ || :'pgmb_end');

-- sorted groups: Gather Merge feeding a final GroupAggregate
call pgmb.reg('cte.par_gather_merge_group_aggregate', '{perf,planning,analyze,olap}', :'pgmb_par2' || $q$
set local enable_hashagg = off;
with c as materialized (select parent_id, count(*) as n, sum(amount) as total from g_child group by parent_id)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end');

------------------------------------------------------------------------------
-- Parallel Append: UNION ALL branches and partitions
------------------------------------------------------------------------------
call pgmb.reg('cte.par_append_union_all_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as (select k_100 as k from g_narrow union all select kind from g_child union all select cat from g_events)
select count(*), sum(k) from c$q$ || :'pgmb_end', equiv => 'cte.par_append');

call pgmb.reg('cte.par_append_union_all_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with c as materialized (select k_100 as k from g_narrow union all select kind from g_child union all select cat from g_events)
select count(*), sum(k) from c$q$ || :'pgmb_end', equiv => 'cte.par_append');

-- branches are still scanned in parallel, but one after another
call pgmb.reg('cte.par_append_union_all_no_parallel_append', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
set local enable_parallel_append = off;
with c as (select k_100 as k from g_narrow union all select kind from g_child union all select cat from g_events)
select count(*), sum(k) from c$q$ || :'pgmb_end', equiv => 'cte.par_append');

call pgmb.reg('cte.par_append_union_all_serial', '{perf,planning,analyze,consistency,olap}', :'pgmb_par0' || $q$
with c as (select k_100 as k from g_narrow union all select kind from g_child union all select cat from g_events)
select count(*), sum(k) from c$q$ || :'pgmb_end', equiv => 'cte.par_append');

-- three CTEs appended in the main query: inlined they are one Parallel Append
call pgmb.reg('cte.par_append_of_three_ctes_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with a as (select k_100 as k from g_narrow), b as (select kind as k from g_child), c as (select cat as k from g_events)
select count(*), sum(k) from (select k from a union all select k from b union all select k from c) u$q$ || :'pgmb_end', equiv => 'cte.par_append');

-- materialized they are three stores read one after another by the leader
call pgmb.reg('cte.par_append_of_three_ctes_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with a as materialized (select k_100 as k from g_narrow), b as materialized (select kind as k from g_child), c as materialized (select cat as k from g_events)
select count(*), sum(k) from (select k from a union all select k from b union all select k from c) u$q$ || :'pgmb_end', equiv => 'cte.par_append');

-- 16 partitions
call pgmb.reg('cte.par_append_partitions_inlined', '{perf,planning,analyze,consistency,olap,needs_data}', :'pgmb_par2' || $q$
with c as (select bucket, id from g_part where id % 3 = 0)
select count(*), sum(bucket) from c$q$ || :'pgmb_end', equiv => 'cte.par_partitions');

call pgmb.reg('cte.par_append_partitions_materialized', '{perf,planning,analyze,consistency,olap,needs_data}', :'pgmb_par2' || $q$
with c as materialized (select bucket, id from g_part where id % 3 = 0)
select count(*), sum(bucket) from c$q$ || :'pgmb_end', equiv => 'cte.par_partitions');

call pgmb.reg('cte.par_append_partitions_partitionwise_aggregate', '{perf,planning,analyze,consistency,olap,needs_data}', :'pgmb_par2' || $q$
set local enable_partitionwise_aggregate = on;
with c as materialized (select bucket, count(*) as n from g_part where id % 3 = 0 group by bucket)
select sum(n), sum(bucket * n) from c$q$ || :'pgmb_end', equiv => 'cte.par_partitions');

------------------------------------------------------------------------------
-- index paths: parallel index scan and parallel bitmap heap scan in the CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.par_index_scan_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
set local enable_seqscan = off;
set local enable_bitmapscan = off;
with c as materialized (select id, amount from g_child where id between :n_g_child / 4 and :n_g_child * 3 / 4)
select count(*), sum(amount) from c$q$ || :'pgmb_end', equiv => 'cte.par_index');

call pgmb.reg('cte.par_bitmap_heap_scan_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
set local enable_seqscan = off;
set local enable_indexscan = off;
with c as materialized (select id, amount from g_child where id between :n_g_child / 4 and :n_g_child * 3 / 4)
select count(*), sum(amount) from c$q$ || :'pgmb_end', equiv => 'cte.par_index');

call pgmb.reg('cte.par_index_range_serial', '{perf,planning,analyze,consistency,olap}', :'pgmb_par0' || $q$
with c as materialized (select id, amount from g_child where id between :n_g_child / 4 and :n_g_child * 3 / 4)
select count(*), sum(amount) from c$q$ || :'pgmb_end', equiv => 'cte.par_index');

------------------------------------------------------------------------------
-- the leader and the number of workers
------------------------------------------------------------------------------
-- the leader only collects: with few workers the CTE loses a third of its hands
call pgmb.reg('cte.par_leader_does_not_participate', '{perf,planning,analyze,olap}', :'pgmb_par2' || $q$
set local parallel_leader_participation = off;
with c as materialized (select kind, count(*) as n, sum(amount) as total from g_child group by kind)
select count(*), sum(n), sum(total) from c$q$ || :'pgmb_end');

select format($f$call pgmb.reg('cte.par_workers_%1$s', '{perf,planning,analyze,olap}', %2$L)$f$, n,
              format(E'begin;\nset local max_parallel_workers_per_gather = %s;\nset local min_parallel_table_scan_size = 0;\nset local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\nwith c as materialized (select kind, count(*) as n, sum(length(md5(note))) as l from g_child group by kind)\nselect count(*), sum(n), sum(l) from c;\ncommit;', n))
from (values (1), (2), (4), (8)) v(n) \gexec

-- workers are asked for but the table is declared to need none
call pgmb.reg('cte.par_workers_real_costs', '{perf,planning,analyze,olap}', $q$
with c as materialized (select kind, count(*) as n, sum(length(md5(note))) as l from g_child group by kind)
select count(*), sum(n), sum(l) from c$q$);

------------------------------------------------------------------------------
-- several Gathers in one statement
------------------------------------------------------------------------------
-- three materialized CTEs, each with its own Gather, run one after another:
-- the workers are started and stopped three times
call pgmb.reg('cte.par_three_gathers_in_three_ctes', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with a as materialized (select count(*) as n from g_narrow where k_100 < 50),
     b as materialized (select count(*) as n from g_child where kind < 4),
     c as materialized (select count(*) as n from g_events where cat < 3)
select a.n, b.n, c.n from a, b, c$q$ || :'pgmb_end', equiv => 'cte.par_three_gathers');

call pgmb.reg('cte.par_three_gathers_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with a as (select count(*) as n from g_narrow where k_100 < 50),
     b as (select count(*) as n from g_child where kind < 4),
     c as (select count(*) as n from g_events where cat < 3)
select a.n, b.n, c.n from a, b, c$q$ || :'pgmb_end', equiv => 'cte.par_three_gathers');

call pgmb.reg('cte.par_three_gathers_serial', '{perf,planning,analyze,consistency,olap}', :'pgmb_par0' || $q$
with a as materialized (select count(*) as n from g_narrow where k_100 < 50),
     b as materialized (select count(*) as n from g_child where kind < 4),
     c as materialized (select count(*) as n from g_events where cat < 3)
select a.n, b.n, c.n from a, b, c$q$ || :'pgmb_end', equiv => 'cte.par_three_gathers');

-- a Gather in the CTE and another in the main query
call pgmb.reg('cte.par_gather_in_cte_and_in_main_query', '{perf,planning,analyze,olap}', :'pgmb_par2' || $q$
with c as materialized (select kind, sum(amount) as total from g_child group by kind)
select e.cat, count(*), (select sum(total) from c) from g_events e group by e.cat order by e.cat$q$ || :'pgmb_end');

------------------------------------------------------------------------------
-- the CTE Scan itself: restricted, so it shapes the plan above it
------------------------------------------------------------------------------
-- a small CTE joined to a large table: inlined, the join and the aggregate run
-- in the workers; materialized, the CTE Scan stays in the leader and the large
-- table is gathered row by row to meet it
call pgmb.reg('cte.par_cte_scan_joined_to_parallel_scan_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with wanted as (select id from g_parent where grp < 10)
select count(*), sum(ch.amount) from g_child ch join wanted w on w.id = ch.parent_id$q$ || :'pgmb_end', equiv => 'cte.par_cte_scan_join');

call pgmb.reg('cte.par_cte_scan_joined_to_parallel_scan_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with wanted as materialized (select id from g_parent where grp < 10)
select count(*), sum(ch.amount) from g_child ch join wanted w on w.id = ch.parent_id$q$ || :'pgmb_end', equiv => 'cte.par_cte_scan_join');

-- the CTE result as a scalar: an initplan value can be sent to the workers
call pgmb.reg('cte.par_cte_as_scalar_parameter_materialized', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with lim as materialized (select avg(amount) as a from g_child where kind = 0)
select count(*), sum(amount) from g_child where amount > (select a from lim)$q$ || :'pgmb_end', equiv => 'cte.par_scalar');

call pgmb.reg('cte.par_cte_as_scalar_parameter_inlined', '{perf,planning,analyze,consistency,olap}', :'pgmb_par2' || $q$
with lim as (select avg(amount) as a from g_child where kind = 0)
select count(*), sum(amount) from g_child where amount > (select a from lim)$q$ || :'pgmb_end', equiv => 'cte.par_scalar');

-- a recursive CTE runs in the leader; only what it reads can be parallel
call pgmb.reg('cte.par_recursive_over_parallel_scan', '{perf,planning,analyze,olap}', :'pgmb_par2' || $q$
with recursive r(lvl, n) as (
    select 0, count(*) from g_child where kind = 0
    union all
    select lvl + 1, (select count(*) from g_child where kind = r.lvl + 1) from r where lvl < 6)
select count(*), sum(n) from r$q$ || :'pgmb_end');

-- early stop above a Gather: the workers are shut down with work left
call pgmb.reg('cte.par_limit_above_gather_inlined', '{perf,planning,analyze,oltp}', :'pgmb_par2' || $q$
with c as (select id, amount from g_child where amount > 100)
select count(*) from (select id from c limit 100) s$q$ || :'pgmb_end');

call pgmb.reg('cte.par_limit_above_gather_materialized', '{perf,planning,analyze,oltp}', :'pgmb_par2' || $q$
with c as materialized (select id, amount from g_child where amount > 100)
select count(*) from (select id from c limit 100) s$q$ || :'pgmb_end');

-- a window function over a parallel CTE: gathered, then sorted in the leader
call pgmb.reg('cte.par_window_above_gather', '{perf,planning,analyze,olap}', :'pgmb_par2' || $q$
with c as materialized (select parent_id, amount from g_child where kind < 2)
select count(*), max(r) from (select rank() over (partition by parent_id order by amount) as r from c) s$q$ || :'pgmb_end');
