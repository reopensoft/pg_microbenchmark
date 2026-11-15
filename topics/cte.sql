-- Topic: common table expressions.
-- Dependency shapes (chain, diamond, multi-reader), boundary cases, recursion,
-- data-modifying CTEs, plain and hard joins, syntax errors.

------------------------------------------------------------------------------
-- dependency shapes
------------------------------------------------------------------------------
call pgmb.reg('cte.inline_point', '{perf,planning,oltp}', $q$
with p as (select * from g_parent where id = :id)
select id, grp, val from p$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.chain_5', '{perf,planning,oltp}', $q$
with a as (select id, parent_id, amount from g_child where parent_id = :id),
     b as (select * from a where amount > 10),
     c as (select parent_id, count(*) as cnt, sum(amount) as total from b group by parent_id),
     d as (select c.*, p.grp, p.dim_id from c join g_parent p on p.id = c.parent_id),
     e as (select d.*, m.code from d join g_dim m on m.id = d.dim_id)
select * from e$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.diamond', '{perf,planning,oltp}', $q$
with base as (select parent_id, kind, amount from g_child where parent_id between :id and :id + 20),
     l as (select parent_id, sum(amount) as s from base where kind < 4 group by parent_id),
     r as (select parent_id, max(amount) as m from base where kind >= 4 group by parent_id)
select parent_id, l.s, r.m from l full join r using (parent_id)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.multi_reader_3', '{perf,planning}', $q$
with hot as (select id, grp, val from g_parent where grp = :grp)
select (select count(*) from hot),
       (select max(val) from hot),
       (select min(val) from hot where id % 2 = 0)$q$,
    setup => '\set grp random(0, 99)');

