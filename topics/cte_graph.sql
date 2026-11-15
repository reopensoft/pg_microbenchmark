-- Topic: cte (part 19) - shapes of the dependency graph between CTEs.
-- "A -> B" means B reads A; Q is the final query. One section per topology,
-- usually in three forms: default, every CTE MATERIALIZED, every CTE NOT
-- MATERIALIZED. The forms of one topology are a consistency group.
-- A CTE read once is inlined by default, one read more often is materialized;
-- NOT MATERIALIZED copies the definition to every reader, so in graphs where
-- nodes have several readers the amount of work can multiply level by level.
-- Large graphs are generated here with string_agg and \gset.
-- Earlier single cases: cte.chain_5, cte.diamond, cte.fan_out_fan_in, cte.unused.

------------------------------------------------------------------------------
-- 1. single:  A -> Q
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_single_default', '{perf,planning,consistency,oltp}', $q$
with a as (select id, grp, val from g_parent)
select count(*), sum(val) from a where id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_single');

call pgmb.reg('cte.graph_single_materialized', '{perf,planning,consistency,olap}', $q$
with a as materialized (select id, grp, val from g_parent)
select count(*), sum(val) from a where id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_single');

call pgmb.reg('cte.graph_single_not_materialized', '{perf,planning,consistency,oltp}', $q$
with a as not materialized (select id, grp, val from g_parent)
select count(*), sum(val) from a where id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_single');

------------------------------------------------------------------------------
-- 2. linear:  A -> B -> C -> Q   (the filter of Q has to travel three levels down)
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_linear_default', '{perf,planning,consistency,oltp}', $q$
with a as (select id, grp, val from g_parent),
     b as (select id, grp, val * 2 as val from a),
     c as (select id, grp, val + grp as val from b where grp < 90)
select count(*), sum(val) from c where id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_linear');

call pgmb.reg('cte.graph_linear_materialized', '{perf,planning,consistency,olap}', $q$
with a as materialized (select id, grp, val from g_parent),
     b as materialized (select id, grp, val * 2 as val from a),
     c as materialized (select id, grp, val + grp as val from b where grp < 90)
select count(*), sum(val) from c where id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_linear');

-- only the middle level is a fence: the filter stops there
call pgmb.reg('cte.graph_linear_middle_materialized', '{perf,planning,consistency,olap}', $q$
with a as (select id, grp, val from g_parent),
     b as materialized (select id, grp, val * 2 as val from a),
     c as (select id, grp, val + grp as val from b where grp < 90)
select count(*), sum(val) from c where id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_linear');

------------------------------------------------------------------------------
-- 3. deep chain:  A -> ... -> Z -> Q   (26 and 100 levels)
------------------------------------------------------------------------------
select 'with c0 as (select id, grp, val from g_parent)'
       || string_agg(format(', c%s as (select id, grp, val + 1 as val from c%s)', i, i - 1), '' order by i)
       || ' select count(*), sum(val) from c26 where id between :id and :id + 199' as pgmb_sql
from generate_series(1, 26) i \gset
call pgmb.reg('cte.graph_deep_chain_26_default', '{perf,planning,consistency,oltp}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_deep26');

select 'with c0 as materialized (select id, grp, val from g_parent where id between :id and :id + 199)'
       || string_agg(format(', c%s as materialized (select id, grp, val + 1 as val from c%s)', i, i - 1), '' order by i)
       || ' select count(*), sum(val) from c26' as pgmb_sql
from generate_series(1, 26) i \gset
call pgmb.reg('cte.graph_deep_chain_26_materialized', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_deep26');

select 'with c0 as (select id, grp, val from g_parent)'
       || string_agg(format(', c%s as (select id, grp, val + 1 as val from c%s)', i, i - 1), '' order by i)
       || ' select count(*), sum(val) from c100 where id between :id and :id + 199' as pgmb_sql
from generate_series(1, 100) i \gset
call pgmb.reg('cte.graph_deep_chain_100_default', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_deep100');

select 'with c0 as materialized (select id, grp, val from g_parent where id between :id and :id + 199)'
       || string_agg(format(', c%s as materialized (select id, grp, val + 1 as val from c%s)', i, i - 1), '' order by i)
       || ' select count(*), sum(val) from c100' as pgmb_sql
from generate_series(1, 100) i \gset
call pgmb.reg('cte.graph_deep_chain_100_materialized', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_deep100');

-- every level filters a little: 100 conditions collapse into one scan
select 'with c0 as (select id, grp, val from g_parent where id between :id and :id + 999)'
       || string_agg(format(', c%s as (select id, grp, val from c%s where id %% 1000 <> %s)', i, i - 1, i), '' order by i)
       || ' select count(*), sum(val) from c100' as pgmb_sql
from generate_series(1, 100) i \gset
call pgmb.reg('cte.graph_deep_chain_100_filter_per_level', '{perf,planning}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 4. fan-out:  A -> B, C, D -> Q
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_fan_out_default', '{perf,planning,consistency}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 199),
     b as (select count(*) as n from a where grp < 30),
     c as (select sum(val) as total from a where grp between 30 and 60),
     d as (select max(val) as mx from a where grp > 60)
select b.n, c.total, d.mx from b, c, d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_fan_out');

call pgmb.reg('cte.graph_fan_out_materialized', '{perf,planning,consistency}', $q$
with a as materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as materialized (select count(*) as n from a where grp < 30),
     c as materialized (select sum(val) as total from a where grp between 30 and 60),
     d as materialized (select max(val) as mx from a where grp > 60)
select b.n, c.total, d.mx from b, c, d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_fan_out');

-- A is computed once per branch
call pgmb.reg('cte.graph_fan_out_not_materialized', '{perf,planning,consistency}', $q$
with a as not materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as not materialized (select count(*) as n from a where grp < 30),
     c as not materialized (select sum(val) as total from a where grp between 30 and 60),
     d as not materialized (select max(val) as mx from a where grp > 60)
select b.n, c.total, d.mx from b, c, d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_fan_out');

------------------------------------------------------------------------------
-- 5. fan-in:  A, B, C -> D -> Q   (three independent sources)
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_fan_in_default', '{perf,planning,consistency}', $q$
with a as (select id, dim_id, val from g_parent where id between :id and :id + 199),
     b as (select parent_id, count(*) as children from g_child where parent_id between :id and :id + 199 group by parent_id),
     c as (select id, category from g_dim),
     d as (select a.id, a.val, coalesce(b.children, 0) as children, c.category
           from a left join b on b.parent_id = a.id join c on c.id = a.dim_id)
select category, count(*), sum(children), sum(val) from d group by category order by category$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_fan_in');

call pgmb.reg('cte.graph_fan_in_materialized', '{perf,planning,consistency}', $q$
with a as materialized (select id, dim_id, val from g_parent where id between :id and :id + 199),
     b as materialized (select parent_id, count(*) as children from g_child where parent_id between :id and :id + 199 group by parent_id),
     c as materialized (select id, category from g_dim),
     d as materialized (select a.id, a.val, coalesce(b.children, 0) as children, c.category
           from a left join b on b.parent_id = a.id join c on c.id = a.dim_id)
select category, count(*), sum(children), sum(val) from d group by category order by category$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_fan_in');

------------------------------------------------------------------------------
-- 6. diamond:  A -> B, C -> D -> Q
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_diamond_default', '{perf,planning,consistency}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 199),
     b as (select grp, count(*) as n from a group by grp),
     c as (select grp, sum(val) as total from a group by grp),
     d as (select b.grp, b.n, c.total from b join c using (grp))
select count(*), sum(n), sum(total) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_diamond');

call pgmb.reg('cte.graph_diamond_materialized', '{perf,planning,consistency}', $q$
with a as materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as materialized (select grp, count(*) as n from a group by grp),
     c as materialized (select grp, sum(val) as total from a group by grp),
     d as materialized (select b.grp, b.n, c.total from b join c using (grp))
select count(*), sum(n), sum(total) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_diamond');

call pgmb.reg('cte.graph_diamond_not_materialized', '{perf,planning,consistency}', $q$
with a as not materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as not materialized (select grp, count(*) as n from a group by grp),
     c as not materialized (select grp, sum(val) as total from a group by grp),
     d as not materialized (select b.grp, b.n, c.total from b join c using (grp))
select count(*), sum(n), sum(total) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_diamond');

------------------------------------------------------------------------------
-- 7. double diamond:  A -> B, C -> D -> E, F -> G -> Q
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_double_diamond_default', '{perf,planning,consistency}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 199),
     b as (select grp, count(*) as n from a group by grp),
     c as (select grp, sum(val) as total from a group by grp),
     d as (select b.grp, b.n, c.total from b join c using (grp)),
     e as (select grp % 10 as bucket, sum(n) as n from d group by 1),
     f as (select grp % 10 as bucket, sum(total) as total from d group by 1),
     g as (select e.bucket, e.n, f.total from e join f using (bucket))
select count(*), sum(n), sum(total) from g$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_double_diamond');

-- A is read 2 times, D 2 times: inlined, the base scan runs 4 times
call pgmb.reg('cte.graph_double_diamond_not_materialized', '{perf,planning,consistency}', $q$
with a as not materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as not materialized (select grp, count(*) as n from a group by grp),
     c as not materialized (select grp, sum(val) as total from a group by grp),
     d as not materialized (select b.grp, b.n, c.total from b join c using (grp)),
     e as not materialized (select grp % 10 as bucket, sum(n) as n from d group by 1),
     f as not materialized (select grp % 10 as bucket, sum(total) as total from d group by 1),
     g as not materialized (select e.bucket, e.n, f.total from e join f using (bucket))
select count(*), sum(n), sum(total) from g$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_double_diamond');

-- a chain of five diamonds
select 'with n0 as (select id, grp, val from g_parent where id between :id and :id + 199)'
       || string_agg(format(', l%1$s as (select id, grp, val from n%2$s where id %% 2 = 0), r%1$s as (select id, grp, val from n%2$s where id %% 2 = 1), n%1$s as (select * from l%1$s union all select * from r%1$s)', i, i - 1), '' order by i)
       || ' select count(*), sum(val) from n5' as pgmb_sql
from generate_series(1, 5) i \gset
call pgmb.reg('cte.graph_five_diamonds_default', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_five_diamonds');

select 'with n0 as not materialized (select id, grp, val from g_parent where id between :id and :id + 199)'
       || string_agg(format(', l%1$s as not materialized (select id, grp, val from n%2$s where id %% 2 = 0), r%1$s as not materialized (select id, grp, val from n%2$s where id %% 2 = 1), n%1$s as not materialized (select * from l%1$s union all select * from r%1$s)', i, i - 1), '' order by i)
       || ' select count(*), sum(val) from n5' as pgmb_sql
from generate_series(1, 5) i \gset
-- every diamond doubles the copies of what is below it: 32 scans of the base
call pgmb.reg('cte.graph_five_diamonds_not_materialized', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_five_diamonds');

------------------------------------------------------------------------------
-- 8. tree:  A -> B, C;  B -> D, E;  C -> F, G;  leaves -> Q
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_tree_all_leaves_read', '{perf,planning}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 399),
     b as (select * from a where grp < 50),
     c as (select * from a where grp >= 50),
     d as (select count(*) as n from b where id % 2 = 0),
     e as (select count(*) as n from b where id % 2 = 1),
     f as (select count(*) as n from c where id % 2 = 0),
     g as (select count(*) as n from c where id % 2 = 1)
select d.n, e.n, f.n, g.n from d, e, f, g$q$,
    setup => '\set id random(1, :n_g_parent)');

-- Q reads two leaves: the other two, E and F, are never planned or run
call pgmb.reg('cte.graph_tree_two_leaves_read', '{perf,planning}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 399),
     b as (select * from a where grp < 50),
     c as (select * from a where grp >= 50),
     d as (select count(*) as n from b where id % 2 = 0),
     e as (select count(*) as n from b where id % 2 = 1),
     f as (select count(*) as n from c where id % 2 = 0),
     g as (select count(*) as n from c where id % 2 = 1)
select d.n, g.n from d, g$q$,
    setup => '\set id random(1, :n_g_parent)');

-- one leaf: a single path from the root is left, and it is inlined completely
call pgmb.reg('cte.graph_tree_one_leaf_read', '{perf,planning}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 399),
     b as (select * from a where grp < 50),
     c as (select * from a where grp >= 50),
     d as (select count(*) as n from b where id % 2 = 0),
     e as (select count(*) as n from b where id % 2 = 1),
     f as (select count(*) as n from c where id % 2 = 0),
     g as (select count(*) as n from c where id % 2 = 1)
select d.n from d$q$,
    setup => '\set id random(1, :n_g_parent)');

-- the leaf to read is chosen at run time: both are planned, one is executed
call pgmb.reg('cte.graph_tree_leaf_chosen_at_run_time', '{perf,planning}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 399),
     b as (select * from a where grp < 50),
     c as (select * from a where grp >= 50),
     d as (select count(*) as n from b),
     g as (select count(*) as n from c)
select case when :pick = 0 then (select n from d) else (select n from g) end$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set pick random(0, 1)');

------------------------------------------------------------------------------
-- 9. inverted tree:  A, B, C, D -> E, F -> G -> Q
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_inverted_tree_default', '{perf,planning,consistency}', $q$
with a as (select id, val from g_parent where id between :id and :id + 99),
     b as (select id, val from g_parent where id between :id + 100 and :id + 199),
     c as (select id, val from g_parent where id between :id + 200 and :id + 299),
     d as (select id, val from g_parent where id between :id + 300 and :id + 399),
     e as (select a.id, a.val + b.val as val from a join b on b.id = a.id + 100),
     f as (select c.id, c.val + d.val as val from c join d on d.id = c.id + 100),
     g as (select e.id, e.val + f.val as val from e join f on f.id = e.id + 200)
select count(*), sum(val) from g$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_inverted_tree');

call pgmb.reg('cte.graph_inverted_tree_materialized', '{perf,planning,consistency}', $q$
with a as materialized (select id, val from g_parent where id between :id and :id + 99),
     b as materialized (select id, val from g_parent where id between :id + 100 and :id + 199),
     c as materialized (select id, val from g_parent where id between :id + 200 and :id + 299),
     d as materialized (select id, val from g_parent where id between :id + 300 and :id + 399),
     e as materialized (select a.id, a.val + b.val as val from a join b on b.id = a.id + 100),
     f as materialized (select c.id, c.val + d.val as val from c join d on d.id = c.id + 100),
     g as materialized (select e.id, e.val + f.val as val from e join f on f.id = e.id + 200)
select count(*), sum(val) from g$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_inverted_tree');

-- the same four leaves joined directly: what the inlined form becomes
call pgmb.reg('cte.graph_inverted_tree_flat_join', '{perf,planning,consistency}', $q$
select count(*), sum(a.val + b.val + c.val + d.val)
from g_parent a join g_parent b on b.id = a.id + 100
     join g_parent c on c.id = a.id + 200 join g_parent d on d.id = a.id + 300
where a.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_inverted_tree');

------------------------------------------------------------------------------
-- 10. wide DAG: many CTEs on one level
------------------------------------------------------------------------------
select 'with ' || string_agg(format('c%s as (select count(*) as n, sum(val) as total from g_parent where id between :id + %s and :id + %s)', i, i * 10, i * 10 + 9), ', ' order by i)
       || ' select sum(n), sum(total) from (' || string_agg(format('select * from c%s', i), ' union all ' order by i) || ') u' as pgmb_sql
from generate_series(1, 50) i \gset
call pgmb.reg('cte.graph_wide_50_union', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_wide50');

select 'with ' || string_agg(format('c%s as materialized (select count(*) as n, sum(val) as total from g_parent where id between :id + %s and :id + %s)', i, i * 10, i * 10 + 9), ', ' order by i)
       || ' select sum(n), sum(total) from (' || string_agg(format('select * from c%s', i), ' union all ' order by i) || ') u' as pgmb_sql
from generate_series(1, 50) i \gset
call pgmb.reg('cte.graph_wide_50_union_materialized', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_wide50');

call pgmb.reg('cte.graph_wide_50_as_one_scan', '{perf,planning,consistency}', $q$
select count(*), sum(val) from g_parent where id between :id + 10 and :id + 509$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_wide50');

select 'with ' || string_agg(format('c%s as (select count(*) as n from g_parent where id between :id + %s and :id + %s)', i, i * 5, i * 5 + 4), ', ' order by i)
       || ' select sum(n) from (' || string_agg(format('select * from c%s', i), ' union all ' order by i) || ') u' as pgmb_sql
from generate_series(1, 300) i \gset
call pgmb.reg('cte.graph_wide_300_union', '{perf,planning}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)');

-- 20 single-row CTEs cross-joined: 20 relations for the join planner
select 'with ' || string_agg(format('c%s as (select count(*) as n from g_parent where id between :id + %s and :id + %s)', i, i * 10, i * 10 + 9), ', ' order by i)
       || ' select ' || string_agg(format('c%s.n', i), ' + ' order by i) || ' from ' || string_agg(format('c%s', i), ', ' order by i) as pgmb_sql
from generate_series(1, 20) i \gset
call pgmb.reg('cte.graph_wide_20_cross_join', '{perf,planning}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 11. deep DAG: two nodes per level, each reading both nodes of the level below
------------------------------------------------------------------------------
select 'with a0 as (select id, val from g_parent where id between :id and :id + 49), b0 as (select id, val from g_parent where id between :id and :id + 49)'
       || string_agg(format(', a%1$s as (select x.id, x.val + y.val as val from a%2$s x join b%2$s y using (id)), b%1$s as (select x.id, x.val - y.val as val from a%2$s x join b%2$s y using (id))', i, i - 1), '' order by i)
       || ' select count(*), sum(a10.val + b10.val) from a10 join b10 using (id)' as pgmb_sql
from generate_series(1, 10) i \gset
call pgmb.reg('cte.graph_deep_dag_10_levels_default', '{perf,planning}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)');

select 'with a0 as (select id, val from g_parent where id between :id and :id + 49), b0 as (select id, val from g_parent where id between :id and :id + 49)'
       || string_agg(format(', a%1$s as (select x.id, x.val + y.val as val from a%2$s x join b%2$s y using (id)), b%1$s as (select x.id, x.val - y.val as val from a%2$s x join b%2$s y using (id))', i, i - 1), '' order by i)
       || ' select count(*), sum(a5.val + b5.val) from a5 join b5 using (id)' as pgmb_sql
from generate_series(1, 5) i \gset
call pgmb.reg('cte.graph_deep_dag_5_levels_default', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_deep_dag5');

-- inlined, level k holds 2^k copies of each base scan: 64 base scans for 5 levels
select 'with a0 as not materialized (select id, val from g_parent where id between :id and :id + 49), b0 as not materialized (select id, val from g_parent where id between :id and :id + 49)'
       || string_agg(format(', a%1$s as not materialized (select x.id, x.val + y.val as val from a%2$s x join b%2$s y using (id)), b%1$s as not materialized (select x.id, x.val - y.val as val from a%2$s x join b%2$s y using (id))', i, i - 1), '' order by i)
       || ' select count(*), sum(a5.val + b5.val) from a5 join b5 using (id)' as pgmb_sql
from generate_series(1, 5) i \gset
call pgmb.reg('cte.graph_deep_dag_5_levels_not_materialized', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_deep_dag5');

------------------------------------------------------------------------------
-- 12. dense DAG: every CTE reads all the CTEs before it
------------------------------------------------------------------------------
select 'with c1 as (select count(*)::numeric as n from g_parent where id between :id and :id + 99)'
       || string_agg(format(', c%s as (select sum(n) + 1 as n from (%s) u)', i,
                            (select string_agg(format('select n from c%s', j), ' union all ' order by j) from generate_series(1, i - 1) j)), '' order by i)
       || ' select n from c12' as pgmb_sql
from generate_series(2, 12) i \gset
call pgmb.reg('cte.graph_dense_dag_12_default', '{perf,planning}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)');

select 'with c1 as (select count(*)::numeric as n from g_parent where id between :id and :id + 99)'
       || string_agg(format(', c%s as (select sum(n) + 1 as n from (%s) u)', i,
                            (select string_agg(format('select n from c%s', j), ' union all ' order by j) from generate_series(1, i - 1) j)), '' order by i)
       || ' select n from c8' as pgmb_sql
from generate_series(2, 8) i \gset
call pgmb.reg('cte.graph_dense_dag_8_default', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_dense8');

-- inlined, c8 expands to 2^6 = 64 copies of c1
select 'with c1 as not materialized (select count(*)::numeric as n from g_parent where id between :id and :id + 99)'
       || string_agg(format(', c%s as not materialized (select sum(n) + 1 as n from (%s) u)', i,
                            (select string_agg(format('select n from c%s', j), ' union all ' order by j) from generate_series(1, i - 1) j)), '' order by i)
       || ' select n from c8' as pgmb_sql
from generate_series(2, 8) i \gset
call pgmb.reg('cte.graph_dense_dag_8_not_materialized', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_dense8');

------------------------------------------------------------------------------
-- 13. sparse DAG: 30 CTEs, few edges, Q needs three of them
------------------------------------------------------------------------------
select 'with ' || string_agg(format('c%s as (select count(*) as n from %s)', i,
                                    case when i % 10 = 0 then format('c%s', i - 5)
                                         else format('g_parent where id between :id + %s and :id + %s', i * 10, i * 10 + 9) end), ', ' order by i)
       || ' select c10.n + c20.n + c7.n from c10, c20, c7' as pgmb_sql
from generate_series(1, 30) i \gset
call pgmb.reg('cte.graph_sparse_dag_30_three_needed', '{perf,planning}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)');

select 'with ' || string_agg(format('c%s as (select count(*) as n from %s)', i,
                                    case when i % 10 = 0 then format('c%s', i - 5)
                                         else format('g_parent where id between :id + %s and :id + %s', i * 10, i * 10 + 9) end), ', ' order by i)
       || ' select ' || string_agg(format('c%s.n', i), ' + ' order by i) || ' from ' || string_agg(format('c%s', i), ', ' order by i) as pgmb_sql
from generate_series(1, 30) i \gset
call pgmb.reg('cte.graph_sparse_dag_30_all_needed', '{perf,planning}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 14. disconnected DAG:  A -> B   and   C -> D,  Q reads one component or both
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_disconnected_one_component_read', '{perf,planning,consistency}', $q$
with a as (select id, val from g_parent where id between :id and :id + 199),
     b as (select count(*) as n, sum(val) as total from a),
     c as (select parent_id, amount from g_child),
     d as (select parent_id, sum(amount) as total from c group by parent_id)
select n, total from b$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_disconnected');

call pgmb.reg('cte.graph_disconnected_other_component_absent', '{perf,planning,consistency}', $q$
with a as (select id, val from g_parent where id between :id and :id + 199),
     b as (select count(*) as n, sum(val) as total from a)
select n, total from b$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_disconnected');

call pgmb.reg('cte.graph_disconnected_both_components_read', '{perf,planning,olap}', $q$
with a as (select id, val from g_parent where id between :id and :id + 199),
     b as (select count(*) as n, sum(val) as total from a),
     c as (select parent_id, amount from g_child),
     d as (select parent_id, sum(amount) as total from c group by parent_id)
select b.n, b.total, (select count(*) from d) from b$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 15. orphan: a CTE nobody reads      16. dead branch:  A -> B, but only A -> Q
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_orphan_heavy', '{perf,planning,consistency,oltp}', $q$
with orphan as (select parent_id, kind, sum(amount) from g_child group by parent_id, kind order by 3 desc),
     a as (select id, val from g_parent where id = :id)
select * from a$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_orphan');

call pgmb.reg('cte.graph_orphan_heavy_materialized', '{perf,planning,consistency,oltp}', $q$
with orphan as materialized (select parent_id, kind, sum(amount) from g_child group by parent_id, kind order by 3 desc),
     a as (select id, val from g_parent where id = :id)
select * from a$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_orphan');

-- 20 orphans: parsed and analysed, never planned
select 'with ' || string_agg(format('o%s as (select parent_id, sum(amount) from g_child where kind = %s group by parent_id)', i, i % 8), ', ' order by i)
       || ', a as (select id, val from g_parent where id = :id) select * from a' as pgmb_sql
from generate_series(1, 20) i \gset
call pgmb.reg('cte.graph_orphans_20', '{perf,planning,consistency,oltp}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_orphan');

call pgmb.reg('cte.graph_dead_branch', '{perf,planning,consistency,oltp}', $q$
with a as (select id, val from g_parent where id = :id),
     b as (select a.id, sum(ch.amount) as total from a join g_child ch on ch.parent_id = a.id group by a.id)
select * from a$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_orphan');

-- a dead chain hanging off a live CTE
call pgmb.reg('cte.graph_dead_branch_chain', '{perf,planning,consistency,oltp}', $q$
with a as (select id, val from g_parent where id = :id),
     b as (select a.id, ch.amount from a join g_child ch on ch.parent_id = a.id),
     c as (select id, sum(amount) as total from b group by id),
     d as (select * from c where total > 0)
select * from a$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_orphan');

-- the branch is dead, but A now has "two readers" in the text: is A still inlined?
call pgmb.reg('cte.graph_dead_branch_pk_lookup_through_a', '{perf,planning,oltp}', $q$
with a as (select id, val from g_parent),
     b as (select count(*) as n from a)
select * from a where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 17. shared root: one expensive source for several branches
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_shared_root_default', '{perf,planning,consistency}', $q$
with root as (select parent_id, kind, sum(amount) as total, count(*) as n
              from g_child where parent_id between :id and :id + 499 group by parent_id, kind),
     by_kind as (select kind, sum(total) as total from root group by kind),
     by_parent as (select parent_id, sum(n) as n from root group by parent_id),
     top as (select max(total) as mx from root)
select (select count(*) from by_kind), (select count(*) from by_parent), (select mx from top)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_shared_root');

-- the aggregate is computed once per branch
call pgmb.reg('cte.graph_shared_root_not_materialized', '{perf,planning,consistency}', $q$
with root as not materialized (select parent_id, kind, sum(amount) as total, count(*) as n
              from g_child where parent_id between :id and :id + 499 group by parent_id, kind),
     by_kind as (select kind, sum(total) as total from root group by kind),
     by_parent as (select parent_id, sum(n) as n from root group by parent_id),
     top as (select max(total) as mx from root)
select (select count(*) from by_kind), (select count(*) from by_parent), (select mx from top)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_shared_root');

-- each branch wants a small part: inlined, every branch can filter early
call pgmb.reg('cte.graph_shared_root_selective_branches_default', '{perf,planning,consistency}', $q$
with root as (select id, grp, val from g_parent),
     one as (select val from root where id = :id),
     two as (select val from root where id = :id + 1),
     three as (select val from root where id = :id + 2)
select (select val from one), (select val from two), (select val from three)$q$,
    setup => '\set id random(1, :n_g_parent - 2)', equiv => 'cte.graph_shared_root_sel');

call pgmb.reg('cte.graph_shared_root_selective_branches_not_materialized', '{perf,planning,consistency,oltp}', $q$
with root as not materialized (select id, grp, val from g_parent),
     one as (select val from root where id = :id),
     two as (select val from root where id = :id + 1),
     three as (select val from root where id = :id + 2)
select (select val from one), (select val from two), (select val from three)$q$,
    setup => '\set id random(1, :n_g_parent - 2)', equiv => 'cte.graph_shared_root_sel');

------------------------------------------------------------------------------
-- 18. shared intermediate:  A -> B -> C, D -> Q   (B is the shared one)
------------------------------------------------------------------------------
-- A has one reader and is inlined into B; B has two and becomes the boundary
call pgmb.reg('cte.graph_shared_intermediate_default', '{perf,planning,consistency}', $q$
with a as (select id, grp, val from g_parent),
     b as (select grp, count(*) as n, sum(val) as total from a where id between :id and :id + 499 group by grp),
     c as (select count(*) as groups from b where n > 3),
     d as (select max(total) as mx from b)
select c.groups, d.mx from c, d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_shared_mid');

call pgmb.reg('cte.graph_shared_intermediate_not_materialized', '{perf,planning,consistency}', $q$
with a as (select id, grp, val from g_parent),
     b as not materialized (select grp, count(*) as n, sum(val) as total from a where id between :id and :id + 499 group by grp),
     c as (select count(*) as groups from b where n > 3),
     d as (select max(total) as mx from b)
select c.groups, d.mx from c, d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_shared_mid');

-- the fence one level too low: A materialized, the range filter cannot reach the table
call pgmb.reg('cte.graph_shared_intermediate_root_materialized', '{perf,planning,consistency,olap}', $q$
with a as materialized (select id, grp, val from g_parent),
     b as (select grp, count(*) as n, sum(val) as total from a where id between :id and :id + 499 group by grp),
     c as (select count(*) as groups from b where n > 3),
     d as (select max(total) as mx from b)
select c.groups, d.mx from c, d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_shared_mid');

------------------------------------------------------------------------------
-- 19. repeated leaf: the same CTE read many times by Q
------------------------------------------------------------------------------
select 'with leaf as (select id, grp, val from g_parent where id between :id and :id + 199) select '
       || string_agg(format('(select count(*) from leaf where grp %% 10 = %s)', i), ', ' order by i) as pgmb_sql
from generate_series(0, 9) i \gset
call pgmb.reg('cte.graph_repeated_leaf_10_readers_default', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_leaf10');

select 'with leaf as not materialized (select id, grp, val from g_parent where id between :id and :id + 199) select '
       || string_agg(format('(select count(*) from leaf where grp %% 10 = %s)', i), ', ' order by i) as pgmb_sql
from generate_series(0, 9) i \gset
call pgmb.reg('cte.graph_repeated_leaf_10_readers_not_materialized', '{perf,planning,consistency}', :'pgmb_sql',
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_leaf10');

call pgmb.reg('cte.graph_repeated_leaf_10_readers_as_one_pass', '{perf,planning,consistency}', $q$
with leaf as (select id, grp, val from g_parent where id between :id and :id + 199)
select count(*) filter (where grp % 10 = 0), count(*) filter (where grp % 10 = 1), count(*) filter (where grp % 10 = 2),
       count(*) filter (where grp % 10 = 3), count(*) filter (where grp % 10 = 4), count(*) filter (where grp % 10 = 5),
       count(*) filter (where grp % 10 = 6), count(*) filter (where grp % 10 = 7), count(*) filter (where grp % 10 = 8),
       count(*) filter (where grp % 10 = 9)
from leaf$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_leaf10');

-- the leaf on the inner side of a nested loop: rescanned once per outer row
call pgmb.reg('cte.graph_repeated_leaf_rescanned_per_row', '{perf,planning}', $q$
with leaf as materialized (select id, grp, val from g_parent where id between :id and :id + 199)
select count(*) from leaf a where a.val > (select avg(b.val) from leaf b where b.grp % 10 = a.grp % 10)$q$,
    setup => '\set id random(1, :n_g_parent)');

-- a six-way self-join of one leaf
call pgmb.reg('cte.graph_repeated_leaf_six_way_self_join', '{perf,planning}', $q$
with leaf as (select id, val from g_parent where id between :id and :id + 199)
select count(*) from leaf a join leaf b on b.id = a.id + 1 join leaf c on c.id = b.id + 1
     join leaf d on d.id = c.id + 1 join leaf e on e.id = d.id + 1 join leaf f on f.id = e.id + 1$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 20. nested scopes: WITH inside the definition of a CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_nested_scope_default', '{perf,planning,consistency}', $q$
with a as (
        with x as (select id, grp, val from g_parent where id between :id and :id + 199),
             y as (select grp, sum(val) as total from x group by grp)
        select * from y),
     b as (
        with z as (select grp, total from a where total > 0)
        select count(*) as n, max(total) as mx from z)
select n, mx from b$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_nested_scope');

call pgmb.reg('cte.graph_nested_scope_flattened', '{perf,planning,consistency}', $q$
with x as (select id, grp, val from g_parent where id between :id and :id + 199),
     y as (select grp, sum(val) as total from x group by grp),
     z as (select grp, total from y where total > 0)
select count(*) as n, max(total) as mx from z$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_nested_scope');

-- an inner diamond inside each of two outer CTEs that form a diamond themselves
call pgmb.reg('cte.graph_nested_scope_diamond_in_diamond', '{perf,planning}', $q$
with base as (select id, grp, val from g_parent where id between :id and :id + 199),
     left_side as (
        with l as (select * from base where grp < 50),
             l1 as (select count(*) as n from l), l2 as (select sum(val) as total from l)
        select n, total from l1, l2),
     right_side as (
        with r as (select * from base where grp >= 50),
             r1 as (select count(*) as n from r), r2 as (select sum(val) as total from r)
        select n, total from r1, r2)
select l.n + r.n, l.total + r.total from left_side l, right_side r$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 21. shadowed: a local CTE hides one of the same name from the outer WITH
------------------------------------------------------------------------------
-- left branch sees the outer A, right branch its own A
call pgmb.reg('cte.graph_shadowed_default', '{perf,planning,consistency}', $q$
with a as (select id, val from g_parent where id between :id and :id + 99),
     left_side as (select count(*) as n, sum(val) as total from a),
     right_side as (
        with a as (select id, val from g_parent where id between :id + 100 and :id + 199)
        select count(*) as n, sum(val) as total from a)
select l.n, l.total, r.n, r.total from left_side l, right_side r$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_shadowed');

call pgmb.reg('cte.graph_shadowed_renamed', '{perf,planning,consistency}', $q$
with a as (select id, val from g_parent where id between :id and :id + 99),
     a2 as (select id, val from g_parent where id between :id + 100 and :id + 199),
     left_side as (select count(*) as n, sum(val) as total from a),
     right_side as (select count(*) as n, sum(val) as total from a2)
select l.n, l.total, r.n, r.total from left_side l, right_side r$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_shadowed');

-- the local A is built from the outer A it hides
call pgmb.reg('cte.graph_shadowed_local_built_from_outer', '{perf,planning}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 199),
     narrowed as (
        with a as (select * from a where grp < 50)
        select count(*) as n from a),
     narrower as (
        with a as (select * from a where grp < 50),
             b as (with a as (select * from a where grp < 10) select count(*) as n from a)
        select n from b)
select (select count(*) from a), (select n from narrowed), (select n from narrower)$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- 22. mixed: MATERIALIZED and NOT MATERIALIZED in one diamond
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_mixed_root_materialized_rest_inlined', '{perf,planning,consistency}', $q$
with a as materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as not materialized (select grp, count(*) as n from a group by grp),
     c as not materialized (select grp, sum(val) as total from a group by grp),
     d as not materialized (select b.grp, b.n, c.total from b join c using (grp))
select count(*), sum(n), sum(total) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_diamond');

call pgmb.reg('cte.graph_mixed_root_inlined_branches_materialized', '{perf,planning,consistency}', $q$
with a as not materialized (select id, grp, val from g_parent where id between :id and :id + 199),
     b as materialized (select grp, count(*) as n from a group by grp),
     c as materialized (select grp, sum(val) as total from a group by grp),
     d as not materialized (select b.grp, b.n, c.total from b join c using (grp))
select count(*), sum(n), sum(total) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_diamond');

call pgmb.reg('cte.graph_mixed_one_branch_each', '{perf,planning,consistency}', $q$
with a as (select id, grp, val from g_parent where id between :id and :id + 199),
     b as materialized (select grp, count(*) as n from a group by grp),
     c as not materialized (select grp, sum(val) as total from a group by grp),
     d as (select b.grp, b.n, c.total from b join c using (grp))
select count(*), sum(n), sum(total) from d$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_diamond');

-- a linear chain with alternating settings: the filter of Q stops at the first fence
call pgmb.reg('cte.graph_mixed_alternating_chain', '{perf,planning,consistency,olap}', $q$
with a as not materialized (select id, grp, val from g_parent),
     b as materialized (select id, grp, val * 2 as val from a),
     c as not materialized (select id, grp, val + grp as val from b where grp < 90)
select count(*), sum(val) from c where id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.graph_linear');

------------------------------------------------------------------------------
-- 23. recursive node:  A -> A
------------------------------------------------------------------------------
call pgmb.reg('cte.graph_recursive_node_counter', '{perf,planning}', $q$
with recursive a(n) as (select 1 union all select n + 1 from a where n < 1000)
select count(*), sum(n) from a$q$);

call pgmb.reg('cte.graph_recursive_node_tree', '{perf,planning}', $q$
with recursive a as (
    select id, parent_id, val from g_tree where id = :id
    union all
    select t.id, t.parent_id, t.val from g_tree t join a on t.parent_id = a.id)
select count(*), sum(val) from a$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

-- the recursive node in the middle of a chain:  B -> A (recursive) -> C -> Q
call pgmb.reg('cte.graph_recursive_node_in_chain', '{perf,planning}', $q$
with recursive start as (select id from g_tree where id = :id),
     a as (
        select t.id, t.parent_id, t.val, 0 as lvl from g_tree t join start s on s.id = t.id
        union all
        select t.id, t.parent_id, t.val, a.lvl + 1 from g_tree t join a on t.parent_id = a.id),
     c as (select lvl, count(*) as n, sum(val) as total from a group by lvl)
select count(*), sum(n), sum(total) from c$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

-- two recursive nodes, the second seeded by the first
call pgmb.reg('cte.graph_recursive_two_nodes_chained', '{perf,planning}', $q$
with recursive up as (
        select id, parent_id from g_tree where id = :id
        union all
        select t.id, t.parent_id from g_tree t join up on t.id = up.parent_id),
     down as (
        select id, 0 as lvl from up where parent_id is null
        union all
        select t.id, d.lvl + 1 from g_tree t join down d on t.parent_id = d.id where d.lvl < 2)
select (select count(*) from up) as ancestors, (select count(*) from down) as from_root$q$,
    setup => '\set id random(1, :n_g_tree)');

------------------------------------------------------------------------------
-- 24. recursion with several readers
------------------------------------------------------------------------------
-- the recursion runs once; three branches read its stored result
call pgmb.reg('cte.graph_recursive_three_readers', '{perf,planning,consistency}', $q$
with recursive sub as (
        select id, parent_id, val, 0 as lvl from g_tree where id = :id
        union all
        select t.id, t.parent_id, t.val, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id),
     per_level as (select lvl, count(*) as n from sub group by lvl),
     leaves as (select count(*) as n from sub s where not exists (select 1 from sub c where c.parent_id = s.id)),
     totals as (select sum(val) as total from sub)
select (select count(*) from per_level), (select n from leaves), (select total from totals)$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)', equiv => 'cte.graph_rec_readers');

-- the same with the recursion written three times: three executions
call pgmb.reg('cte.graph_recursive_three_copies', '{perf,planning,consistency}', $q$
with recursive
     s1 as (select id, parent_id, val, 0 as lvl from g_tree where id = :id
            union all select t.id, t.parent_id, t.val, s.lvl + 1 from g_tree t join s1 s on t.parent_id = s.id),
     s2 as (select id, parent_id, val, 0 as lvl from g_tree where id = :id
            union all select t.id, t.parent_id, t.val, s.lvl + 1 from g_tree t join s2 s on t.parent_id = s.id),
     s3 as (select id, parent_id, val, 0 as lvl from g_tree where id = :id
            union all select t.id, t.parent_id, t.val, s.lvl + 1 from g_tree t join s3 s on t.parent_id = s.id),
     per_level as (select lvl, count(*) as n from s1 group by lvl),
     leaves as (select count(*) as n from s2 s where not exists (select 1 from s2 c where c.parent_id = s.id)),
     totals as (select sum(val) as total from s3)
select (select count(*) from per_level), (select n from leaves), (select total from totals)$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)', equiv => 'cte.graph_rec_readers');

-- a recursive result feeding a diamond
call pgmb.reg('cte.graph_recursive_feeds_diamond', '{perf,planning}', $q$
with recursive sub as (
        select id, parent_id, val, 0 as lvl from g_tree where id = :id
        union all
        select t.id, t.parent_id, t.val, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id),
     evens as (select lvl, sum(val) as total from sub where id % 2 = 0 group by lvl),
     odds as (select lvl, sum(val) as total from sub where id % 2 = 1 group by lvl),
     merged as (select lvl, coalesce(e.total, 0) + coalesce(o.total, 0) as total from evens e full join odds o using (lvl))
select count(*), sum(total) from merged$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');

-- one reader needs only a few rows of the recursion, the other needs all
call pgmb.reg('cte.graph_recursive_readers_limit_and_full', '{perf,planning}', $q$
with recursive a(n) as (select 1 union all select n + 1 from a where n < 5000)
select (select max(n) from (select n from a limit 10) s) as first_ten, (select count(*) from a) as everything$q$);
