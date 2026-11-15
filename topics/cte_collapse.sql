-- Topic: cte (part 24) - how inlining changes the size of the join problem.
-- An inlined CTE is a subquery; the planner merges it into the outer query
-- while the merged FROM list stays within from_collapse_limit (8), and searches
-- join orders exhaustively below geqo_threshold (12 relations). A MATERIALIZED
-- CTE is a fence: it is planned on its own and joined as one relation.
-- Tables are joined along primary keys (row i with row i+1), so every order is
-- cheap to execute and the planning time is what differs. The planning check
-- records it; perf shows planning and execution together.

------------------------------------------------------------------------------
-- N single-table CTEs joined in the main query: an N-way join either way
------------------------------------------------------------------------------
select format($f$call pgmb.reg('cte.collapse_%1$s_single_table_ctes_%2$s', '{perf,planning,analyze,consistency}', %3$L, setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_single_%1$s')$f$, n, lbl,
              'with ' || (select string_agg(format('c%s as %s(select id, val from g_parent where id between :id + %s and :id + %s)', i, kw, i, i + 99), E',\n     ' order by i) from generate_series(1, n) i)
              || E'\nselect count(*), sum(c1.val) from c1'
              || (select string_agg(format(' join c%s on c%s.id = c%s.id + 1', i, i, i - 1), '' order by i) from generate_series(2, n) i))
from (values (4), (8), (9), (12), (16)) v(n), (values ('inlined', ''), ('materialized', 'materialized ')) w(lbl, kw) \gexec

-- the same joins written without CTEs
select format($f$call pgmb.reg('cte.collapse_%1$s_tables_plain_join', '{perf,planning,analyze,consistency}', %2$L, setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_single_%1$s')$f$, n,
              'select count(*), sum(c1.val) from g_parent c1'
              || (select string_agg(format(' join g_parent c%s on c%s.id = c%s.id + 1', i, i, i - 1), '' order by i) from generate_series(2, n) i)
              || ' where c1.id between :id + 1 and :id + 100')
from (values (4), (8), (9), (12), (16)) v(n) \gexec

------------------------------------------------------------------------------
-- CTEs that are joins themselves: k CTEs of m tables each
-- 2 x 4 = 8 relations fit into from_collapse_limit, 2 x 5 and 3 x 4 do not,
-- so there the subqueries stay separate planning problems even when inlined
------------------------------------------------------------------------------
select format($f$call pgmb.reg('cte.collapse_%1$s_ctes_of_%2$s_tables_%3$s', '{perf,planning,analyze,consistency}', %4$L, setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_%1$sx%2$s')$f$, k, m, lbl,
              'with ' || (select string_agg(format('c%s as %s(select t1.id, t1.val from g_parent t1%s where t1.id between :id + %s and :id + %s)', j, kw,
                              (select string_agg(format(' join g_parent t%s on t%s.id = t%s.id + 1', i, i, i - 1), '' order by i) from generate_series(2, m) i),
                              j, j + 99), E',\n     ' order by j) from generate_series(1, k) j)
              || E'\nselect count(*), sum(c1.val) from c1'
              || (select string_agg(format(' join c%s on c%s.id = c%s.id + 1', j, j, j - 1), '' order by j) from generate_series(2, k) j))
from (values (2, 4), (2, 5), (3, 4), (4, 4)) v(k, m), (values ('inlined', ''), ('materialized', 'materialized ')) w(lbl, kw) \gexec

------------------------------------------------------------------------------
-- the limits moved: 3 CTEs of 4 tables under different settings
------------------------------------------------------------------------------
select 'with ' || (select string_agg(format('c%s as (select t1.id, t1.val from g_parent t1 join g_parent t2 on t2.id = t1.id + 1 join g_parent t3 on t3.id = t2.id + 1 join g_parent t4 on t4.id = t3.id + 1 where t1.id between :id + %s and :id + %s)', j, j, j + 99), E',\n     ' order by j) from generate_series(1, 3) j)
       || E'\nselect count(*), sum(c1.val) from c1 join c2 on c2.id = c1.id + 1 join c3 on c3.id = c2.id + 1' as pgmb_q \gset

-- no flattening at all: every CTE is planned alone, the outer join is 3-way
call pgmb.reg('cte.collapse_3x4_from_collapse_limit_1', '{perf,planning,analyze,consistency}',
    E'begin;\nset local from_collapse_limit = 1;\n' || :'pgmb_q' || E';\ncommit;',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_3x4_limits');

-- everything flattened into one 12-relation problem, searched exhaustively
call pgmb.reg('cte.collapse_3x4_limits_20_exhaustive', '{perf,planning,analyze,consistency}',
    E'begin;\nset local from_collapse_limit = 20;\nset local join_collapse_limit = 20;\nset local geqo = off;\n' || :'pgmb_q' || E';\ncommit;',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_3x4_limits');

-- the same 12 relations handed to the genetic optimizer
call pgmb.reg('cte.collapse_3x4_limits_20_geqo', '{perf,planning,analyze,consistency}',
    E'begin;\nset local from_collapse_limit = 20;\nset local join_collapse_limit = 20;\nset local geqo = on;\nset local geqo_threshold = 12;\n' || :'pgmb_q' || E';\ncommit;',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_3x4_limits');

-- the written order kept inside each CTE
call pgmb.reg('cte.collapse_3x4_join_collapse_limit_1', '{perf,planning,analyze,consistency}',
    E'begin;\nset local join_collapse_limit = 1;\n' || :'pgmb_q' || E';\ncommit;',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_3x4_limits');

------------------------------------------------------------------------------
-- 16 relations: exhaustive search, genetic search, and fences
------------------------------------------------------------------------------
select 'with ' || (select string_agg(format('c%s as (select id, val from g_parent where id between :id + %s and :id + %s)', i, i, i + 99), E',\n     ' order by i) from generate_series(1, 16) i)
       || E'\nselect count(*), sum(c1.val) from c1'
       || (select string_agg(format(' join c%s on c%s.id = c%s.id + 1', i, i, i - 1), '' order by i) from generate_series(2, 16) i) as pgmb_q \gset

call pgmb.reg('cte.collapse_16_relations_default_limits', '{perf,planning,analyze,consistency}', :'pgmb_q',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_16');

call pgmb.reg('cte.collapse_16_relations_exhaustive', '{perf,planning,analyze,consistency}',
    E'begin;\nset local from_collapse_limit = 20;\nset local join_collapse_limit = 20;\nset local geqo = off;\n' || :'pgmb_q' || E';\ncommit;',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_16');

call pgmb.reg('cte.collapse_16_relations_geqo', '{perf,planning,analyze,consistency}',
    E'begin;\nset local from_collapse_limit = 20;\nset local join_collapse_limit = 20;\nset local geqo = on;\n' || :'pgmb_q' || E';\ncommit;',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))', equiv => 'cte.collapse_16');

-- fences by hand: four materialized CTEs of four tables each
select 'with ' || (select string_agg(format('c%s as materialized (select t1.id, t1.val from g_parent t1 join g_parent t2 on t2.id = t1.id + 1 join g_parent t3 on t3.id = t2.id + 1 join g_parent t4 on t4.id = t3.id + 1 where t1.id between :id + %s and :id + %s)', j, (j - 1) * 4 + 1, (j - 1) * 4 + 100), E',\n     ' order by j) from generate_series(1, 4) j)
       || E'\nselect count(*) from c1 join c2 on c2.id = c1.id + 4 join c3 on c3.id = c2.id + 4 join c4 on c4.id = c3.id + 4' as pgmb_q \gset
call pgmb.reg('cte.collapse_16_relations_as_four_fenced_groups', '{perf,planning,analyze}', :'pgmb_q',
    setup => '\set id random(1, greatest(1, :n_g_parent - 200))');

------------------------------------------------------------------------------
-- when the fence costs more than planning saves: a star around one row
------------------------------------------------------------------------------
-- inlined: the planner starts from the single row and reaches the others by index
call pgmb.reg('cte.collapse_star_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with p as (select id, dim_id, val from g_parent),
     ch as (select parent_id, count(*) as n, sum(amount) as total from g_child group by parent_id),
     d as (select id, category from g_dim),
     nr as (select id, k_100 from g_narrow)
select p.id, p.val, ch.n, ch.total, d.category, nr.k_100
from p left join ch on ch.parent_id = p.id join d on d.id = p.dim_id join nr on nr.id = p.id
where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.collapse_star');

-- materialized: four full results are computed to answer for one row
call pgmb.reg('cte.collapse_star_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with p as materialized (select id, dim_id, val from g_parent),
     ch as materialized (select parent_id, count(*) as n, sum(amount) as total from g_child group by parent_id),
     d as materialized (select id, category from g_dim),
     nr as materialized (select id, k_100 from g_narrow)
select p.id, p.val, ch.n, ch.total, d.category, nr.k_100
from p left join ch on ch.parent_id = p.id join d on d.id = p.dim_id join nr on nr.id = p.id
where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.collapse_star');
