-- Topic: subq - nested queries without WITH, in every place a query can sit:
-- FROM, the select list, JOIN, LATERAL, WHERE, LIMIT and OFFSET, GROUP BY and
-- HAVING; several levels of nesting, correlated and uncorrelated; and the same
-- query written as subqueries and as CTEs.
--
-- Each form stands next to an equivalent one (a flat query, a join, a CTE)
-- in a consistency group: they must return the same rows. Floats are summed
-- as numeric, so that the order of addition does not change the result.

------------------------------------------------------------------------------
-- FROM: derived tables, pull-up and the barriers that stop it
------------------------------------------------------------------------------
-- the outer filter travels through 1, 3 and 10 levels of derived tables
call pgmb.reg('subq.from_levels_1', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val) from (select id, val from g_parent) s where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.from_levels');
call pgmb.reg('subq.from_levels_3', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val)
from (select id, val from (select id, val from (select id, val from g_parent) s1) s2) s3
where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.from_levels');
select 'select count(*), sum(val) from ' || repeat('(select id, val from ', 10) || 'g_parent'
       || string_agg(format(') s%s', i), '' order by i) || ' where id between :id and :id + 99' as pgmb_sq10
from generate_series(1, 10) i \gset
call pgmb.reg('subq.from_levels_10', '{perf,planning,analyze,consistency,oltp}', :'pgmb_sq10',
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.from_levels');
call pgmb.reg('subq.from_levels_flat', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val) from g_parent where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.from_levels');

-- OFFSET 0 keeps the derived table from being pulled up: the filter stays outside
call pgmb.reg('subq.from_barrier_offset_0', '{perf,planning,analyze,consistency,olap}', $q$
select count(*), sum(val) from (select id, val from g_parent offset 0) s where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.from_levels');
-- a volatile function in the select list of the derived table
call pgmb.reg('subq.from_barrier_volatile_column', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from (select id, val, random() as r from g_parent) s where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.from_levels');

-- an aggregate: a filter on the group key moves inside, one on the aggregate does not
call pgmb.reg('subq.from_aggregate_filter_on_group_key', '{perf,planning,analyze,consistency}', $q$
select grp, n, total from (select grp, count(*) as n, sum(val) as total from g_parent group by grp) s where grp = :g$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.from_aggregate');
call pgmb.reg('subq.from_aggregate_filter_on_group_key_flat', '{perf,planning,analyze,consistency}', $q$
select grp, count(*), sum(val) from g_parent where grp = :g group by grp$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.from_aggregate');
call pgmb.reg('subq.from_aggregate_filter_on_aggregate', '{perf,planning,analyze,consistency,olap}', $q$
select count(*), sum(n) from (select grp, count(*) as n from g_parent group by grp) s where n > :m$q$,
    setup => '\set m random(1, 20)', equiv => 'subq.from_aggregate_having');
call pgmb.reg('subq.from_aggregate_filter_on_aggregate_as_having', '{perf,planning,analyze,consistency,olap}', $q$
select count(*), sum(n) from (select grp, count(*) as n from g_parent group by grp having count(*) > :m) s$q$,
    setup => '\set m random(1, 20)', equiv => 'subq.from_aggregate_having');

-- DISTINCT and a window partitioned by the filtered column: the filter moves inside
call pgmb.reg('subq.from_distinct', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(dim_id) from (select distinct grp, dim_id from g_parent) s where grp = :g$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.from_distinct');
call pgmb.reg('subq.from_distinct_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(dim_id) from (select distinct grp, dim_id from g_parent where grp = :g) s$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.from_distinct');
call pgmb.reg('subq.from_window_partition_key', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from (select id, grp, val, row_number() over (partition by grp order by id) as rn from g_parent) s
where grp = :g and rn <= 3$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.from_window');
call pgmb.reg('subq.from_window_partition_key_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from (select id, val, row_number() over (order by id) as rn from g_parent where grp = :g) s
where rn <= 3$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.from_window');

------------------------------------------------------------------------------
-- the select list: scalar subqueries
------------------------------------------------------------------------------
-- uncorrelated: computed once (InitPlan)
call pgmb.reg('subq.select_uncorrelated_scalar', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val - (select max(val) from g_parent where grp = 0)) from g_parent where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_uncorrelated');
call pgmb.reg('subq.select_uncorrelated_scalar_as_cross_join', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(p.val - m.v) from g_parent p, (select max(val) as v from g_parent where grp = 0) m
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_uncorrelated');

-- correlated: computed per row (SubPlan); two of them in one list
call pgmb.reg('subq.select_correlated_two', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(n), sum(amt)
from (select p.id,
             (select count(*) from g_child c where c.parent_id = p.id) as n,
             (select coalesce(sum(amount), 0) from g_child c where c.parent_id = p.id) as amt
      from g_parent p where p.id between :id and :id + 99) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_correlated');
call pgmb.reg('subq.select_correlated_two_as_left_join', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(n), sum(amt)
from (select p.id, count(c.id) as n, coalesce(sum(c.amount), 0) as amt
      from g_parent p left join g_child c on c.parent_id = p.id
      where p.id between :id and :id + 99 group by p.id) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_correlated');

-- a scalar subquery nested in another: the largest amount among the children
-- of the smallest kind
call pgmb.reg('subq.select_nested_scalar', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(m)
from (select p.id,
             (select max(c.amount) from g_child c
              where c.parent_id = p.id and c.kind = (select min(c2.kind) from g_child c2 where c2.parent_id = p.id)) as m
      from g_parent p where p.id between :id and :id + 99) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_nested');
call pgmb.reg('subq.select_nested_scalar_as_window', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(m)
from (select p.id, max(c.amount) filter (where c.kind = c.min_kind) as m
      from g_parent p
           left join (select parent_id, kind, amount, min(kind) over (partition by parent_id) as min_kind from g_child) c
             on c.parent_id = p.id
      where p.id between :id and :id + 99 group by p.id) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_nested');

-- ARRAY(subquery) and EXISTS(subquery) as values
call pgmb.reg('subq.select_array_and_exists', '{perf,planning,analyze,consistency,oltp}', $q$
select p.id,
       array(select c.id from g_child c where c.parent_id = p.id order by c.id) as children,
       exists(select from g_child c where c.parent_id = p.id and c.kind = 7) as has_kind_7
from g_parent p where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_array_exists');
call pgmb.reg('subq.select_array_and_exists_as_aggregates', '{perf,planning,analyze,consistency,oltp}', $q$
select p.id,
       coalesce(array_agg(c.id order by c.id) filter (where c.id is not null), '{}') as children,
       coalesce(bool_or(c.kind = 7), false) as has_kind_7
from g_parent p left join g_child c on c.parent_id = p.id
where p.id between :id and :id + 19 group by p.id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.select_array_exists');

call pgmb.reg('subq.err_select_scalar_two_rows', '{errors,needs_data}',
    $q$select (select id from g_parent where id <= 2)$q$, expect_error => '21000');
call pgmb.reg('subq.err_select_scalar_two_columns', '{errors}',
    $q$select (select 1, 2)$q$, expect_error => '42601');

------------------------------------------------------------------------------
-- JOIN: derived tables on either side
------------------------------------------------------------------------------
-- 100 parents against the children totals of 100 parents, half of them the same
select $t$
select count(*), count(a.id), count(b.parent_id), sum(b.amt)
from (select id, grp from g_parent where id between :id and :id + 99) a
     {j} join (select parent_id, sum(amount) as amt from g_child
               where parent_id between :id + 50 and :id + 149 group by parent_id) b on b.parent_id = a.id$t$ as pgmb_t \gset
select $t$
with a as (select id, grp from g_parent where id between :id and :id + 99),
     b as (select parent_id, sum(amount) as amt from g_child where parent_id between :id + 50 and :id + 149 group by parent_id)
select count(*), count(a.id), count(b.parent_id), sum(b.amt) from a {j} join b on b.parent_id = a.id$t$ as pgmb_tc \gset
select format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'subq.join_derived_' || lower(j), '{perf,planning,analyze,consistency}',
              replace(:'pgmb_t', '{j}', j), '\set id random(1, :n_g_parent)', 'subq.join_derived_' || lower(j)),
       format('call pgmb.reg(%L, %L, %L, setup => %L, equiv => %L)', 'subq.join_derived_' || lower(j) || '_as_cte', '{perf,planning,analyze,consistency}',
              replace(:'pgmb_tc', '{j}', j), '\set id random(1, :n_g_parent)', 'subq.join_derived_' || lower(j))
from unnest(array['INNER', 'LEFT', 'RIGHT', 'FULL']) j \gexec

-- a subquery in the ON condition against the same condition in WHERE
call pgmb.reg('subq.join_subquery_in_on', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(c.amount) from g_parent p
     join g_child c on c.parent_id = p.id and c.kind = (select min(kind) + 3 from g_child where parent_id = :id)
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.join_on');
call pgmb.reg('subq.join_subquery_in_where', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(c.amount) from g_parent p join g_child c on c.parent_id = p.id
where p.id between :id and :id + 99 and c.kind = (select min(kind) + 3 from g_child where parent_id = :id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.join_on');

-- four derived tables in one join, with and without join reordering
select $t$
select count(*), sum(c.amt), sum(d.category), sum(t.depth)
from (select id, dim_id from g_parent where id between :id and :id + 99) p
     join (select parent_id, sum(amount) as amt from g_child where parent_id between :id and :id + 99 group by parent_id) c
       on c.parent_id = p.id
     join (select id, category from g_dim) d on d.id = p.dim_id
     join (select id, depth from g_tree) t on t.id = p.id$t$ as pgmb_t \gset
call pgmb.reg('subq.join_four_derived', '{perf,planning,analyze,consistency}', :'pgmb_t',
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.join_four');
call pgmb.reg('subq.join_four_derived_join_collapse_limit_1', '{perf,planning,analyze,consistency}',
    E'begin;\nset local join_collapse_limit = 1;\nset local from_collapse_limit = 1;\n' || :'pgmb_t' || E';\ncommit;',
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.join_four');
call pgmb.reg('subq.join_four_tables_flat', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(c.amt), sum(d.category), sum(t.depth)
from g_parent p
     join (select parent_id, sum(amount) as amt from g_child where parent_id between :id and :id + 99 group by parent_id) c
       on c.parent_id = p.id
     join g_dim d on d.id = p.dim_id join g_tree t on t.id = p.id
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.join_four');

------------------------------------------------------------------------------
-- LATERAL
------------------------------------------------------------------------------
-- the three largest children of each parent, against a window
call pgmb.reg('subq.lateral_top3', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(t.amount) from g_parent p,
     lateral (select amount from g_child c where c.parent_id = p.id order by amount desc, id limit 3) t
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_top3');
call pgmb.reg('subq.lateral_top3_as_window', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(amount)
from (select amount, row_number() over (partition by parent_id order by amount desc, id) as rn
      from g_child where parent_id between :id and :id + 99) s
where rn <= 3$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_top3');

-- a chain: each LATERAL reads the one before it
call pgmb.reg('subq.lateral_chain', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(b.amt), sum(c.depth)
from g_parent p,
     lateral (select sum(amount) as amt, max(kind) as k from g_child where parent_id = p.id) b,
     lateral (select depth from g_tree where id = p.id + coalesce(b.k, 0)) c
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_chain');
call pgmb.reg('subq.lateral_chain_as_joins', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(b.amt), sum(t.depth)
from g_parent p
     left join (select parent_id, sum(amount) as amt, max(kind) as k from g_child group by parent_id) b on b.parent_id = p.id
     join g_tree t on t.id = p.id + coalesce(b.k, 0)
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_chain');

-- LEFT JOIN LATERAL keeps parents for which the subquery returns nothing
call pgmb.reg('subq.lateral_left_join_empty_side', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), count(t.amount), sum(t.amount) from g_parent p
     left join lateral (select amount from g_child c where c.parent_id = p.id and c.kind = 7 order by amount desc limit 1) t on true
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_left');
call pgmb.reg('subq.lateral_left_join_empty_side_as_aggregate', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), count(m), sum(m) from g_parent p
     left join (select parent_id, max(amount) as m from g_child where kind = 7 group by parent_id) t on t.parent_id = p.id
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_left');

-- a per-row LIMIT, which only LATERAL allows
call pgmb.reg('subq.lateral_limit_from_outer_row', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(t.amount) from g_parent p,
     lateral (select amount from g_child c where c.parent_id = p.id order by amount desc, id limit p.grp % 4) t
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_limit');
call pgmb.reg('subq.lateral_limit_from_outer_row_as_window', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(amount)
from (select c.amount, p.grp, row_number() over (partition by c.parent_id order by c.amount desc, c.id) as rn
      from g_parent p join g_child c on c.parent_id = p.id where p.id between :id and :id + 99) s
where rn <= grp % 4$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_limit');

-- Memoize in front of a LATERAL subquery whose key repeats (few dimensions)
\set pgmb_sq_memo 'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\nset local enable_material = off;\n'
\set pgmb_sq_nomemo 'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\nset local enable_material = off;\nset local enable_memoize = off;\n'
call pgmb.reg('subq.lateral_memoize_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_sq_memo' || $q$
select count(*), sum(d.n) from g_parent p,
     lateral (select count(*) as n from g_parent p2 where p2.dim_id = p.dim_id and p2.grp = 0) d
where p.id between :id and :id + 999$q$ || E';\ncommit;',
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_memoize');
call pgmb.reg('subq.lateral_memoize_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_sq_nomemo' || $q$
select count(*), sum(d.n) from g_parent p,
     lateral (select count(*) as n from g_parent p2 where p2.dim_id = p.dim_id and p2.grp = 0) d
where p.id between :id and :id + 999$q$ || E';\ncommit;',
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.lateral_memoize');

------------------------------------------------------------------------------
-- WHERE: semi and anti joins, quantified comparisons, nesting
------------------------------------------------------------------------------
-- parents with a child of kind 3, four ways
call pgmb.reg('subq.where_in', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val) from g_parent where id between :id and :id + 99
  and id in (select parent_id from g_child where kind = 3)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_semi');
call pgmb.reg('subq.where_exists', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val) from g_parent p where id between :id and :id + 99
  and exists (select from g_child c where c.parent_id = p.id and c.kind = 3)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_semi');
call pgmb.reg('subq.where_any', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val) from g_parent where id between :id and :id + 99
  and id = any (select parent_id from g_child where kind = 3)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_semi');
call pgmb.reg('subq.where_semi_as_distinct_join', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(p.val) from g_parent p
     join (select distinct parent_id from g_child where kind = 3) c on c.parent_id = p.id
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_semi');

-- parents without a child of kind 3, four ways (parent_id is never NULL)
call pgmb.reg('subq.where_not_exists', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(val) from g_parent p where id between :id and :id + 99
  and not exists (select from g_child c where c.parent_id = p.id and c.kind = 3)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_anti');
call pgmb.reg('subq.where_not_in', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from g_parent where id between :id and :id + 99
  and id not in (select parent_id from g_child where kind = 3)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_anti');
call pgmb.reg('subq.where_not_equal_all', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from g_parent where id between :id and :id + 99
  and id <> all (select parent_id from g_child where kind = 3)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_anti');
call pgmb.reg('subq.where_anti_as_left_join', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(p.val) from g_parent p
     left join (select distinct parent_id from g_child where kind = 3) c on c.parent_id = p.id
where p.id between :id and :id + 99 and c.parent_id is null$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_anti');

-- NOT IN over a set of 5000 values. The subquery returns nullif(k_uniq, -1),
-- which the planner cannot prove NOT NULL, so NOT IN stays a subplan: hashed
-- when the set fits in work_mem, searched for every outer row when it does
-- not. On a NOT NULL column a recent planner turns the same NOT IN into an
-- anti join (the third form); all three return the same count.
call pgmb.reg('subq.where_not_in_hashed_subplan', '{perf,planning,analyze,consistency}', $q$
begin;
set local work_mem = '64MB';
select count(*) from g_narrow where id <= 10000 and k_uniq not in (select nullif(k_uniq, -1) from g_narrow where id <= 5000);
commit;$q$, equiv => 'subq.where_not_in_size');
call pgmb.reg('subq.where_not_in_plain_subplan', '{perf,planning,analyze,consistency}', $q$
begin;
set local work_mem = '64kB';
select count(*) from g_narrow where id <= 10000 and k_uniq not in (select nullif(k_uniq, -1) from g_narrow where id <= 5000);
commit;$q$, equiv => 'subq.where_not_in_size');
call pgmb.reg('subq.where_not_in_not_null_column', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_narrow where id <= 10000 and k_uniq not in (select k_uniq from g_narrow where id <= 5000)$q$,
    equiv => 'subq.where_not_in_size');

-- one NULL in the set: NOT IN is never true, NOT EXISTS ignores it
call pgmb.reg('subq.where_not_in_set_with_null', '{perf,planning,consistency}', $q$
select count(*) from g_narrow where id <= 1000 and k_100 not in (select k_null from g_narrow where id <= 100)$q$,
    equiv => 'subq.where_not_in_null');
call pgmb.reg('subq.where_not_in_set_with_null_expected', '{consistency}',
    $q$select 0::bigint$q$, equiv => 'subq.where_not_in_null');

-- > ALL against > the maximum: the same unless the set is empty
call pgmb.reg('subq.where_greater_than_all', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_parent where id between :id and :id + 999 and val > all (select val from g_parent where grp = :g)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'subq.where_all');
call pgmb.reg('subq.where_greater_than_max', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_parent where id between :id and :id + 999
  and (val > (select max(val) from g_parent where grp = :g) or not exists (select from g_parent where grp = :g))$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'subq.where_all');
call pgmb.reg('subq.where_all_over_empty_set_is_true', '{consistency}', $q$
select 1 > all (select 1 where false), 1 = any (select 1 where false), 1 not in (select 1 where false)$q$,
    equiv => 'subq.where_empty_set');
call pgmb.reg('subq.where_all_over_empty_set_is_true_expected', '{consistency}',
    $q$select true, false, true$q$, equiv => 'subq.where_empty_set');

-- three levels: parents of children of a kind that a dimension names
call pgmb.reg('subq.where_nested_three_levels', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from g_parent where id between :id and :id + 99
  and id in (select parent_id from g_child
             where kind in (select category - 1 from g_dim where id in (select dim_id from g_parent where grp = :g)))$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'subq.where_nested');
call pgmb.reg('subq.where_nested_three_levels_as_exists', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(p.val) from g_parent p where p.id between :id and :id + 99
  and exists (select from g_child c join g_dim d on d.category - 1 = c.kind join g_parent q on q.dim_id = d.id
              where c.parent_id = p.id and q.grp = :g)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'subq.where_nested');

-- compared with a scalar subquery: uncorrelated, and correlated to the outer row
call pgmb.reg('subq.where_scalar_uncorrelated', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_parent where id between :id and :id + 999 and val > (select avg(val) from g_parent where grp = :g)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'subq.where_scalar');
call pgmb.reg('subq.where_scalar_uncorrelated_as_join', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_parent p, (select avg(val) as a from g_parent where grp = :g) s
where p.id between :id and :id + 999 and p.val > s.a$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'subq.where_scalar');
call pgmb.reg('subq.where_scalar_correlated', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_parent p where id between :id and :id + 999
  and val > (select avg(val) from g_parent q where q.grp = p.grp)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_scalar_correlated');
call pgmb.reg('subq.where_scalar_correlated_as_window', '{perf,planning,analyze,consistency}', $q$
select count(*) from (select id, val, avg(val) over (partition by grp) as a from g_parent) s
where id between :id and :id + 999 and val > a$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.where_scalar_correlated');

------------------------------------------------------------------------------
-- LIMIT and OFFSET from a subquery
------------------------------------------------------------------------------
call pgmb.reg('subq.limit_offset_from_subquery', '{perf,planning,analyze,consistency,oltp}', $q$
select id from g_parent where id >= :id order by id
limit (select count(*) from g_dim where id <= 10) offset (select count(*) from g_dim where id <= 5)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.limit_offset');
call pgmb.reg('subq.limit_offset_literal', '{perf,planning,analyze,consistency,oltp}', $q$
select id from g_parent where id >= :id order by id limit 10 offset 5$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.limit_offset');

-- NULL from the subquery means no limit
call pgmb.reg('subq.limit_null_from_subquery', '{perf,planning,consistency}', $q$
select count(*) from (select id from g_parent where id between :id and :id + 99 limit (select null::bigint)) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.limit_null');
call pgmb.reg('subq.limit_none', '{perf,planning,consistency}', $q$
select count(*) from (select id from g_parent where id between :id and :id + 99) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.limit_null');

call pgmb.reg('subq.err_limit_negative_from_subquery', '{errors}',
    $q$select 1 limit (select -1)$q$, expect_error => '2201W');
call pgmb.reg('subq.err_offset_negative_from_subquery', '{errors}',
    $q$select 1 offset (select -1)$q$, expect_error => '2201X');
-- a LIMIT may not refer to the rows it limits
call pgmb.reg('subq.err_limit_correlated', '{errors}',
    $q$select id from g_parent p limit (select p.id)$q$, expect_error => '42P10');

------------------------------------------------------------------------------
-- GROUP BY and HAVING
------------------------------------------------------------------------------
-- grouped by the result of a correlated scalar subquery, against a join
call pgmb.reg('subq.group_by_scalar_subquery', '{perf,planning,analyze,consistency}', $q$
select (select category from g_dim d where d.id = p.dim_id) as category, count(*), sum(val)
from g_parent p where id between :id and :id + 999 group by 1$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.group_by');
call pgmb.reg('subq.group_by_scalar_subquery_as_join', '{perf,planning,analyze,consistency}', $q$
select d.category, count(*), sum(p.val)
from g_parent p join g_dim d on d.id = p.dim_id where p.id between :id and :id + 999 group by d.category$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.group_by');

-- HAVING compared with a subquery over another aggregate
call pgmb.reg('subq.having_subquery', '{perf,planning,analyze,consistency,olap}', $q$
select grp, count(*) from g_parent group by grp
having count(*) > (select avg(n) from (select count(*) as n from g_parent group by grp) s)$q$,
    equiv => 'subq.having');
call pgmb.reg('subq.having_subquery_as_window', '{perf,planning,analyze,consistency,olap}', $q$
select grp, n from (select grp, count(*) as n, avg(count(*)) over () as a from g_parent group by grp) s where n > a$q$,
    equiv => 'subq.having');

-- an aggregate over a derived table that is itself an aggregate
call pgmb.reg('subq.group_by_over_aggregated_derived_table', '{perf,planning,analyze,consistency,olap}', $q$
select kind, count(*), sum(total), max(total)
from (select parent_id, kind, sum(amount) as total from g_child where parent_id between :id and :id + 999 group by parent_id, kind) s
group by kind$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.group_by_twice');
call pgmb.reg('subq.group_by_over_aggregated_derived_table_as_cte', '{perf,planning,analyze,consistency,olap}', $q$
with s as (select parent_id, kind, sum(amount) as total from g_child where parent_id between :id and :id + 999 group by parent_id, kind)
select kind, count(*), sum(total), max(total) from s group by kind$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.group_by_twice');

-- a subquery in the select list correlated with the grouping column
call pgmb.reg('subq.group_by_correlated_to_group_column', '{perf,planning,analyze,consistency}', $q$
select p.grp, count(*), (select count(*) from g_dim d where d.category = p.grp % 10) as dims
from g_parent p where p.id between :id and :id + 999 group by p.grp$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.group_correlated');
call pgmb.reg('subq.group_by_correlated_to_group_column_as_join', '{perf,planning,analyze,consistency}', $q$
select g.grp, g.n, coalesce(d.dims, 0)
from (select grp, count(*) as n from g_parent where id between :id and :id + 999 group by grp) g
     left join (select category, count(*) as dims from g_dim group by category) d on d.category = g.grp % 10$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.group_correlated');

------------------------------------------------------------------------------
-- the same query as subqueries and as CTEs
------------------------------------------------------------------------------
-- An intermediate result used twice: as subqueries it is written twice, as a
-- CTE once. The results agree; the plans and the work differ.
call pgmb.reg('subq.vs_cte_used_twice_subqueries', '{perf,planning,analyze,consistency}', $q$
select (select count(*) from (select parent_id, sum(amount) as t from g_child where parent_id between :id and :id + 999 group by parent_id) a where t > 1000),
       (select max(t) from (select parent_id, sum(amount) as t from g_child where parent_id between :id and :id + 999 group by parent_id) b)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.vs_cte');
call pgmb.reg('subq.vs_cte_used_twice_cte_default', '{perf,planning,analyze,consistency}', $q$
with s as (select parent_id, sum(amount) as t from g_child where parent_id between :id and :id + 999 group by parent_id)
select (select count(*) from s where t > 1000), (select max(t) from s)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.vs_cte');
call pgmb.reg('subq.vs_cte_used_twice_cte_not_materialized', '{perf,planning,analyze,consistency}', $q$
with s as not materialized (select parent_id, sum(amount) as t from g_child where parent_id between :id and :id + 999 group by parent_id)
select (select count(*) from s where t > 1000), (select max(t) from s)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.vs_cte');

-- how often a function in the shared part is called (counted with the
-- functions of cte_more.sql): written twice it runs twice, as a CTE once
call pgmb.reg('subq.calls_expected_100', '{consistency}', $q$select 100::bigint$q$, equiv => 'subq.calls_100');
call pgmb.reg('subq.calls_expected_200', '{consistency}', $q$select 200::bigint$q$, equiv => 'subq.calls_200');
call pgmb.reg('subq.vs_cte_calls_subqueries_twice', '{consistency}', $q$
select cte_calls($s$select (select sum(v) from (select cte_volatile(n) as v from generate_series(1, 100) n) a),
                           (select max(v) from (select cte_volatile(n) as v from generate_series(1, 100) n) b)$s$)$q$,
    equiv => 'subq.calls_200');
call pgmb.reg('subq.vs_cte_calls_cte_once', '{consistency}', $q$
select cte_calls($s$with s as (select cte_volatile(n) as v from generate_series(1, 100) n)
                    select (select sum(v) from s), (select max(v) from s)$s$)$q$,
    equiv => 'subq.calls_100');
call pgmb.reg('subq.vs_cte_calls_immutable_not_materialized', '{consistency}', $q$
select cte_calls($s$with s as not materialized (select cte_imm(n) as v from generate_series(1, 100) n)
                    select (select sum(v) from s), (select max(v) from s)$s$)$q$,
    equiv => 'subq.calls_200');
