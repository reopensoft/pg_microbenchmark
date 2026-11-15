-- Topic: cte (part 6) - CTEs under Nested Loop, Hash Join and Merge Join.
--   joinalgo_<algo>_*      : shapes where the planner picks the algorithm by itself
--   joinalgo_forced_<algo> : one statement forced through each algorithm,
--                            with the CTEs inlined and materialized

------------------------------------------------------------------------------
-- Nested Loop
------------------------------------------------------------------------------
call pgmb.reg('cte.joinalgo_nl_index_inner', '{perf,planning,oltp}', $q$
with p as (select id, grp from g_parent where id between :id and :id + 10),
     c as (select id, parent_id, amount from g_child)
select p.id, c.id as child_id, c.amount from p join c on c.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.joinalgo_nl_materialized_outer', '{perf,planning,oltp}', $q$
with p as materialized (select id, grp from g_parent where id between :id and :id + 10)
select p.id, c.id as child_id, c.amount from p join g_child c on c.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

-- the inner side is a materialized CTE: every outer row rescans the whole CTE
call pgmb.reg('cte.joinalgo_nl_materialized_inner_rescan', '{perf,planning}', $q$
with c as materialized (select parent_id, amount from g_child where parent_id between :id and :id + 100)
select p.id, (select max(amount) from c where c.parent_id = p.id)
from g_parent p where p.id between :id and :id + 100$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.joinalgo_nl_inequality_only', '{perf,planning}', $q$
with a as (select id, val from g_parent where id between :id and :id + 150),
     b as (select id, val from g_parent where id between :id + 151 and :id + 300)
select count(*) from a join b on a.val < b.val and b.val - a.val < 100$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.joinalgo_nl_three_levels', '{perf,planning,oltp}', $q$
with d as (select id, code from g_dim where id = :d),
     p as (select id, dim_id from g_parent),
     c as (select id, parent_id, kind from g_child)
select d.code, count(*) from d join p on p.dim_id = d.id join c on c.parent_id = p.id group by d.code$q$,
    setup => '\set d random(1, :n_g_dim)');

------------------------------------------------------------------------------
-- Hash Join
------------------------------------------------------------------------------
call pgmb.reg('cte.joinalgo_hash_inlined', '{perf,planning}', $q$
with p as (select id, grp from g_parent where grp < 20),
     c as (select parent_id, amount from g_child where kind < 4)
select p.grp, count(*), sum(c.amount) from p join c on c.parent_id = p.id group by p.grp$q$);

call pgmb.reg('cte.joinalgo_hash_materialized_both', '{perf,planning}', $q$
with p as materialized (select id, grp from g_parent where grp < 20),
     c as materialized (select parent_id, amount from g_child where kind < 4)
select p.grp, count(*), sum(c.amount) from p join c on c.parent_id = p.id group by p.grp$q$);

call pgmb.reg('cte.joinalgo_hash_build_on_cte', '{perf,planning}', $q$
with small as materialized (select id from g_parent where grp = :g)
select count(*), sum(c.amount) from g_child c join small s on s.id = c.parent_id$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('cte.joinalgo_hash_two_keys', '{perf,planning}', $q$
with a as (select k_100, k_10k, id from g_narrow where id between :id and :id + 20000),
     b as (select k_100, k_10k from g_narrow where k_skew < 5)
select count(*) from a join b using (k_100, k_10k)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_hash_semi_anti', '{perf,planning}', $q$
with busy as (select parent_id from g_child where kind = :k)
select count(*) filter (where b.parent_id is not null) as with_kind, count(*) as total
from g_parent p left join (select distinct parent_id from busy) b on b.parent_id = p.id$q$,
    setup => '\set k random(0, 7)');

call pgmb.reg('cte.joinalgo_hash_full_join', '{perf,planning}', $q$
with a as (select id from g_narrow where k_100 < 30),
     b as (select id from g_events where cat < 2)
select count(*), count(a.id), count(b.id) from a full join b using (id)$q$);

------------------------------------------------------------------------------
-- Merge Join
------------------------------------------------------------------------------
call pgmb.reg('cte.joinalgo_merge_index_order_both', '{perf,planning}', $q$
with a as (select id, k_10k from g_narrow where id between :id and :id + 30000),
     b as (select id, val from g_events where id between :id and :id + 30000)
select count(*), sum(a.k_10k * b.val) from a join b using (id)$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- sorted materialized CTEs: the planner may reuse their order
call pgmb.reg('cte.joinalgo_merge_sorted_ctes', '{perf,planning}', $q$
with a as materialized (select id, k_10k from g_narrow where id between :id and :id + 30000 order by id),
     b as materialized (select id, val from g_events where id between :id and :id + 30000 order by id)
select count(*), sum(a.k_10k * b.val) from a join b using (id)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_merge_then_ordered_output', '{perf,planning}', $q$
with a as (select id, k_10k from g_narrow where id between :id and :id + 30000),
     b as (select id, val from g_events where id between :id and :id + 30000)
select id, a.k_10k, b.val from a join b using (id) order by id limit 100$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_merge_full_join_ranges', '{perf,planning}', $q$
with a as (select id from g_narrow where id between :id and :id + 20000),
     b as (select id from g_events where id between :id + 10000 and :id + 30000)
select count(*), count(a.id), count(b.id) from a full join b using (id)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_merge_many_duplicates', '{perf,planning}', $q$
with a as (select parent_id, id from g_child where parent_id between :id and :id + 300 order by parent_id),
     b as (select parent_id, amount from g_child where parent_id between :id and :id + 300 order by parent_id)
select count(*), sum(b.amount) from a join b using (parent_id)$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- one statement, three algorithms, inlined and materialized
------------------------------------------------------------------------------
call pgmb.reg('cte.joinalgo_forced_nestloop_inlined', '{perf}', $q$
begin;
set local enable_hashjoin = off;
set local enable_mergejoin = off;
with a as (select id, k_100 from g_narrow where id between :id and :id + 1000),
     b as (select id, val from g_events where id between :id and :id + 1000)
select count(*), sum(a.k_100 * b.val) from a join b using (id);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_forced_hash_inlined', '{perf}', $q$
begin;
set local enable_nestloop = off;
set local enable_mergejoin = off;
with a as (select id, k_100 from g_narrow where id between :id and :id + 1000),
     b as (select id, val from g_events where id between :id and :id + 1000)
select count(*), sum(a.k_100 * b.val) from a join b using (id);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_forced_merge_inlined', '{perf}', $q$
begin;
set local enable_nestloop = off;
set local enable_hashjoin = off;
with a as (select id, k_100 from g_narrow where id between :id and :id + 1000),
     b as (select id, val from g_events where id between :id and :id + 1000)
select count(*), sum(a.k_100 * b.val) from a join b using (id);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_forced_nestloop_materialized', '{perf}', $q$
begin;
set local enable_hashjoin = off;
set local enable_mergejoin = off;
with a as materialized (select id, k_100 from g_narrow where id between :id and :id + 1000),
     b as materialized (select id, val from g_events where id between :id and :id + 1000)
select count(*), sum(a.k_100 * b.val) from a join b using (id);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_forced_hash_materialized', '{perf}', $q$
begin;
set local enable_nestloop = off;
set local enable_mergejoin = off;
with a as materialized (select id, k_100 from g_narrow where id between :id and :id + 1000),
     b as materialized (select id, val from g_events where id between :id and :id + 1000)
select count(*), sum(a.k_100 * b.val) from a join b using (id);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.joinalgo_forced_merge_materialized', '{perf}', $q$
begin;
set local enable_nestloop = off;
set local enable_hashjoin = off;
with a as materialized (select id, k_100 from g_narrow where id between :id and :id + 1000),
     b as materialized (select id, val from g_events where id between :id and :id + 1000)
select count(*), sum(a.k_100 * b.val) from a join b using (id);
commit;$q$,
    setup => '\set id random(1, :n_g_narrow)');
