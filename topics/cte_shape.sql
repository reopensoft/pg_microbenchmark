-- Topic: cte (part 5)
--   prune_*  : parts of a CTE that the query does not need - are they skipped?
--   nested_* : WITH inside WITH, inside subqueries, at several depths

------------------------------------------------------------------------------
-- pruning: whole CTEs
------------------------------------------------------------------------------
call pgmb.reg('cte.prune_unreferenced_heavy', '{perf,planning,oltp}', $q$
with big_sort as (select * from g_narrow order by pad),
     big_agg as (select entity_id, count(*), avg(val) from g_events group by entity_id),
     big_join as (select c.id from g_child c join g_parent p on p.id = c.parent_id),
     rec as (with recursive r(n) as (select 1 union all select n + 1 from r where n < 100000) select count(*) from r)
select id, val from g_parent where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.prune_unreferenced_chain', '{perf,planning,oltp}', $q$
with a as (select * from g_child),
     b as (select parent_id, sum(amount) as s from a group by parent_id),
     c as (select * from b where s > 0),
     d as (select count(*) from c)
select id, val from g_parent where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.prune_unreferenced_materialized', '{perf,planning,oltp}', $q$
with unused as materialized (select * from g_narrow order by pad)
select id, val from g_parent where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

-- a data-modifying CTE runs even when nothing reads it
call pgmb.reg('cte.prune_unreferenced_writer_runs', '{perf,planning,oltp}', $q$
with touch as (update g_parent set updated_at = now() where id = :id)
select 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- referenced, but the reader can never produce a row
call pgmb.reg('cte.prune_reader_where_false', '{perf,planning,oltp}', $q$
with c as (select parent_id, sum(amount) as s from g_child group by parent_id)
select * from c where false$q$);

call pgmb.reg('cte.prune_reader_limit_zero', '{perf,planning,oltp}', $q$
with c as (select parent_id, sum(amount) as s from g_child group by parent_id)
select * from c limit 0$q$);

call pgmb.reg('cte.prune_reader_limit_zero_materialized', '{perf,planning,oltp}', $q$
with c as materialized (select parent_id, sum(amount) as s from g_child group by parent_id)
select * from c limit 0$q$);

-- a materialized CTE is filled lazily: EXISTS and LIMIT read only what they need
call pgmb.reg('cte.prune_exists_reads_one_row', '{perf,planning,oltp}', $q$
with c as materialized (select id, pad from g_narrow where k_100 = :k)
select exists (select 1 from c)$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('cte.prune_limit_reads_prefix', '{perf,planning,oltp}', $q$
with c as materialized (select id, pad from g_narrow where k_100 = :k)
select * from c limit 3$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('cte.prune_exists_blocked_by_sort', '{perf,planning}', $q$
with c as materialized (select id, pad from g_narrow where k_100 = :k order by pad)
select exists (select 1 from c)$q$,
    setup => '\set k random(0, 99)');

------------------------------------------------------------------------------
-- pruning: columns, joins, aggregates and branches inside a CTE
------------------------------------------------------------------------------
-- expensive columns the reader ignores: dropped when inlined, computed when materialized
call pgmb.reg('cte.prune_unused_columns_inlined', '{perf,planning,consistency}', $q$
with c as (select id, md5(pad) as h1, md5(md5(pad)) as h2, repeat(pad, 50) as big, k_100
           from g_narrow where id between :id and :id + 2000)
select count(*), sum(k_100) from c$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.prune_columns');

call pgmb.reg('cte.prune_unused_columns_materialized', '{perf,planning,consistency}', $q$
with c as materialized (select id, md5(pad) as h1, md5(md5(pad)) as h2, repeat(pad, 50) as big, k_100
                        from g_narrow where id between :id and :id + 2000)
select count(*), sum(k_100) from c$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.prune_columns');

call pgmb.reg('cte.prune_unused_columns_two_readers', '{perf,planning,consistency}', $q$
with c as (select id, md5(pad) as h1, md5(md5(pad)) as h2, repeat(pad, 50) as big, k_100
           from g_narrow where id between :id and :id + 2000)
select (select count(*) from c), (select sum(k_100) from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.prune_columns');

-- a join inside the CTE whose columns nobody reads
call pgmb.reg('cte.prune_unused_left_join', '{perf,planning,oltp}', $q$
with c as (select p.id, p.val, d.code, d.name, t.depth
           from g_parent p
           left join g_dim d on d.id = p.dim_id
           left join g_tree t on t.id = p.id)
select id, val from c where id between :id and :id + 50$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.prune_unused_left_join_materialized', '{perf,planning}', $q$
with c as materialized (select p.id, p.val, d.code, d.name, t.depth
                        from g_parent p
                        left join g_dim d on d.id = p.dim_id
                        left join g_tree t on t.id = p.id
                        where p.id between :id and :id + 50)
select id, val from c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.prune_unused_inner_join_kept', '{perf,planning,oltp}', $q$
with c as (select p.id, p.val, d.code from g_parent p join g_dim d on d.id = p.dim_id)
select id, val from c where id between :id and :id + 50$q$,
    setup => '\set id random(1, :n_g_parent)');

-- aggregates, window functions and sorts the reader ignores
call pgmb.reg('cte.prune_unused_aggregates', '{perf,planning}', $q$
with c as (select parent_id, count(*) as n, sum(amount) as total, array_agg(id order by amount) as ids,
                  string_agg(note, ',' order by note) as notes, count(distinct kind) as kinds
           from g_child where parent_id between :id and :id + 300 group by parent_id)
select parent_id, n from c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.prune_unused_window_column', '{perf,planning}', $q$
with c as (select id, entity_id, val,
                  rank() over (partition by entity_id order by val) as r,
                  sum(val) over (partition by entity_id order by ts) as running
           from g_events where entity_id between :e and :e + 19)
select count(*), sum(val) from c$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('cte.prune_unused_order_by', '{perf,planning}', $q$
with c as (select id, pad, k_100 from g_narrow where id between :id and :id + 5000 order by pad)
select count(*), sum(k_100) from c$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.prune_unused_distinct', '{perf,planning}', $q$
with c as (select distinct parent_id, kind from g_child where parent_id between :id and :id + 300)
select exists (select 1 from c where kind = 3)$q$,
    setup => '\set id random(1, :n_g_parent)');

-- a UNION ALL branch excluded by a constant
call pgmb.reg('cte.prune_union_branch_by_constant', '{perf,planning,oltp}', $q$
with c as (select 'parent' as src, id, val as amount from g_parent
           union all
           select 'child', id, amount from g_child
           union all
           select 'event', id, val::numeric from g_events)
select * from c where src = 'parent' and id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.prune_union_branch_contradiction', '{perf,planning,oltp}', $q$
with c as (select id, grp from g_parent where grp < 50
           union all
           select id, grp from g_parent where grp >= 50)
select count(*) from c where grp = :g and grp < 50$q$,
    setup => '\set g random(0, 49)');

-- the same CTE text twice is planned and executed twice
call pgmb.reg('cte.prune_duplicate_definitions', '{perf,planning}', $q$
with a as (select parent_id, sum(amount) as s from g_child where parent_id between :id and :id + 100 group by parent_id),
     b as (select parent_id, sum(amount) as s from g_child where parent_id between :id and :id + 100 group by parent_id)
select count(*) from a join b using (parent_id, s)$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- nesting: depth
------------------------------------------------------------------------------
-- the same result flat and five levels deep
call pgmb.reg('cte.nested_flat', '{perf,planning,consistency,oltp}', $q$
with a as (select id, parent_id, amount from g_child where parent_id between :id and :id + 20),
     b as (select parent_id, sum(amount) as s from a group by parent_id),
     c as (select b.parent_id, b.s, p.grp from b join g_parent p on p.id = b.parent_id),
     d as (select grp, sum(s) as s from c group by grp),
     e as (select grp, s from d where s > 0)
select * from e$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.nested');

call pgmb.reg('cte.nested_5_levels_in_body', '{perf,planning,consistency,oltp}', $q$
with e as (
    with d as (
        with c as (
            with b as (
                with a as (select id, parent_id, amount from g_child where parent_id between :id and :id + 20)
                select parent_id, sum(amount) as s from a group by parent_id)
            select b.parent_id, b.s, p.grp from b join g_parent p on p.id = b.parent_id)
        select grp, sum(s) as s from c group by grp)
    select grp, s from d where s > 0)
select * from e$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.nested');

call pgmb.reg('cte.nested_5_levels_in_from', '{perf,planning,consistency,oltp}', $q$
select * from (
    with d as (
        select grp, sum(s) as s from (
            with b as (
                select parent_id, sum(amount) as s from (
                    with a as (select id, parent_id, amount from g_child where parent_id between :id and :id + 20)
                    select * from a) a1
                group by parent_id)
            select b.parent_id, b.s, p.grp from b join g_parent p on p.id = b.parent_id) c
        group by grp)
    select grp, s from d where s > 0) e$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.nested');

call pgmb.reg('cte.nested_5_levels_materialized', '{perf,planning,consistency}', $q$
with e as materialized (
    with d as materialized (
        with c as materialized (
            with b as materialized (
                with a as materialized (select id, parent_id, amount from g_child where parent_id between :id and :id + 20)
                select parent_id, sum(amount) as s from a group by parent_id)
            select b.parent_id, b.s, p.grp from b join g_parent p on p.id = b.parent_id)
        select grp, sum(s) as s from c group by grp)
    select grp, s from d where s > 0)
select * from e$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.nested');

------------------------------------------------------------------------------
-- nesting: where the inner WITH sits
------------------------------------------------------------------------------
call pgmb.reg('cte.nested_in_scalar_subquery', '{perf,planning}', $q$
select p.id,
       (with k as (select amount from g_child c where c.parent_id = p.id)
        select max(amount) - min(amount) from k) as spread
from g_parent p where p.id between :id and :id + 50$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.nested_in_lateral', '{perf,planning}', $q$
select p.id, x.n, x.top
from g_parent p,
     lateral (with k as (select amount from g_child c where c.parent_id = p.id)
              select count(*) as n, max(amount) as top from k) x
where p.id between :id and :id + 50$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.nested_in_exists', '{perf,planning}', $q$
select count(*) from g_parent p
where p.id between :id and :id + 200
  and exists (with k as (select kind from g_child c where c.parent_id = p.id)
              select 1 from k where kind = 0)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.nested_in_in_list', '{perf,planning,oltp}', $q$
with outer_ids as (select id from g_parent where id between :id and :id + 30)
select count(*), sum(amount) from g_child
where parent_id in (with evens as (select id from outer_ids where id % 2 = 0) select id from evens)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.nested_in_union_branches', '{perf,planning,oltp}', $q$
(with a as (select id, grp from g_parent where id between :id and :id + 20) select id, grp from a)
union all
(with a as (select id, kind from g_child where id between :id and :id + 20) select id, kind from a)$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- nesting: visibility and shadowing
------------------------------------------------------------------------------
call pgmb.reg('cte.nested_shadow_3_levels', '{perf,planning,oltp}', $q$
with t as (select id, 1 as lvl from g_parent where id = :id)
select * from (
    with t as (select id, lvl + 1 as lvl from t)
    select * from (
        with t as (select id, lvl + 1 as lvl from t)
        select * from t) s2) s1$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.nested_inner_reads_outer_twice', '{perf,planning}', $q$
with base as (select id, grp, val from g_parent where id between :id and :id + 200)
select * from (
    with hi as (select grp, max(val) as v from base group by grp),
         lo as (select grp, min(val) as v from base group by grp)
    select hi.grp, hi.v - lo.v as spread from hi join lo using (grp)) s$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.nested_sibling_scopes', '{perf,planning}', $q$
with shared as (select id, val from g_parent where id between :id and :id + 100)
select (with x as (select val from shared where id % 2 = 0) select sum(val) from x) as evens,
       (with x as (select val from shared where id % 2 = 1) select sum(val) from x) as odds$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- nesting: recursion and writes
------------------------------------------------------------------------------
call pgmb.reg('cte.nested_recursive_inside_plain', '{perf,planning}', $q$
with sub as (
    with recursive r as (
        select id, 0 as lvl from g_tree where id = :id
        union all
        select t.id, r.lvl + 1 from g_tree t join r on t.parent_id = r.id where r.lvl < 3)
    select lvl, count(*) as n from r group by lvl)
select sum(n), max(lvl) from sub$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.nested_recursive_in_recursive', '{perf,planning}', $q$
with recursive outer_r(n) as (
    (with recursive inner_r(m) as (select 1 union all select m + 1 from inner_r where m < 20)
     select max(m) from inner_r)
    union all
    select n + 1 from outer_r where n < 200)
select count(*), max(n) from outer_r$q$);

call pgmb.reg('cte.nested_plain_inside_recursive_term', '{perf,planning}', $q$
with recursive r(id, lvl) as (
    select :id::bigint, 0
    union all
    select k.id, r.lvl + 1
    from r, lateral (with kids as (select id from g_tree t where t.parent_id = r.id)
                     select id from kids) k
    where r.lvl < 3)
select count(*) from r$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.nested_in_update_source', '{perf,planning,oltp}', $q$
with picked as (select id from g_parent where id between :id and :id + 5)
update g_parent p set val = p.val + s.n
from (with counts as (select parent_id, count(*) as n from g_child where parent_id in (select id from picked) group by parent_id)
      select * from counts) s
where p.id = s.parent_id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');
