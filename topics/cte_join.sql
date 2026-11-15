-- Topic: cte (part 2) - joins between CTEs and between CTEs and tables.
-- Join types, join conditions, join shapes, and equivalent formulations.

------------------------------------------------------------------------------
-- join types
------------------------------------------------------------------------------
call pgmb.reg('cte.join_inner', '{perf,planning,oltp}', $q$
with p as (select id, grp, dim_id from g_parent where id between :id and :id + 30),
     c as (select id as child_id, parent_id, amount from g_child where parent_id between :id and :id + 30)
select p.id, p.grp, c.child_id, c.amount from p join c on c.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_left_with_missing', '{perf,planning,oltp}', $q$
with p as (select id, grp from g_parent where id between :id and :id + 30),
     c as (select parent_id, count(*) as n from g_child
           where parent_id between :id and :id + 30 and kind = 0 group by parent_id)
select p.id, coalesce(c.n, 0) as n, c.parent_id is null as missing from p left join c on c.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_right', '{perf,planning,oltp}', $q$
with c as (select parent_id, sum(amount) as total from g_child
           where parent_id between :id and :id + 30 and kind < 2 group by parent_id),
     p as (select id, name from g_parent where id between :id and :id + 30)
select p.id, p.name, c.total from c right join p on p.id = c.parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_full_partial_overlap', '{perf,planning,oltp}', $q$
with a as (select id, k_100 from g_narrow where id between :id and :id + 200),
     b as (select id, k_10k from g_narrow where id between :id + 100 and :id + 300)
select count(*), count(a.id) as in_a, count(b.id) as in_b, count(*) filter (where a.id is not null and b.id is not null) as both
from a full join b on a.id = b.id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.join_cross_small', '{perf,planning,oltp}', $q$
with d as (select id, code from g_dim where id <= 10),
     s as (select distinct status from g_parent where id between :id and :id + 200)
select d.code, s.status from d cross join s$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_natural', '{perf,planning,oltp}', $q$
with a as (select id, grp from g_parent where id between :id and :id + 50),
     b as (select id, val from g_parent where id between :id + 10 and :id + 60)
select * from a natural join b$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_using_two_columns', '{perf,planning}', $q$
with a as (select k_100, k_10k, id from g_narrow where id between :id and :id + 2000),
     b as (select k_100, k_10k, k_skew from g_narrow where k_100 = :k)
select count(*), max(b.k_skew) from a join b using (k_100, k_10k)$q$,
    setup => E'\\set id random(1, :n_g_narrow)\n\\set k random(0, 99)');