call pgmb.reg('cte.fan_out_fan_in', '{perf,planning}', $q$
with src as (select id, k_100, k_10k from g_narrow where id between :id and :id + 499),
     a as (select k_100, count(*) as n from src group by k_100),
     b as (select k_100, max(k_10k) as mx from src group by k_100),
     c as (select k_100, min(k_10k) as mn from src group by k_100),
     j as (select a.k_100, a.n, b.mx, c.mn from a join b using (k_100) join c using (k_100))
select count(*), sum(n), max(mx), min(mn) from j$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- boundary cases
------------------------------------------------------------------------------
call pgmb.reg('cte.unused', '{perf,planning,oltp}', $q$
with unused as (select * from g_child),
     unused2 as (select count(*) from g_events)
select id from g_parent where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.empty_join', '{perf,planning,oltp}', $q$
with e as (select id from g_parent where false)
select c.id from g_child c join e on e.id = c.parent_id$q$);

call pgmb.reg('cte.nested_shadow', '{perf,planning,oltp}', $q$
with a as (select 1 as lvl, id from g_parent where id = :id)
select * from (with a as (select 2 as lvl, id from a) select * from a) s$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.in_subquery', '{perf,planning,oltp}', $q$
select p.id, p.val
from g_parent p
where p.id in (with c as (select parent_id from g_child where id between :id and :id + 20)
               select parent_id from c)$q$,
    setup => '\set id random(1, :n_g_child)');

select string_agg(format('(%s)', i), ',') as pgmb_vals from generate_series(1, 200) i \gset
call pgmb.reg('cte.values_200_join', '{perf,planning}', format($q$
with v(x) as (values %s)
select count(*), sum(p.val) from v join g_parent p on p.id = v.x$q$, :'pgmb_vals'));

------------------------------------------------------------------------------
-- joins
------------------------------------------------------------------------------
call pgmb.reg('cte.join_plain', '{perf,planning,oltp}', $q$
with p as (select id, grp, dim_id from g_parent where id between :id and :id + 10),
     c as (select parent_id, count(*) as n from g_child where parent_id between :id and :id + 10 group by parent_id)
select p.id, p.grp, d.code, c.n
from p join g_dim d on d.id = p.dim_id left join c on c.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.join_hard', '{perf,planning}', $q$
with a as (select id, k_100, k_10k from g_narrow where id between :id and :id + 200),
     b as (select id, k_100, k_10k from g_narrow where id between :id + 100 and :id + 300)
select count(*)
from a join b on a.k_100 < b.k_100 and (a.k_10k = b.k_10k or a.id = b.id)$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- recursion
------------------------------------------------------------------------------
call pgmb.reg('cte.recursive_counter', '{perf,planning}', $q$
with recursive t(n) as (values (1) union all select n + 1 from t where n < 1000)
select sum(n) from t$q$);

call pgmb.reg('cte.recursive_tree_descend', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, t.parent_id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 4)
select count(*), max(lvl) from sub$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.recursive_tree_ascend', '{perf,planning,oltp}', $q$
with recursive up as (
    select id, parent_id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, t.parent_id, u.lvl + 1 from g_tree t join up u on t.id = u.parent_id)
select count(*) from up$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.recursive_graph_cycle', '{perf,planning}', $q$
with recursive walk(node, depth) as (
    select :id::bigint, 0
    union all
    select g.dst, w.depth + 1 from g_graph g join walk w on g.src = w.node where w.depth < 3)
cycle node set is_cycle using path
select count(*), count(*) filter (where is_cycle) from walk$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

call pgmb.reg('cte.recursive_search_bfs', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id from g_tree where id = :id
    union all
    select t.id, t.parent_id from g_tree t join sub s on t.parent_id = s.id)
search breadth first by id set ord
select id from sub order by ord limit 50$q$,
    setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.recursive_union_dedup', '{perf,planning,olap}', $q$
with recursive r(node) as (
    select :id::bigint
    union
    select g.dst from g_graph g join r on g.src = r.node)
select count(*) from r$q$,
    setup => '\set id random(1, :n_g_graph_nodes)');

------------------------------------------------------------------------------
-- data-modifying CTEs
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_update_returning', '{perf,planning,oltp}', $q$
with u as (update g_parent set val = val + 1, updated_at = now() where id = :id returning id, val)
select * from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.dml_insert_returning', '{perf,planning,oltp}', $q$
with ins as (insert into g_child (parent_id, seq, kind, amount, ts, note)
             values (:id, 0, 1, 1.00, now(), 'cte') returning id)
select id from ins$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.dml_delete_reinsert', '{perf,planning,oltp}', $q$
with d as (delete from g_child where id = :id returning *)
insert into g_child select * from d$q$,
    kind => 'write', setup => '\set id random(1, :n_g_child)');

call pgmb.reg('cte.dml_two_writers', '{perf,planning,oltp}', $q$
with up as (update g_parent set val = val - 1 where id = :a returning id),
     up2 as (update g_parent set val = val + 1 where id = :a + 1 returning id)
select (select count(*) from up) + (select count(*) from up2)$q$,
    kind => 'write', setup => '\set a random(1, :n_g_parent - 1)');

------------------------------------------------------------------------------
-- errors
------------------------------------------------------------------------------
call pgmb.reg('cte.err_forward_reference', '{errors}',
    $q$with a as (select * from b), b as (select 1) select * from a$q$, expect_error => '42P01');
call pgmb.reg('cte.err_duplicate_name', '{errors}',
    $q$with a as (select 1), a as (select 2) select * from a$q$, expect_error => '42712');
call pgmb.reg('cte.err_recursive_no_union', '{errors}',
    $q$with recursive t as (select * from t) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_recursive_aggregate', '{errors}',
    $q$with recursive t(n) as (select 1 union all select sum(n)::int from t) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_recursive_type_mismatch', '{errors}',
    $q$with recursive t(n) as (select 1 union all select n + 1.5 from t where n < 3) select * from t$q$, expect_error => '42804');
call pgmb.reg('cte.err_dml_not_top_level', '{errors}',
    $q$select * from (with x as (delete from g_parent where false returning *) select * from x) s$q$, expect_error => '0A000');
