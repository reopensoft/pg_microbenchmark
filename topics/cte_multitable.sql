-- Topic: cte (part 29) - dependency graphs whose nodes read different tables
-- (the graphs of cte_graph.sql read g_parent almost everywhere). Trees and
-- DAGs with different sources, diamonds and fan-outs whose shared node is a
-- join, star and snowflake schemas, mixed join types between nodes, deep
-- chains that add a table at every level, recursion through two tables.
--
-- Every shape is written once with a {m} placeholder for the directive and
-- registered three times (default, MATERIALIZED, NOT MATERIALIZED), next to
-- an equivalent statement without CTEs; all of them must return the same rows.
-- Float columns are summed as numeric, so that the order of addition does not
-- change the result.

\set pgmb_mt_variants '(values (''default'', ''''), (''materialized'', ''materialized ''), (''not_materialized'', ''not materialized '')) v(lbl, kw)'
\set pgmb_mt_tags '{perf,planning,analyze,consistency}'

------------------------------------------------------------------------------
-- 1. a tree whose leaves read four tables
------------------------------------------------------------------------------
--   p (g_parent) ─┐
--                 ├─ pc ── l ─┐
--   c (g_child) ──┘           ├─ root
--   e (g_events) ─┐           │
--                 ├─ ed ── r ─┘
--   d (g_dim) ────┘
select $t$
with p as {m}(select id, grp from g_parent where id between :id and :id + 99),
     c as {m}(select parent_id, count(*) as n, sum(amount) as amt from g_child
              where parent_id between :id and :id + 99 group by parent_id),
     e as {m}(select cat, val from g_events where entity_id between :e and :e + 9),
     d as {m}(select id, code from g_dim),
     pc as {m}(select p.grp, c.n, c.amt from p join c on c.parent_id = p.id),
     ed as {m}(select e.cat, d.code, e.val from e join d on d.id = e.cat + 1),
     l as {m}(select grp % 5 as k, sum(n) as n, sum(amt) as amt from pc group by grp % 5),
     r as {m}(select cat as k, count(*) as n, sum(val::numeric) as v, max(code) as code from ed group by cat)
select count(*), sum(l.n), sum(l.amt), sum(r.n), sum(r.v), max(r.code) from l join r using (k)$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_tree_four_sources_' || lbl, :'pgmb_mt_tags',
              replace(:'pgmb_t', '{m}', kw), E'\\set id random(1, :n_g_parent)\n\\set e random(1, :n_g_events_entities)',
              'cte.multi_tree_four_sources')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_tree_four_sources_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(l.n), sum(l.amt), sum(r.n), sum(r.v), max(r.code)
from (select p.grp % 5 as k, sum(c.n) as n, sum(c.amt) as amt
      from g_parent p
           join (select parent_id, count(*) as n, sum(amount) as amt from g_child
                 where parent_id between :id and :id + 99 group by parent_id) c on c.parent_id = p.id
      where p.id between :id and :id + 99
      group by p.grp % 5) l
     join (select e.cat as k, count(*) as n, sum(e.val::numeric) as v, max(d.code) as code
           from g_events e join g_dim d on d.id = e.cat + 1
           where e.entity_id between :e and :e + 9
           group by e.cat) r using (k)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set e random(1, :n_g_events_entities)', equiv => 'cte.multi_tree_four_sources');

------------------------------------------------------------------------------
-- 2. a DAG: one node read by two nodes that join it to different tables
------------------------------------------------------------------------------
--            ┌─ a (n ⋈ g_dim) ────┐
--   n ───────┤                    ├─ root (a ⋈ b on n.id)
--  (g_narrow)└─ b (n ⋈ g_parent) ─┘
select $t$
with n as {m}(select id, k_100, k_10k from g_narrow where id between :id and :id + 999),
     a as {m}(select n.id, d.category from n join g_dim d on d.id = n.k_100 % :n_g_dim + 1),
     b as {m}(select n.id, p.grp, p.val from n join g_parent p on p.id = n.k_10k % :n_g_parent + 1)
select count(*), sum(a.category), sum(b.grp), sum(b.val) from a join b using (id)$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_dag_shared_source_' || lbl, :'pgmb_mt_tags',
              replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_narrow)', 'cte.multi_dag_shared_source')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_dag_shared_source_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(d.category), sum(p.grp), sum(p.val)
from g_narrow n
     join g_dim d on d.id = n.k_100 % :n_g_dim + 1
     join g_parent p on p.id = n.k_10k % :n_g_parent + 1
where n.id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.multi_dag_shared_source');

-- the two readers filter the shared node differently: inlined, each copy is
-- filtered at the source; materialized, the whole node is stored first
select $t$
with n as {m}(select id, k_100, k_10k from g_narrow where id between :id and :id + 9999),
     a as {m}(select n.id, d.category from n join g_dim d on d.id = n.k_100 % :n_g_dim + 1 where n.k_100 < 5),
     b as {m}(select n.id, p.grp from n join g_parent p on p.id = n.k_10k % :n_g_parent + 1 where n.k_10k < 500)
select (select count(*) from a), (select sum(category) from a), (select count(*) from b), (select sum(grp) from b)$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_dag_readers_filter_differently_' || lbl,
              :'pgmb_mt_tags', replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_narrow)', 'cte.multi_dag_readers_filter')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_dag_readers_filter_differently_flat', '{perf,planning,analyze,consistency}', $q$
select (select count(*) from g_narrow n join g_dim d on d.id = n.k_100 % :n_g_dim + 1
        where n.id between :id and :id + 9999 and n.k_100 < 5),
       (select sum(d.category) from g_narrow n join g_dim d on d.id = n.k_100 % :n_g_dim + 1
        where n.id between :id and :id + 9999 and n.k_100 < 5),
       (select count(*) from g_narrow n join g_parent p on p.id = n.k_10k % :n_g_parent + 1
        where n.id between :id and :id + 9999 and n.k_10k < 500),
       (select sum(p.grp) from g_narrow n join g_parent p on p.id = n.k_10k % :n_g_parent + 1
        where n.id between :id and :id + 9999 and n.k_10k < 500)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.multi_dag_readers_filter');

------------------------------------------------------------------------------
-- 3. a diamond and a fan-out whose shared node is a join
------------------------------------------------------------------------------
--                      ┌─ l (base ⋈ g_dim) ──┐
--   base (g_parent ⋈ ──┤                     ├─ root
--         g_child)     └─ r (base ⋈ g_tree) ─┘
select $t$
with base as {m}(select p.id as pid, p.dim_id, c.kind, c.amount
                 from g_parent p join g_child c on c.parent_id = p.id where p.id between :id and :id + 19),
     l as {m}(select b.pid, sum(b.amount) as amt, max(d.code) as code from base b join g_dim d on d.id = b.dim_id group by b.pid),
     r as {m}(select b.pid, count(*) as n, max(t.depth) as depth from base b join g_tree t on t.id = b.pid group by b.pid)
select count(*), sum(l.amt), sum(r.n), sum(r.depth), count(distinct l.code) from l join r using (pid)$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_diamond_join_root_' || lbl, :'pgmb_mt_tags',
              replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)', 'cte.multi_diamond_join_root')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_diamond_join_root_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(l.amt), sum(r.n), sum(r.depth), count(distinct l.code)
from (select p.id as pid, sum(c.amount) as amt, max(d.code) as code
      from g_parent p join g_child c on c.parent_id = p.id join g_dim d on d.id = p.dim_id
      where p.id between :id and :id + 19 group by p.id) l
     join (select p.id as pid, count(*) as n, max(t.depth) as depth
           from g_parent p join g_child c on c.parent_id = p.id join g_tree t on t.id = p.id
           where p.id between :id and :id + 19 group by p.id) r using (pid)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_diamond_join_root');

-- the same join read by three branches, each joined to another table
select $t$
with base as {m}(select p.id as pid, p.dim_id, p.grp, c.kind, c.amount
                 from g_parent p join g_child c on c.parent_id = p.id where p.id between :id and :id + 19),
     x as {m}(select sum(b.amount) as v from base b join g_dim d on d.id = b.dim_id where d.category < 5),
     y as {m}(select sum(t.depth) as v from base b join g_tree t on t.id = b.pid),
     z as {m}(select sum(n.k_100) as v from base b join g_narrow n on n.id = b.pid * 8 + b.kind)
select (select v from x), (select v from y), (select v from z)$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_fan_out_join_root_' || lbl, :'pgmb_mt_tags',
              replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)', 'cte.multi_fan_out_join_root')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_fan_out_join_root_flat', '{perf,planning,analyze,consistency}', $q$
select (select sum(c.amount) from g_parent p join g_child c on c.parent_id = p.id join g_dim d on d.id = p.dim_id
        where p.id between :id and :id + 19 and d.category < 5),
       (select sum(t.depth) from g_parent p join g_child c on c.parent_id = p.id join g_tree t on t.id = p.id
        where p.id between :id and :id + 19),
       (select sum(n.k_100) from g_parent p join g_child c on c.parent_id = p.id join g_narrow n on n.id = p.id * 8 + c.kind
        where p.id between :id and :id + 19)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_fan_out_join_root');

------------------------------------------------------------------------------
-- 4. star and snowflake
------------------------------------------------------------------------------
-- star: one fact CTE (g_child), three dimension CTEs joined to it directly
select $t$
with f as {m}(select parent_id, kind, amount from g_child where parent_id between :id and :id + 199),
     dp as {m}(select id, grp from g_parent),
     dk as {m}(select id, category from g_dim),
     dt as {m}(select id, depth from g_tree)
select dp.grp % 10 as g, dk.category, count(*), sum(f.amount), sum(dt.depth)
from f join dp on dp.id = f.parent_id join dk on dk.id = f.kind + 1 join dt on dt.id = f.parent_id
group by 1, 2$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_star_' || lbl, :'pgmb_mt_tags',
              replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)', 'cte.multi_star')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_star_flat', '{perf,planning,analyze,consistency}', $q$
select p.grp % 10 as g, d.category, count(*), sum(c.amount), sum(t.depth)
from g_child c join g_parent p on p.id = c.parent_id join g_dim d on d.id = c.kind + 1 join g_tree t on t.id = c.parent_id
where c.parent_id between :id and :id + 199
group by 1, 2$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_star');

-- snowflake: the dimension of the fact has a dimension of its own, each level a CTE
select $t$
with f as {m}(select parent_id, amount from g_child where parent_id between :id and :id + 199),
     d1 as {m}(select id, dim_id, grp from g_parent),
     d2 as {m}(select id, category from g_dim),
     d12 as {m}(select d1.id, d1.grp, d2.category from d1 join d2 on d2.id = d1.dim_id)
select d12.category, count(*), sum(f.amount), count(distinct d12.grp)
from f join d12 on d12.id = f.parent_id
group by d12.category$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_snowflake_' || lbl, :'pgmb_mt_tags',
              replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)', 'cte.multi_snowflake')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_snowflake_flat', '{perf,planning,analyze,consistency}', $q$
select d.category, count(*), sum(c.amount), count(distinct p.grp)
from g_child c join g_parent p on p.id = c.parent_id join g_dim d on d.id = p.dim_id
where c.parent_id between :id and :id + 199
group by d.category$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_snowflake');

------------------------------------------------------------------------------
-- 5. mixed join types between nodes over different tables
------------------------------------------------------------------------------
-- LEFT JOIN with a filter on the preserved side written outside: it reaches
-- g_parent only when the CTEs are inlined
select $t$
with p as {m}(select id, grp from g_parent),
     c as {m}(select parent_id, count(*) as n, sum(amount) as amt from g_child group by parent_id)
select count(*), sum(c.n), sum(c.amt), count(c.parent_id)
from p left join c on c.parent_id = p.id
where p.id between :id and :id + 99$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_left_join_filter_preserved_side_' || lbl,
              '{perf,planning,analyze,consistency,olap}', replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)',
              'cte.multi_left_join_preserved')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_left_join_filter_preserved_side_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(c.n), sum(c.amt), count(c.parent_id)
from g_parent p
     left join (select parent_id, count(*) as n, sum(amount) as amt from g_child
                where parent_id between :id and :id + 99 group by parent_id) c on c.parent_id = p.id
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_left_join_preserved');

-- a filter on the nullable side turns the LEFT JOIN into an inner join
select $t$
with p as {m}(select id, grp from g_parent where id between :id and :id + 99),
     c as {m}(select parent_id, kind, amount from g_child where parent_id between :id and :id + 99)
select count(*), sum(c.amount) from p left join c on c.parent_id = p.id where c.kind = 3$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_left_join_filter_nullable_side_' || lbl,
              :'pgmb_mt_tags', replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)', 'cte.multi_left_join_nullable')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_left_join_filter_nullable_side_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(c.amount) from g_parent p join g_child c on c.parent_id = p.id
where p.id between :id and :id + 99 and c.kind = 3$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_left_join_nullable');

-- semi join: parents whose entity has an event of category 0
select $t$
with p as {m}(select id, grp from g_parent where id between :id and :id + 99),
     e as {m}(select entity_id from g_events where cat = 0)
select count(*), sum(grp) from p where p.id % :n_g_events_entities + 1 in (select entity_id from e)$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_semi_join_' || lbl,
              '{perf,planning,analyze,consistency,olap}', replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)',
              'cte.multi_semi_join')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_semi_join_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(p.grp) from g_parent p
where p.id between :id and :id + 99
  and exists (select from g_events e where e.entity_id = p.id % :n_g_events_entities + 1 and e.cat = 0)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_semi_join');

-- anti join three ways over two CTEs: NOT EXISTS, LEFT JOIN ... IS NULL, NOT IN
select $t$
with p as {m}(select id, grp from g_parent where id between :id and :id + 99),
     c as {m}(select parent_id from g_child where parent_id between :id and :id + 99 and kind = 7)
select count(*), sum(grp) from p where not exists (select from c where c.parent_id = p.id)$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_anti_join_not_exists_' || lbl,
              :'pgmb_mt_tags', replace(:'pgmb_t', '{m}', kw), '\set id random(1, :n_g_parent)', 'cte.multi_anti_join')
from :pgmb_mt_variants \gexec
call pgmb.reg('cte.multi_anti_join_left_join_is_null', '{perf,planning,analyze,consistency}', $q$
with p as (select id, grp from g_parent where id between :id and :id + 99),
     c as (select distinct parent_id from g_child where parent_id between :id and :id + 99 and kind = 7)
select count(*), sum(p.grp) from p left join c on c.parent_id = p.id where c.parent_id is null$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_anti_join');
call pgmb.reg('cte.multi_anti_join_not_in', '{perf,planning,analyze,consistency}', $q$
with p as (select id, grp from g_parent where id between :id and :id + 99),
     c as (select parent_id from g_child where parent_id between :id and :id + 99 and kind = 7)
select count(*), sum(grp) from p where p.id not in (select parent_id from c)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_anti_join');
call pgmb.reg('cte.multi_anti_join_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(p.grp) from g_parent p
where p.id between :id and :id + 99
  and not exists (select from g_child c where c.parent_id = p.id and c.kind = 7)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.multi_anti_join');

------------------------------------------------------------------------------
-- 6. deep chains that add a table at every level
------------------------------------------------------------------------------
-- Level i looks up one row in the next table of the cycle g_parent, g_dim,
-- g_tree, g_narrow by primary key and adds one of its columns to s. Inlined,
-- the chain becomes one join problem with a relation per level.
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)',
              format('cte.multi_chain_%s_tables_%s', levels, v.lbl), '{perf,planning,analyze,consistency}',
              v.pre || 'with c0 as ' || v.kw || '(select id as k, 0::bigint as s from g_parent where id between :id and :id + 99)'
              || string_agg(format(', c%1$s as %2$s(select c.k, c.s + x.%3$s as s from c%4$s c join %5$s x on x.id = c.k %% %6$s + 1)',
                                   i, v.kw, (array['grp', 'category', 'depth', 'k_100'])[1 + (i - 1) % 4], i - 1,
                                   (array['g_parent', 'g_dim', 'g_tree', 'g_narrow'])[1 + (i - 1) % 4],
                                   (array[':n_g_parent', ':n_g_dim', ':n_g_tree', ':n_g_narrow'])[1 + (i - 1) % 4]), '' order by i)
              || format(' select count(*), sum(s) from c%s', levels) || v.post,
              '\set id random(1, :n_g_parent)', format('cte.multi_chain_%s', levels))
from (values (4), (8), (12)) l(levels),
     (values ('default', '', '', ''), ('materialized', 'materialized ', '', ''),
             ('not_materialized', 'not materialized ', '', ''),
             ('collapse_limit_1', '', E'begin;\nset local from_collapse_limit = 1;\nset local join_collapse_limit = 1;\n', E';\ncommit;'))
     v(lbl, kw, pre, post),
     lateral generate_series(1, levels) i
group by levels, v.lbl, v.kw, v.pre, v.post \gexec

-- the same chains as one statement over the tables
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)',
              format('cte.multi_chain_%s_tables_flat', levels), '{perf,planning,analyze,consistency}',
              'select count(*), sum(' || string_agg(format('x%s.%s', i, (array['grp', 'category', 'depth', 'k_100'])[1 + (i - 1) % 4]), ' + ' order by i)
              || ') from g_parent x0'
              || string_agg(format(' join %1$s x%2$s on x%2$s.id = x0.id %% %3$s + 1',
                                   (array['g_parent', 'g_dim', 'g_tree', 'g_narrow'])[1 + (i - 1) % 4], i,
                                   (array[':n_g_parent', ':n_g_dim', ':n_g_tree', ':n_g_narrow'])[1 + (i - 1) % 4]), '' order by i)
              || ' where x0.id between :id and :id + 99',
              '\set id random(1, :n_g_parent)', format('cte.multi_chain_%s', levels))
from (values (4), (8), (12)) l(levels), lateral generate_series(1, levels) i
group by levels \gexec

------------------------------------------------------------------------------
-- 7. recursion through two tables
------------------------------------------------------------------------------
-- Three levels down g_tree from one node; at every level the node's children
-- in g_child (tree ids are parent ids) and its parent row are joined in.
-- The child totals come from a CTE that the recursive term reads.
select $t$
with recursive cs as {m}(select parent_id, sum(amount) as amt from g_child group by parent_id),
     w(id, depth, amt, grp) as (
         select t.id, 0, coalesce(cs.amt, 0), p.grp
         from g_tree t join g_parent p on p.id = t.id left join cs on cs.parent_id = t.id
         where t.id = :r
         union all
         select t.id, w.depth + 1, w.amt + coalesce(cs.amt, 0), w.grp + p.grp
         from g_tree t join w on t.parent_id = w.id join g_parent p on p.id = t.id
              left join cs on cs.parent_id = t.id
         where w.depth < 3)
select count(*), sum(amt), sum(grp), max(depth) from w$t$ as pgmb_t \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'cte.multi_recursive_two_tables_' || lbl,
              '{perf,planning,analyze,consistency,olap}', replace(:'pgmb_t', '{m}', kw), '\set r random(1, 20)',
              'cte.multi_recursive_two_tables')
from :pgmb_mt_variants \gexec

-- the child totals read per node by a scalar subquery
call pgmb.reg('cte.multi_recursive_two_tables_subquery_per_node', '{perf,planning,analyze,consistency}', $q$
with recursive w(id, depth, amt, grp) as (
    select t.id, 0, coalesce((select sum(amount) from g_child where parent_id = t.id), 0), p.grp
    from g_tree t join g_parent p on p.id = t.id
    where t.id = :r
    union all
    select t.id, w.depth + 1, w.amt + coalesce((select sum(amount) from g_child where parent_id = t.id), 0), w.grp + p.grp
    from g_tree t join w on t.parent_id = w.id join g_parent p on p.id = t.id
    where w.depth < 3)
select count(*), sum(amt), sum(grp), max(depth) from w$q$,
    setup => '\set r random(1, 20)', equiv => 'cte.multi_recursive_two_tables');

-- the depth is known, so the walk can be written as four joins without recursion
call pgmb.reg('cte.multi_recursive_two_tables_flat_levels', '{perf,planning,analyze,consistency}', $q$
with cs as (select parent_id, sum(amount) as amt from g_child group by parent_id),
     n as (select t.id, t.parent_id, coalesce(cs.amt, 0) as amt, p.grp
           from g_tree t join g_parent p on p.id = t.id left join cs on cs.parent_id = t.id),
     l0 as (select id, 0 as depth, amt, grp from n where id = :r),
     l1 as (select n.id, 1 as depth, l0.amt + n.amt as amt, l0.grp + n.grp as grp from n join l0 on n.parent_id = l0.id),
     l2 as (select n.id, 2 as depth, l1.amt + n.amt as amt, l1.grp + n.grp as grp from n join l1 on n.parent_id = l1.id),
     l3 as (select n.id, 3 as depth, l2.amt + n.amt as amt, l2.grp + n.grp as grp from n join l2 on n.parent_id = l2.id),
     w as (select * from l0 union all select * from l1 union all select * from l2 union all select * from l3)
select count(*), sum(amt), sum(grp), max(depth) from w$q$,
    setup => '\set r random(1, 20)', equiv => 'cte.multi_recursive_two_tables');
