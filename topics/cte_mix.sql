-- Topic: cte (part 10) - interacting areas.
-- Each block combines features whose behaviour changes when they meet.

------------------------------------------------------------------------------
-- VOLATILE x several readers x LIMIT: lazily filled, but filled only once
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_random_limit_then_full', '{perf,planning}', $q$
with r as (select i, random() as x from generate_series(1, 50000) i)
select (select x from r limit 1) as first_x, (select count(*) from r) as n, (select x from r limit 1) as first_again$q$);

call pgmb.reg('cte.mix_random_exists_then_join', '{perf,planning}', $q$
with r as (select i, random() as x from generate_series(1, 20000) i)
select exists (select 1 from r where x >= 0) as any_row,
       (select count(*) from r a join r b using (i) where a.x = b.x) as agree$q$);

call pgmb.reg('cte.mix_random_not_materialized_ignored_two_readers', '{perf,planning}', $q$
with r as not materialized (select i, random() as x from generate_series(1, 20000) i)
select (select count(*) from r a join r b using (i) where a.x = b.x) as agree$q$);

------------------------------------------------------------------------------
-- nextval() x laziness: the reader decides how many values are consumed
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_nextval_exists_takes_one', '{perf,planning,oltp}', $q$
with s as (select nextval('g_cte_seq') as v from g_parent)
select exists (select 1 from s)$q$,
    kind => 'write');

call pgmb.reg('cte.mix_nextval_offset_takes_prefix', '{perf,planning,oltp}', $q$
with s as (select nextval('g_cte_seq') as v from g_parent)
select v from s offset 50 limit 1$q$,
    kind => 'write');

call pgmb.reg('cte.mix_nextval_sort_takes_all', '{perf,planning}', $q$
with s as (select nextval('g_cte_seq') as v from g_parent where id between :id and :id + 999)
select v from s order by v desc limit 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.mix_nextval_in_untaken_case_branch', '{perf,planning,oltp}', $q$
with s as (select nextval('g_cte_seq') as v)
select p.id, case when p.grp < 0 then (select v from s) end from g_parent p where p.id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- partition pruning x materialization x STABLE x join pushdown
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_partition_stable_two_readers_inlined', '{perf,planning}', $q$
with c as not materialized (select id, bucket, val from g_part)
select (select count(*) from c where bucket = noop_plpgsql_stable(:b)),
       (select max(val) from c where bucket = noop_plpgsql_stable((:b + 3) % 16))$q$,
    setup => '\set b random(0, 15)');

call pgmb.reg('cte.mix_partition_keys_from_recursive', '{perf,planning}', $q$
with recursive k(bucket, n) as (select :b, 1 union all select (bucket + 5) % 16, n + 1 from k where n < 3)
select k.bucket, count(*) from k join g_part p on p.bucket = k.bucket and p.id between :id and :id + 5000
group by k.bucket$q$,
    setup => E'\\set b random(0, 15)\n\\set id random(1, :n_g_part)');

call pgmb.reg('cte.mix_partition_aggregate_cte_join_key', '{perf,planning}', $q$
with totals as (select bucket, count(*) as n, avg(val) as av from g_part group by bucket)
select d.id, t.n, t.av from g_dim d join totals t on t.bucket = d.category where d.id = :d$q$,
    setup => '\set d random(1, :n_g_dim)');

call pgmb.reg('cte.mix_partition_materialized_limit', '{perf,planning,oltp}', $q$
with c as materialized (select id, bucket, val from g_part)
select * from c limit 10$q$);

call pgmb.reg('cte.mix_partition_union_all_of_cte_branches', '{perf,planning}', $q$
with a as (select id, bucket, val from g_part where bucket = :b),
     b as (select id, bucket, val from g_part where bucket = (:b + 1) % 16),
     u as (select * from a union all select * from b)
select count(*), sum(val) from u where id between :id and :id + 20000 and bucket = :b$q$,
    setup => E'\\set b random(0, 15)\n\\set id random(1, :n_g_part)');

------------------------------------------------------------------------------
-- recursion x SEARCH/CYCLE x outer LIMIT/ORDER BY: lazy or not
------------------------------------------------------------------------------
-- ORDER BY on the search column needs the complete result before the first row
call pgmb.reg('cte.mix_rec_search_order_limit', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id from g_tree where id = :id
    union all
    select t.id, t.parent_id from g_tree t join sub s on t.parent_id = s.id)
search breadth first by id set ord
select id from sub order by ord limit 10$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

