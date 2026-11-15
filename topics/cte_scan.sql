-- Topic: cte (part 3) - how a CTE is read.
--   scan_*   : the CTE body uses a particular access path
--   reader_* : one CTE consumed by different kinds of readers, or by many

------------------------------------------------------------------------------
-- access paths inside the CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.scan_seq_whole_table', '{perf,planning,olap}', $q$
with c as (select k_100, k_10k from g_narrow)
select k_100, count(*), max(k_10k) from c group by k_100$q$);

call pgmb.reg('cte.scan_index_range', '{perf,planning,oltp}', $q$
with c as (select id, k_100, pad from g_narrow where id between :id and :id + 200)
select count(*), min(pad) from c$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.scan_index_only', '{perf,planning,oltp}', $q$
with c as (select k_10k, k_100 from g_narrow where k_10k between :b and :b + 20)
select k_100, count(*) from c group by k_100$q$,
    setup => '\set b random(0, 9979)');

call pgmb.reg('cte.scan_index_ordered_limit', '{perf,planning,oltp}', $q$
with c as (select id, k_10k from g_narrow where k_100 = :k order by k_10k limit 50)
select count(*), max(k_10k) from c$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('cte.scan_index_backward', '{perf,planning,oltp}', $q$
with c as (select id, k_uniq from g_narrow where id < :id order by id desc limit 50)
select min(id), max(id) from c$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.scan_index_min_max', '{perf,planning,oltp}', $q$
with c as (select min(id) as lo, max(id) as hi from g_narrow where id > :id)
select hi - lo from c$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.scan_bitmap_or', '{perf,planning}', $q$
with c as (select id, k_10k, k_uniq from g_narrow where k_10k = :b or k_uniq between :id and :id + 50)
select count(*) from c$q$,
    setup => E'\\set b random(0, 9999)\n\\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.scan_bitmap_and', '{perf,planning}', $q$
with c as (select id from g_narrow where k_10k between :b and :b + 300 and (k_uniq % 1000) = :m)
select count(*) from c$q$,
    setup => E'\\set b random(0, 9699)\n\\set m random(0, 999)');

call pgmb.reg('cte.scan_brin', '{perf,planning}', $q$
with c as (select id, k_corr from g_narrow where k_corr between :c and :c + 200)
select count(*), max(id) from c$q$,
    setup => '\set c random(0, :n_g_narrow / 10)');

call pgmb.reg('cte.scan_gin_array', '{perf,planning,oltp}', $q$
with c as (select id, a_small from g_array where a_small @> array[:v])
select count(*), max(cardinality(a_small)) from c$q$,
    setup => '\set v random(0, 999)');

call pgmb.reg('cte.scan_hash_index', '{perf,planning,oltp}', $q$
with c as (select id, i6, t1 from g_wide where i6 = :v)
select * from c$q$,
    setup => '\set v random(0, 99999)');

call pgmb.reg('cte.scan_skip_scan', '{perf,planning}', $q$
with c as (select i3, i4, i5 from g_wide where i4 = :a)
select count(*), count(distinct i3) from c$q$,
    setup => '\set a random(0, 999)');

call pgmb.reg('cte.scan_partial_index', '{perf,planning}', $q$
with c as (select id from g_narrow where k_skew = :s and k_null is not null)
select count(*) from c$q$,
    setup => '\set s random(100, 999)');

call pgmb.reg('cte.scan_expression_index', '{perf,planning}', $q$
with c as (select id, k_uniq from g_narrow where (k_uniq % 1000) = :m)
select count(*), min(k_uniq) from c$q$,
    setup => '\set m random(0, 999)');

call pgmb.reg('cte.scan_like_prefix', '{perf,planning}', $q$
with c as (select id, pad from g_narrow where pad like :p::text || '%')
select count(*), min(pad) from c$q$,
    setup => '\set p random(100, 999)');

call pgmb.reg('cte.scan_function', '{perf,planning}', $q$
with c as (select i, i * i as sq from generate_series(1, 5000) i)
select count(*), sum(sq) from c where i % 7 = 0$q$);

call pgmb.reg('cte.scan_values', '{perf,planning,oltp}', $q$
with c(k, v) as (values (1, 'a'), (2, 'b'), (3, 'c'), (4, 'd'), (5, 'e'), (6, 'f'), (7, 'g'), (8, 'h'))
select string_agg(v, '' order by k) from c where k % 2 = :m$q$,
    setup => '\set m random(0, 1)');

call pgmb.reg('cte.scan_unnest_parameter', '{perf,planning,oltp}', $q$
with ids as (select unnest(array[:a, :a + 3, :a + 9, :a + 27, :a + 81]::bigint[]) as id)
select p.id, p.val from ids join g_parent p using (id)$q$,
    setup => '\set a random(1, :n_g_parent)');

call pgmb.reg('cte.scan_subquery_layers', '{perf,planning,oltp}', $q$
with c as (select * from (select * from (select id, grp, val from g_parent offset 0) a where grp = :g) b)
select count(*), sum(val) from c$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('cte.scan_union_all_mixed_paths', '{perf,planning}', $q$
with c as (select id, 'pk' as src from g_narrow where id between :id and :id + 50
           union all
           select id, 'idx' from g_narrow where k_10k = :b
           union all
           select i, 'gen' from generate_series(1, 20) i
           union all
           values (0::bigint, 'val'))
select src, count(*) from c group by src$q$,
    setup => E'\\set id random(1, :n_g_narrow)\n\\set b random(0, 9999)');

call pgmb.reg('cte.scan_distinct_on_index', '{perf,planning}', $q$
with c as (select distinct on (k_100) k_100, k_10k, id from g_narrow where k_100 < 20 order by k_100, k_10k)
select count(*), sum(k_10k) from c$q$);

call pgmb.reg('cte.scan_group_by_whole_table', '{perf,planning,olap}', $q$
with c as (select entity_id, count(*) as n, avg(val) as av from g_events group by entity_id)
select count(*), max(n), avg(av) from c$q$);

call pgmb.reg('cte.scan_every_path_joined', '{perf,planning}', $q$
with pk as (select id, k_100 from g_narrow where id between :id and :id + 300),
     ix as (select id from g_narrow where k_10k between :b and :b + 100),
     gin as (select id from g_array where a_small @> array[:v]),
     seq as (select id, category from g_dim),
     fn as (select i as id from generate_series(:id, :id + 300, 3) i)
select count(*) as n, count(ix.id) as via_index, count(gin.id) as via_gin, count(fn.id) as via_function,
       count(distinct seq.category) as categories
from pk
left join ix using (id)
left join gin using (id)
left join fn using (id)
left join seq on seq.id = pk.k_100 % 10 + 1$q$,
    setup => E'\\set id random(1, :n_g_narrow)\n\\set b random(0, 9899)\n\\set v random(0, 999)');

------------------------------------------------------------------------------
-- kinds of readers over one materialized CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.reader_aggregate', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp between :g and :g + 4)
select grp, count(*), sum(val) from c group by grp$q$,
    setup => '\set g random(0, 95)');

call pgmb.reg('cte.reader_limit_stops_early', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp between :g and :g + 4)
select * from c limit 5$q$,
    setup => '\set g random(0, 95)');