------------------------------------------------------------------------------
-- semi and anti joins: each written three ways, results must agree
------------------------------------------------------------------------------
call pgmb.reg('cte.join_semi_exists', '{perf,planning,consistency,oltp}', $q$
with p as (select id from g_parent where id between :id and :id + 60),
     c as (select parent_id from g_child where kind = :k)
select p.id from p where exists (select 1 from c where c.parent_id = p.id)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', equiv => 'cte.join_semi');

call pgmb.reg('cte.join_semi_in', '{perf,planning,consistency,oltp}', $q$
with p as (select id from g_parent where id between :id and :id + 60),
     c as (select parent_id from g_child where kind = :k)
select p.id from p where p.id in (select parent_id from c)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', equiv => 'cte.join_semi');

call pgmb.reg('cte.join_semi_distinct_join', '{perf,planning,consistency,oltp}', $q$
with p as (select id from g_parent where id between :id and :id + 60),
     c as (select parent_id from g_child where kind = :k)
select distinct p.id from p join c on c.parent_id = p.id$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', equiv => 'cte.join_semi');

call pgmb.reg('cte.join_anti_not_exists', '{perf,planning,consistency,oltp}', $q$
with p as (select id from g_parent where id between :id and :id + 60),
     c as (select parent_id from g_child where kind = :k)
select p.id from p where not exists (select 1 from c where c.parent_id = p.id)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', equiv => 'cte.join_anti');

call pgmb.reg('cte.join_anti_not_in', '{perf,planning,consistency}', $q$
with p as (select id from g_parent where id between :id and :id + 60),
     c as (select parent_id from g_child where kind = :k and parent_id between :id and :id + 60)
select p.id from p where p.id not in (select parent_id from c)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', equiv => 'cte.join_anti');

call pgmb.reg('cte.join_anti_left_is_null', '{perf,planning,consistency,oltp}', $q$
with p as (select id from g_parent where id between :id and :id + 60),
     c as (select parent_id from g_child where kind = :k)
select p.id from p left join c on c.parent_id = p.id where c.parent_id is null$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', equiv => 'cte.join_anti');

call pgmb.reg('cte.join_anti_except', '{perf,planning,consistency}', $q$
with p as (select id from g_parent where id between :id and :id + 60),
     c as (select parent_id from g_child where kind = :k)
select id from p except select parent_id from c$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', equiv => 'cte.join_anti');

------------------------------------------------------------------------------
-- join conditions
------------------------------------------------------------------------------
call pgmb.reg('cte.join_on_expression', '{perf,planning,oltp}', $q$
with n as (select id, k_100 from g_narrow where id between :id and :id + 100),
     d as (select id, code from g_dim)
select n.id, d.code from n join d on d.id = n.k_100 % 10 + 1$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.join_on_range_band', '{perf,planning}', $q$
with a as (select id, ts, val from g_events where entity_id = :e),
     b as (select id, ts, val from g_events where entity_id = :e + 1)
select count(*), avg(b.val - a.val)
from a join b on b.ts between a.ts and a.ts + interval '10 minutes'$q$,
    setup => '\set e random(1, :n_g_events_entities - 1)');

call pgmb.reg('cte.join_on_inequality', '{perf,planning}', $q$
with a as (select id, amount from g_child where parent_id between :id and :id + 5),
     b as (select id, amount from g_child where parent_id between :id + 6 and :id + 11)
select count(*) from a join b on a.amount < b.amount$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_on_or', '{perf,planning}', $q$
with a as (select id, grp, dim_id from g_parent where id between :id and :id + 100),
     b as (select id, grp, dim_id from g_parent where id between :id + 50 and :id + 150)
select count(*) from a join b on a.grp = b.grp or a.dim_id = b.dim_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_on_null_safe', '{perf,planning}', $q$
with a as (select id, k_null from g_narrow where id between :id and :id + 150),
     b as (select id, k_null from g_narrow where id between :id + 150 and :id + 300)
select count(*), count(*) filter (where a.k_null is null) as null_matches
from a join b on a.k_null is not distinct from b.k_null$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.join_on_row_equality', '{perf,planning}', $q$
with a as (select k_100, k_10k, id from g_narrow where id between :id and :id + 3000),
     b as (select k_100, k_10k, id from g_narrow where id between :id + 3001 and :id + 6000)
select count(*) from a join b on (a.k_100, a.k_10k) = (b.k_100, b.k_10k)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.join_on_cast_mismatch', '{perf,planning,oltp}', $q$
with p as (select id, dim_id from g_parent where id between :id and :id + 50),
     d as (select id::numeric as id, code from g_dim)
select p.id, d.code from p join d on d.id = p.dim_id$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- join shapes
------------------------------------------------------------------------------
call pgmb.reg('cte.join_self_two_readers', '{perf,planning}', $q$
with c as (select id, parent_id, amount from g_child where parent_id between :id and :id + 10)
select count(*), max(a.amount + b.amount)
from c a join c b on a.parent_id = b.parent_id and a.id < b.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_chain_4', '{perf,planning,oltp}', $q$
with c as (select id, parent_id, amount from g_child where id between :id and :id + 50),
     p as (select id, dim_id, grp from g_parent),
     d as (select id, category, code from g_dim),
     t as (select id, depth from g_tree)
select c.id, p.grp, d.code, t.depth
from c join p on p.id = c.parent_id join d on d.id = p.dim_id join t on t.id = p.id$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('cte.join_star_5', '{perf,planning,oltp}', $q$
with f as (select id, parent_id, kind, amount from g_child where id between :id and :id + 50),
     p as (select id, grp, dim_id from g_parent),
     n as (select id, k_100 from g_narrow),
     e as (select id, cat from g_events),
     t as (select id, depth from g_tree),
     a as (select id, cardinality(a_small) as len from g_array)
select f.id, p.grp, n.k_100, e.cat, t.depth, a.len
from f
join p on p.id = f.parent_id
left join n on n.id = f.id
left join e on e.id = f.id
left join t on t.id = f.parent_id
left join a on a.id = f.parent_id$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('cte.join_triangle', '{perf,planning}', $q$
with p as (select id, dim_id, grp from g_parent where grp = :g),
     c as (select id, parent_id, kind from g_child where kind = :k),
     d as (select id, category from g_dim)
select count(*)
from p join c on c.parent_id = p.id
       join d on d.id = p.dim_id and d.category = c.kind$q$,
    setup => E'\\set g random(0, 99)\n\\set k random(0, 7)');

call pgmb.reg('cte.join_outer_chain', '{perf,planning,oltp}', $q$
with p as (select id, dim_id from g_parent where id between :id and :id + 30),
     c as (select id, parent_id, kind from g_child where seq < 100),
     d as (select id, category from g_dim where category < 5)
select p.id, c.id as child_id, d.category
from p left join c on c.parent_id = p.id
       left join d on d.id = p.dim_id and d.category = c.kind$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_outer_reduced_to_inner', '{perf,planning,oltp}', $q$
with p as (select id, grp from g_parent where id between :id and :id + 30),
     c as (select parent_id, amount from g_child)
select p.id, c.amount from p left join c on c.parent_id = p.id where c.amount > 500$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_left_removed', '{perf,planning,oltp}', $q$
with p as (select id, dim_id, val from g_parent where id between :id and :id + 100),
     d as (select id, code, name from g_dim)
select p.id, p.val from p left join d on d.id = p.dim_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_table_twice', '{perf,planning,oltp}', $q$
with t as (select id, parent_id from g_tree where id between :id and :id + 20)
select t.id, self.name as own_name, up.name as parent_name
from t join g_parent self on self.id = t.id
       left join g_parent up on up.id = t.parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_aggregate_to_detail', '{perf,planning,oltp}', $q$
with detail as (select id, parent_id, amount from g_child where parent_id between :id and :id + 10),
     total as (select parent_id, sum(amount) as total from detail group by parent_id)
select d.id, d.amount, round(100 * d.amount / nullif(t.total, 0), 2) as pct
from detail d join total t using (parent_id)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_two_aggregates', '{perf,planning}', $q$
with ev as (select entity_id as id, count(*) as events, avg(val) as avg_val
            from g_events where entity_id between :e and :e + 20 group by entity_id),
     ch as (select parent_id as id, count(*) as children, sum(amount) as amount
            from g_child where parent_id between :e and :e + 20 group by parent_id)
select id, ev.events, ev.avg_val, ch.children, ch.amount from ev full join ch using (id)$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('cte.join_values_lookup', '{perf,planning,oltp}', $q$
with label(status, txt) as (values (0, 'new'), (1, 'open'), (2, 'held'), (3, 'done'), (4, 'void')),
     p as (select id, status from g_parent where id between :id and :id + 50)
select p.id, l.txt from p join label l on l.status = p.status$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_unnest_elements', '{perf,planning}', $q$
with a as (select id, a_small from g_array where id between :id and :id + 100),
     e as (select a.id, u.x from a, unnest(a.a_small) as u(x))
select e.id, e.x, p.grp from e join g_parent p on p.id = e.x + 1$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('cte.join_lateral_over_cte', '{perf,planning,oltp}', $q$
with p as (select id from g_parent where id between :id and :id + 20),
     c as (select id, parent_id, amount from g_child where parent_id between :id and :id + 20)
select p.id, top.id as child_id, top.amount
from p, lateral (select id, amount from c where c.parent_id = p.id order by amount desc limit 2) top$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_union_branches', '{perf,planning,oltp}', $q$
with u as (select id, grp from g_parent where id between :id and :id + 20
           union all
           select id, grp from g_parent where id between :id + 500 and :id + 520)
select u.id, count(c.id) from u left join g_child c on c.parent_id = u.id group by u.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_recursive_to_tables', '{perf,planning}', $q$
with recursive sub as (
    select id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 3)
select s.lvl, count(*), sum(p.val), count(distinct d.category)
from sub s join g_parent p on p.id = s.id join g_dim d on d.id = p.dim_id
group by s.lvl$q$,
    setup => '\set id random(1, :n_g_parent / 4)');

call pgmb.reg('cte.join_materialized_both_sides', '{perf,planning}', $q$
with a as materialized (select id, k_100 from g_narrow where id between :id and :id + 2000),
     b as materialized (select id, k_10k from g_narrow where id between :id + 1000 and :id + 3000)
select count(*), sum(a.k_100), sum(b.k_10k) from a join b using (id)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.join_merge_sorted_inputs', '{perf,planning}', $q$
with a as (select id, k_10k from g_narrow where id between :id and :id + 5000),
     b as (select id, val from g_events where id between :id and :id + 5000)
select count(*), sum(a.k_10k * b.val) from a join b using (id)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.join_hash_whole_tables', '{perf,planning,olap}', $q$
with p as (select id, grp from g_parent),
     c as (select parent_id, amount from g_child)
select p.grp, count(*), sum(c.amount) from p join c on c.parent_id = p.id group by p.grp$q$);

call pgmb.reg('cte.join_three_way_whole_tables', '{perf,planning,olap}', $q$
with p as (select id, dim_id from g_parent),
     c as (select parent_id, kind, amount from g_child),
     d as (select id, category from g_dim)
select d.category, c.kind, sum(c.amount)
from c join p on p.id = c.parent_id join d on d.id = p.dim_id
group by d.category, c.kind$q$);

------------------------------------------------------------------------------
-- joins fed by data-modifying CTEs
------------------------------------------------------------------------------
call pgmb.reg('cte.join_update_returning', '{perf,planning,oltp}', $q$
with u as (update g_parent set val = val + 1 where id between :id and :id + 4 returning id, dim_id, val)
select u.id, u.val, d.code from u join g_dim d on d.id = u.dim_id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_insert_from_join', '{perf,planning,oltp}', $q$
with src as (select p.id as parent_id, d.category from g_parent p join g_dim d on d.id = p.dim_id
             where p.id between :id and :id + 2),
     ins as (insert into g_child (parent_id, seq, kind, amount, ts, note)
             select parent_id, 0, category % 8, 1.00, now(), 'join' from src returning id, parent_id)
select i.id, p.grp from ins i join g_parent p on p.id = i.parent_id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');