-- no ORDER BY: the same LIMIT stops the recursion early
call pgmb.reg('cte.mix_rec_search_limit_no_order', '{perf,planning,oltp}', $q$
with recursive sub as (
    select id, parent_id from g_tree where id = :id
    union all
    select t.id, t.parent_id from g_tree t join sub s on t.parent_id = s.id)
search breadth first by id set ord
select id from sub limit 10$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

call pgmb.reg('cte.mix_rec_cycle_limit_lazy', '{perf,planning,oltp}', $q$
with recursive w(node) as (
    select :id::bigint
    union all
    select g.dst from g_graph g join w on g.src = w.node)
cycle node set is_cycle using path
select node, is_cycle from w limit 50$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.mix_rec_union_exists_stops', '{perf,planning,oltp}', $q$
with recursive r(node) as (
    select :id::bigint
    union
    select g.dst from g_graph g join r on g.src = r.node)
select exists (select 1 from r where node <> :id)$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.mix_rec_two_readers_limit_and_count', '{perf,planning}', $q$
with recursive sub as (
    select id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 5)
select (select id from sub limit 1), (select count(*) from sub)$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

-- a filter outside a recursive CTE is never pushed in; the hand-pushed form must agree
call pgmb.reg('cte.mix_rec_filter_outside', '{perf,planning,consistency}', $q$
with recursive sub as (
    select id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 5)
select id from sub where lvl <= 2$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)', equiv => 'cte.mix_rec_filter');

call pgmb.reg('cte.mix_rec_filter_inside', '{perf,planning,consistency}', $q$
with recursive sub as (
    select id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 2)
select id from sub$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)', equiv => 'cte.mix_rec_filter');

------------------------------------------------------------------------------
-- wide rows x temp files x readers: what a spill costs, and when it never happens
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_wide_spill_two_readers', '{perf}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select * from g_wide where id between :id and :id + 5000)
select (select count(*) from c), (select max(t3) from c);
commit;$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('cte.mix_wide_memory_two_readers', '{perf}', $q$
begin;
set local work_mem = '256MB';
with c as materialized (select * from g_wide where id between :id and :id + 5000)
select (select count(*) from c), (select max(t3) from c);
commit;$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('cte.mix_wide_spill_avoided_by_limit', '{perf}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select * from g_wide where id between :id and :id + 5000)
select * from c limit 1;
commit;$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('cte.mix_wide_spill_avoided_by_projection', '{perf}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select id from g_wide where id between :id and :id + 5000)
select (select count(*) from c), (select max(id) from c);
commit;$q$,
    setup => '\set id random(1, :n_g_wide)');

------------------------------------------------------------------------------
-- parallelism x materialization x aggregation x join
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_parallel_join_inlined', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with e as (select entity_id, val from g_events where val > 500),
     n as (select id, k_100 from g_narrow)
select n.k_100, count(*), avg(e.val) from e join n on n.id = e.entity_id group by n.k_100;
commit;$q$);

call pgmb.reg('cte.mix_parallel_join_one_side_materialized', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with e as materialized (select entity_id, val from g_events where val > 500),
     n as (select id, k_100 from g_narrow)
select n.k_100, count(*), avg(e.val) from e join n on n.id = e.entity_id group by n.k_100;
commit;$q$);

call pgmb.reg('cte.mix_parallel_recursive_base_scan', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with recursive r(id, hops) as (
    select id, 0 from g_tree where val = 7
    union all
    select t.parent_id, r.hops + 1 from g_tree t join r on t.id = r.id where t.parent_id is not null and r.hops < 3)
select hops, count(*) from r group by hops;
commit;$q$);

------------------------------------------------------------------------------
-- a raising function x laziness x EXISTS / CASE
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_error_behind_exists', '{perf,planning,oltp}', $q$
with c as (select id, raise_if(id > 50) as r from g_parent where id <= 100)
select exists (select 1 from c)$q$);

call pgmb.reg('cte.mix_error_in_untaken_case_branch', '{perf,planning,oltp}', $q$
with boom as (select raise_if(true) as r)
select p.id, case when p.grp < 0 then (select r from boom) else 0 end from g_parent p where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.mix_error_unreferenced_inside_referenced', '{perf,planning,oltp}', $q$
with outer_cte as (
    with boom as (select raise_if(true) as r)
    select id, val from g_parent where id = :id)
select * from outer_cte$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- ORDER BY inside the CTE x outer LIMIT x materialization
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_sorted_by_index_outer_limit_inlined', '{perf,planning,consistency,oltp}', $q$
with c as (select id, pad from g_narrow where id >= :id order by id)
select * from c limit 20$q$,
    setup => '\set id random(1, :n_g_narrow / 2)', equiv => 'cte.mix_sorted_limit');

call pgmb.reg('cte.mix_sorted_by_index_outer_limit_materialized', '{perf,planning,consistency,oltp}', $q$
with c as materialized (select id, pad from g_narrow where id >= :id order by id)
select * from c limit 20$q$,
    setup => '\set id random(1, :n_g_narrow / 2)', equiv => 'cte.mix_sorted_limit');

call pgmb.reg('cte.mix_sorted_by_expression_outer_limit', '{perf,planning,consistency,olap}', $q$
with c as materialized (select id, pad from g_narrow where id >= :id order by id + 0)
select * from c limit 20$q$,
    setup => '\set id random(1, :n_g_narrow / 2)', equiv => 'cte.mix_sorted_limit');

------------------------------------------------------------------------------
-- window / DISTINCT inside the CTE x join key from outside
------------------------------------------------------------------------------
-- the join key cannot be pushed into a windowed CTE; LATERAL does it by hand
call pgmb.reg('cte.mix_window_cte_joined_on_partition_key', '{perf,planning,consistency,olap}', $q$
with ranked as (select entity_id, id, val, row_number() over (partition by entity_id order by val desc, id) as rn from g_events)
select d.id, r.id as event_id, r.val from g_dim d join ranked r on r.entity_id = d.id where d.id = :d and r.rn <= 3$q$,
    setup => '\set d random(1, 10)', equiv => 'cte.mix_window_join');

call pgmb.reg('cte.mix_window_lateral_by_hand', '{perf,planning,consistency,oltp}', $q$
select d.id, r.id as event_id, r.val
from g_dim d,
     lateral (select id, val from g_events e where e.entity_id = d.id order by val desc, id limit 3) r
where d.id = :d$q$,
    setup => '\set d random(1, 10)', equiv => 'cte.mix_window_join');

call pgmb.reg('cte.mix_distinct_cte_joined', '{perf,planning,oltp}', $q$
with kinds as (select distinct parent_id, kind from g_child)
select p.id, count(*) from g_parent p join kinds k on k.parent_id = p.id where p.id between :id and :id + 20 group by p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- mixed MATERIALIZED chain x projection x expensive expressions
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_chain_fence_first', '{perf,planning,consistency}', $q$
with a as materialized (select id, k_100, md5(md5(pad)) as h from g_narrow where id between :id and :id + 3000),
     b as not materialized (select id, k_100 from a where k_100 < 50),
     c as (select k_100, count(*) as n from b group by k_100)
select count(*), sum(n) from c$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.mix_chain');

call pgmb.reg('cte.mix_chain_fence_last', '{perf,planning,consistency}', $q$
with a as not materialized (select id, k_100, md5(md5(pad)) as h from g_narrow where id between :id and :id + 3000),
     b as not materialized (select id, k_100 from a where k_100 < 50),
     c as materialized (select k_100, count(*) as n from b group by k_100)
select count(*), sum(n) from c$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.mix_chain');

call pgmb.reg('cte.mix_chain_no_fence', '{perf,planning,consistency}', $q$
with a as (select id, k_100, md5(md5(pad)) as h from g_narrow where id between :id and :id + 3000),
     b as (select id, k_100 from a where k_100 < 50),
     c as (select k_100, count(*) as n from b group by k_100)
select count(*), sum(n) from c$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.mix_chain');

------------------------------------------------------------------------------
-- data-modifying CTE x snapshot: readers in the same statement see the old rows
------------------------------------------------------------------------------
call pgmb.reg('cte.mix_dml_snapshot_old_and_new', '{perf,planning,oltp}', $q$
with u as (update g_parent set val = val + 1 where id = :id returning val)
select (select val from g_parent where id = :id) as seen_by_select, (select val from u) as returned$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.mix_dml_insert_not_visible_to_sibling', '{perf,planning,oltp}', $q$
with ins as (insert into g_child (parent_id, seq, kind, amount, ts, note)
             values (:id, 0, 0, 1.00, now(), 'mix') returning id),
     seen as (select count(*) as n from g_child where id in (select id from ins))
select (select count(*) from ins) as inserted, (select n from seen) as visible$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.mix_dml_limit_does_not_cut_writer', '{perf,planning,oltp}', $q$
with u as (update g_parent set val = val + 1 where id between :id and :id + 9 returning id)
select id from u limit 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');