call pgmb.reg('cte.reader_sort', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp between :g and :g + 4)
select id, val from c order by val desc, id limit 20$q$,
    setup => '\set g random(0, 95)');

call pgmb.reg('cte.reader_exists', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp between :g and :g + 4)
select exists (select 1 from c where val > 9000), exists (select 1 from c where val < 0)$q$,
    setup => '\set g random(0, 95)');

call pgmb.reg('cte.reader_scalar_subqueries', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp between :g and :g + 4)
select (select count(*) from c), (select avg(val) from c), (select max(id) from c)$q$,
    setup => '\set g random(0, 95)');

call pgmb.reg('cte.reader_window', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp between :g and :g + 4)
select id, rank() over (partition by grp order by val desc), val - avg(val) over (partition by grp) from c$q$,
    setup => '\set g random(0, 95)');

call pgmb.reg('cte.reader_self_join', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp between :g and :g + 1)
select count(*) from c a join c b on a.grp = b.grp and a.val < b.val$q$,
    setup => '\set g random(0, 98)');

call pgmb.reg('cte.reader_in_list_source', '{perf,planning}', $q$
with c as materialized (select id from g_parent where grp = :g)
select count(*), sum(amount) from g_child where parent_id in (select id from c)$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('cte.reader_correlated_per_row', '{perf,planning}', $q$
with c as materialized (select parent_id, amount from g_child where parent_id between :id and :id + 20)
select p.id, (select sum(amount) from c where c.parent_id = p.id) as total
from g_parent p where p.id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- many readers
------------------------------------------------------------------------------
call pgmb.reg('cte.reader_3_different_filters', '{perf,planning}', $q$
with c as (select id, k_100, k_10k, k_null from g_narrow where id between :id and :id + 1000)
select (select count(*) from c where k_100 < 10) as low,
       (select count(*) from c where k_10k > 9000) as high,
       (select count(*) from c where k_null is null) as nulls$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.reader_5_union_branches', '{perf,planning}', $q$
with c as (select id, kind, amount from g_child where parent_id between :id and :id + 30)
select 'all' as what, count(*), sum(amount) from c
union all select 'kind0', count(*), sum(amount) from c where kind = 0
union all select 'kind1', count(*), sum(amount) from c where kind = 1
union all select 'big', count(*), sum(amount) from c where amount > 900
union all select 'small', count(*), sum(amount) from c where amount < 100$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.reader_10_scalar_subqueries', '{perf,planning}', $q$
with c as (select entity_id, cat, val from g_events where entity_id between :e and :e + 4)
select (select count(*) from c), (select min(val) from c), (select max(val) from c), (select avg(val) from c),
       (select count(*) from c where cat = 0), (select count(*) from c where cat = 1),
       (select count(*) from c where cat = 2), (select count(*) from c where cat = 3),
       (select count(*) from c where cat = 4), (select count(distinct entity_id) from c)$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('cte.reader_fan_out_3_levels', '{perf,planning}', $q$
with l0 as (select id, grp, val from g_parent where id between :id and :id + 200),
     l1a as (select grp, sum(val) as s from l0 group by grp),
     l1b as (select grp, count(*) as n from l0 group by grp),
     l2a as (select a.grp, a.s / b.n as av from l1a a join l1b b using (grp)),
     l2b as (select max(s) as top from l1a),
     l2c as (select max(n) as most from l1b)
select count(*), max(av), (select top from l2b), (select most from l2c) from l2a$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.reader_recursive_reads_plain', '{perf,planning}', $q$
with recursive edges as (select src, dst from g_graph where src between :id and :id + 200),
     walk(node, depth) as (
        select :id::bigint, 0
        union all
        select e.dst, w.depth + 1 from edges e join walk w on e.src = w.node where w.depth < 4)
select count(*), max(depth), (select count(*) from edges) from walk$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.reader_two_recursive', '{perf,planning}', $q$
with recursive down as (
        select id, 0 as lvl from g_tree where id = :id
        union all
        select t.id, d.lvl + 1 from g_tree t join down d on t.parent_id = d.id where d.lvl < 2),
     up as (
        select id, parent_id from g_tree where id = :id
        union all
        select t.id, t.parent_id from g_tree t join up u on t.id = u.parent_id)
select (select count(*) from down) as descendants, (select count(*) from up) as ancestors$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.reader_main_update', '{perf,planning,oltp}', $q$
with hot as (select id from g_parent where id between :id and :id + 2)
update g_parent p set val = p.val + 1 from hot where p.id = hot.id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.reader_main_delete_and_select', '{perf,planning,oltp}', $q$
with victim as (select id from g_child where parent_id = :id and note = 'cte' limit 5),
     gone as (delete from g_child where id in (select id from victim) returning id)
select (select count(*) from victim) as chosen, (select count(*) from gone) as deleted$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- default / MATERIALIZED / NOT MATERIALIZED with three readers must agree
call pgmb.reg('cte.reader_3_default', '{perf,planning,consistency}', $q$
with c as (select parent_id, kind, amount from g_child where parent_id between :id and :id + 40)
select a.kind, a.n, b.total, (select max(amount) from c) as mx
from (select kind, count(*) as n from c group by kind) a
join (select kind, sum(amount) as total from c group by kind) b using (kind)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.reader_3');

call pgmb.reg('cte.reader_3_materialized', '{perf,planning,consistency}', $q$
with c as materialized (select parent_id, kind, amount from g_child where parent_id between :id and :id + 40)
select a.kind, a.n, b.total, (select max(amount) from c) as mx
from (select kind, count(*) as n from c group by kind) a
join (select kind, sum(amount) as total from c group by kind) b using (kind)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.reader_3');

call pgmb.reg('cte.reader_3_not_materialized', '{perf,planning,consistency}', $q$
with c as not materialized (select parent_id, kind, amount from g_child where parent_id between :id and :id + 40)
select a.kind, a.n, b.total, (select max(amount) from c) as mx
from (select kind, count(*) as n from c group by kind) a
join (select kind, sum(amount) as total from c group by kind) b using (kind)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.reader_3');
