-- Topic: planning speed and plan stability.
-- Queries that are cheap to execute and expensive (or unstable) to plan.

-- join chains of growing size: 2 .. 16 relations (16 crosses geqo_threshold)
select string_agg(format('join g_parent p%s on p%s.id = p%s.dim_id', i, i, i - 1), ' ' order by i) as pgmb_j2  from generate_series(2, 2)  i \gset
select string_agg(format('join g_parent p%s on p%s.id = p%s.dim_id', i, i, i - 1), ' ' order by i) as pgmb_j4  from generate_series(2, 4)  i \gset
select string_agg(format('join g_parent p%s on p%s.id = p%s.dim_id', i, i, i - 1), ' ' order by i) as pgmb_j8  from generate_series(2, 8)  i \gset
select string_agg(format('join g_parent p%s on p%s.id = p%s.dim_id', i, i, i - 1), ' ' order by i) as pgmb_j12 from generate_series(2, 12) i \gset
select string_agg(format('join g_parent p%s on p%s.id = p%s.dim_id', i, i, i - 1), ' ' order by i) as pgmb_j16 from generate_series(2, 16) i \gset

call pgmb.reg('plan.join_02', '{perf,planning,oltp}',
    format('select p2.id from g_parent p1 %s where p1.id = :id', :'pgmb_j2'),  setup => '\set id random(1, :n_g_parent)');
call pgmb.reg('plan.join_04', '{perf,planning,oltp}',
    format('select p4.id from g_parent p1 %s where p1.id = :id', :'pgmb_j4'),  setup => '\set id random(1, :n_g_parent)');
call pgmb.reg('plan.join_08', '{perf,planning}',
    format('select p8.id from g_parent p1 %s where p1.id = :id', :'pgmb_j8'),  setup => '\set id random(1, :n_g_parent)');
call pgmb.reg('plan.join_12', '{perf,planning}',
    format('select p12.id from g_parent p1 %s where p1.id = :id', :'pgmb_j12'), setup => '\set id random(1, :n_g_parent)');
call pgmb.reg('plan.join_16_geqo', '{perf,planning}',
    format('select p16.id from g_parent p1 %s where p1.id = :id', :'pgmb_j16'), setup => '\set id random(1, :n_g_parent)');

-- star join over different tables
call pgmb.reg('plan.join_star_5', '{perf,planning,oltp}', $q$
select c.id, p.grp, d.code, t.depth, n.k_100
from g_child c
join g_parent p on p.id = c.parent_id
join g_dim d on d.id = p.dim_id
left join g_tree t on t.id = c.parent_id
left join g_narrow n on n.id = c.id
where c.id = :id$q$,
    setup => '\set id random(1, :n_g_child)');

-- long constant lists
select string_agg((i * 3)::text, ',') as pgmb_in1000 from generate_series(1, 1000) i \gset
call pgmb.reg('plan.in_list_1000', '{perf,planning}',
    format('select count(*) from g_narrow where id in (%s)', :'pgmb_in1000'));

select string_agg(format('id = %s', i * 5), ' or ') as pgmb_or100 from generate_series(1, 100) i \gset
call pgmb.reg('plan.or_chain_100', '{perf,planning}',
    format('select count(*) from g_narrow where %s', :'pgmb_or100'));

select string_agg(format('select id, val from g_parent where id = %s', i * 11), ' union all ') as pgmb_ua20 from generate_series(1, 20) i \gset
call pgmb.reg('plan.union_all_20', '{perf,planning}',
    format('select count(*), sum(val) from (%s) u', :'pgmb_ua20'));

select string_agg(format('when %s then %s', i, i * 2), ' ') as pgmb_case200 from generate_series(1, 200) i \gset
call pgmb.reg('plan.case_200_branches', '{perf,planning,oltp}',
    format('select case k_100 %s else -1 end from g_narrow where id = :id', :'pgmb_case200'),
    setup => '\set id random(1, :n_g_narrow)');

-- wide target lists
call pgmb.reg('plan.wide_self_join', '{perf,planning,oltp}', $q$
select * from g_wide w1 join g_wide w2 using (id) join g_wide w3 using (id) where w1.id = :id$q$,
    setup => '\set id random(1, :n_g_wide)');

-- planner transformations
call pgmb.reg('plan.self_join_elimination', '{perf,planning,oltp}', $q$
select a.id, a.val from g_parent a join g_parent b on a.id = b.id where b.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.exists_semi_join', '{perf,planning}', $q$
select count(*) from g_parent p
where p.grp = :g
  and exists (select 1 from g_child c where c.parent_id = p.id and c.kind = :k)
  and not exists (select 1 from g_tree t where t.parent_id = p.id and t.val = -1)$q$,
    setup => E'\\set g random(0, 99)\n\\set k random(0, 7)');

call pgmb.reg('plan.subquery_pullup_4', '{perf,planning,oltp}', $q$
select * from (select * from (select * from (select * from (
    select id, grp, val from g_parent) a where grp >= 0) b where val >= 0) c where id > 0) d
where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.const_false', '{perf,planning,oltp}', $q$
select * from g_narrow n join g_wide w using (id) where 1 = 0$q$);

-- stability: the best plan depends on the parameter value
call pgmb.reg('plan.unstable_skewed_value', '{perf,planning}', $q$
select count(*), max(k_10k) from g_narrow where k_skew = :s$q$,
    setup => '\set s random(0, 999)');

call pgmb.reg('plan.unstable_range_width', '{perf,planning}', $q$
select count(*), max(pad) from g_narrow where k_uniq between :a and :a + :w * :w * :w$q$,
    setup => E'\\set a random(1, :n_g_narrow)\n\\set w random(1, 100)');

call pgmb.reg('plan.unstable_join_order', '{perf,planning}', $q$
select count(*) from g_parent p join g_child c on c.parent_id = p.id
where p.grp < :g and c.kind < :k$q$,
    setup => E'\\set g random(1, 100)\n\\set k random(1, 8)');

call pgmb.reg('plan.err_ambiguous_column', '{errors}',
    $q$select id from g_parent a join g_parent b using (grp)$q$, expect_error => '42702');

------------------------------------------------------------------------------
-- very long IN lists: cost of parsing and planning the list, and how it is executed
------------------------------------------------------------------------------
select string_agg((i * 3)::text, ',') as pgmb_in10k from generate_series(1, 10000) i \gset
select string_agg((i * 2)::text, ',') as pgmb_in5k from generate_series(1, 5000) i \gset
select string_agg(format('(%s)', i * 2), ',') as pgmb_val5k from generate_series(1, 5000) i \gset
select string_agg((i * 7)::text, ',') as pgmb_in1k from generate_series(1, 1000) i \gset
select string_agg(quote_literal(pgmb.htext(i * 5, 8, 40)), ',') as pgmb_in1k_text from generate_series(1, 1000) i \gset
select string_agg(format('(%s,%s)', i % 100, i * 7 % 10000), ',') as pgmb_in500_pairs from generate_series(1, 500) i \gset

-- index probes driven by the list
call pgmb.reg('plan.in_list_10000_index', '{perf,planning}',
    format('select count(*), sum(k_10k) from g_narrow where id in (%s)', :'pgmb_in10k'));

-- no index on the expression: the list becomes a hash table probed per row
call pgmb.reg('plan.in_list_1000_hashed', '{perf,planning}',
    format('select count(*) from g_narrow where id between :id and :id + 5000 and k_10k + 0 in (%s)', :'pgmb_in1k'),
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('plan.not_in_list_1000_hashed', '{perf,planning}',
    format('select count(*) from g_narrow where id between :id and :id + 5000 and k_10k not in (%s)', :'pgmb_in1k'),
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('plan.in_list_1000_text', '{perf,planning}',
    format('select count(*), min(id) from g_narrow where pad in (%s)', :'pgmb_in1k_text'));

call pgmb.reg('plan.in_list_500_row_pairs', '{perf,planning}',
    format('select count(*) from g_narrow where (k_100, k_10k) in (%s)', :'pgmb_in500_pairs'));

call pgmb.reg('plan.in_list_two_lists', '{perf,planning}',
    format('select count(*) from g_narrow where id in (%s) and k_10k in (%s)', :'pgmb_in5k', :'pgmb_in1k'));

-- the same 5000 keys as an IN list, one array literal, and a VALUES semi-join; results must agree
call pgmb.reg('plan.keys_5000_in_list', '{perf,planning,consistency}',
    format('select count(*), sum(k_10k) from g_narrow where id in (%s)', :'pgmb_in5k'),
    equiv => 'plan.keys_5000');

call pgmb.reg('plan.keys_5000_array_literal', '{perf,planning,consistency}',
    format('select count(*), sum(k_10k) from g_narrow where id = any (''{%s}''::bigint[])', :'pgmb_in5k'),
    equiv => 'plan.keys_5000');

call pgmb.reg('plan.keys_5000_values_semi_join', '{perf,planning,consistency}',
    format('select count(*), sum(k_10k) from g_narrow where id in (values %s)', :'pgmb_val5k'),
    equiv => 'plan.keys_5000');

call pgmb.reg('plan.keys_5000_values_join', '{perf,planning,consistency}',
    format('select count(*), sum(n.k_10k) from (values %s) v(id) join g_narrow n on n.id = v.id', :'pgmb_val5k'),
    equiv => 'plan.keys_5000');

------------------------------------------------------------------------------
-- large VALUES lists: the data set lives in the query text
------------------------------------------------------------------------------
select string_agg(format('(%s)', i), ',') as pgmb_val1k from generate_series(1, 1000) i \gset
select string_agg(format('(%s)', i), ',') as pgmb_val10k from generate_series(1, 10000) i \gset
select string_agg(format('(%s,%s,%L,%s,%L,%s,%s,%L,%s,%s)', i, i * 2, 'row' || i, i / 7.0, pgmb.htext(i, 1, 20),
                         (i % 2 = 0)::text, i * 1000, date '2020-01-01' + i, i % 13, i * i), ',') as pgmb_val1k_wide
from generate_series(1, 1000) i \gset
select string_agg(case i % 4 when 0 then format('(%s)', i) when 1 then format('(%s.5)', i)
                             when 2 then '(null)' else format('(''%s'')', i) end, ',') as pgmb_val1k_mixed
from generate_series(1, 1000) i \gset
select string_agg(format('(%s,%s)', i * 3, i % 5 - 2), ',') as pgmb_val200_upd from generate_series(1, 200) i \gset

call pgmb.reg('plan.values_1000_scan', '{perf,planning}',
    format('select count(*), sum(x) from (values %s) v(x)', :'pgmb_val1k'));

call pgmb.reg('plan.values_10000_scan', '{perf,planning}',
    format('select count(*), sum(x) from (values %s) v(x)', :'pgmb_val10k'));

call pgmb.reg('plan.values_1000_rows_10_columns', '{perf,planning}',
    format('select count(*), sum(a), max(c), sum(d), count(*) filter (where f), max(h) '
           'from (values %s) v(a, b, c, d, e, f, g, h, i, j)', :'pgmb_val1k_wide'));

-- every row forces type resolution: int, numeric, NULL and an untyped literal in one column
call pgmb.reg('plan.values_1000_mixed_types', '{perf,planning}',
    format('select count(*), count(x), sum(x) from (values %s) v(x)', :'pgmb_val1k_mixed'));

call pgmb.reg('plan.values_1000_group_sort', '{perf,planning}',
    format('select x %% 10 as k, count(*), sum(x) from (values %s) v(x) group by 1 order by 3 desc', :'pgmb_val1k'));

call pgmb.reg('plan.values_1000_returned', '{perf,planning}',
    format('select * from (values %s) v(a, b, c, d, e, f, g, h, i, j)', :'pgmb_val1k_wide'));

call pgmb.reg('plan.values_1000_left_join', '{perf,planning}',
    format('select count(*), count(p.id), sum(p.val) from (values %s) v(x) left join g_parent p on p.id = v.x', :'pgmb_val1k'));

call pgmb.reg('plan.values_1000_anti_join', '{perf,planning}',
    format('select count(*) from (values %s) v(x) where not exists (select 1 from g_dim d where d.id = v.x)', :'pgmb_val1k'));

-- batch update driven by a VALUES list
call pgmb.reg('plan.values_200_batch_update', '{perf,planning}',
    format('update g_parent p set val = p.val + v.delta from (values %s) v(id, delta) where p.id = v.id', :'pgmb_val200_upd'),
    kind => 'write');

------------------------------------------------------------------------------
-- row count misestimates: the planner's guess is far off, and the plan pays for it.
-- g_narrow: k_corr ~ id / 10 and k_uniq = n + 1 - id are both functions of id,
-- but the planner treats the columns as independent.
------------------------------------------------------------------------------
-- two predicates that select the same rows: selectivities are multiplied (underestimate)
call pgmb.reg('plan.misestimate_correlated_ranges', '{perf,planning}', $q$
select count(*), sum(c.amount)
from g_narrow n join g_child c on c.id = n.id
where n.id between :id and :id + 20000 and n.k_corr between :id / 10 and :id / 10 + 2009$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('plan.misestimate_redundant_three_columns', '{perf,planning}', $q$
select count(*), sum(e.val)
from g_narrow n join g_events e on e.id = n.id
where n.id between :id and :id + 20000
  and n.k_corr between :id / 10 and :id / 10 + 2009
  and n.k_uniq between :n_g_narrow - :id - 19999 and :n_g_narrow + 1 - :id$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- overlapping OR branches are added up (overestimate)
call pgmb.reg('plan.misestimate_overlapping_or', '{perf,planning}', $q$
select count(*) from g_narrow n join g_events e on e.id = n.id
where n.id < :id or n.k_corr < :id / 10 or n.k_uniq > :n_g_narrow - :id$q$,
    setup => '\set id random(1, :n_g_narrow / 20)');

-- expressions without statistics get a default selectivity
call pgmb.reg('plan.misestimate_expression_default', '{perf,planning}', $q$
select count(*), sum(c.amount)
from g_narrow n join g_child c on c.id = n.id
where n.id between :id and :id + 20000 and n.k_10k % 2 = 0$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('plan.misestimate_function_predicate', '{perf,planning}', $q$
select count(*) from g_parent p join g_child c on c.parent_id = p.id
where noop_plpgsql(p.grp) < 50 and length(p.name) > 5$q$);

call pgmb.reg('plan.misestimate_like_infix', '{perf,planning}', $q$
select count(*) from g_narrow n join g_events e on e.id = n.id
where n.id between :id and :id + 20000 and n.pad like '%a%'$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- set-returning functions: a fixed guess of rows
call pgmb.reg('plan.misestimate_srf_rows', '{perf,planning}', $q$
select count(*) from generate_series(1, 5) g, noop_srf(g) s join g_narrow n on n.id = s$q$);

call pgmb.reg('plan.misestimate_unnest_subquery_array', '{perf,planning}', $q$
select count(*), sum(c.amount)
from unnest((select array_agg(id) from g_parent where grp = :g)) as k(id)
join g_child c on c.parent_id = k.id
join g_parent p on p.id = c.parent_id$q$,
    setup => '\set g random(0, 99)');

-- a materialized CTE hides its statistics from the outer query
call pgmb.reg('plan.misestimate_cte_scan_filter', '{perf,planning}', $q$
with c as materialized (select id, k_100, k_skew from g_narrow where id between :id and :id + 20000)
select count(*), sum(e.val) from c join g_events e on e.id = c.id where c.k_skew = 0 and c.k_100 < 90$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- recursion: the size of the result is a guess
call pgmb.reg('plan.misestimate_recursive_size', '{perf,planning}', $q$
with recursive sub as (
    select id from g_tree where id = :id
    union all
    select t.id from g_tree t join sub s on t.parent_id = s.id)
select count(*), sum(p.val) from sub join g_parent p on p.id = sub.id$q$,
    setup => '\set id random(1, :n_g_tree / 256 + 1)');

-- skewed join key: an average fan-out is assumed for every parent
call pgmb.reg('plan.misestimate_skewed_fan_out', '{perf,planning}', $q$
select count(*), sum(c.amount) from g_parent p join g_child c on c.parent_id = p.id
where p.id <= :m$q$,
    setup => '\set m random(1, :n_g_parent / 100 + 1)');

-- group count after an expression
call pgmb.reg('plan.misestimate_group_count', '{perf,planning}', $q$
select count(*) from (select k_corr / 100 as g, id % 3 as r, count(*) from g_narrow
                      where id between :id and :id + 50000 group by 1, 2) s$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- LIMIT with a filter correlated against the sort order: the planner walks an
-- index expecting early matches that only come at the very end.
-- The second form hides the index and returns the same rows.
call pgmb.reg('plan.misestimate_limit_correlated', '{perf,planning,consistency}', $q$
select id, k_uniq from g_narrow where k_corr > :n_g_narrow * 0.08 order by k_uniq desc limit 10$q$,
    equiv => 'plan.misestimate_limit');

call pgmb.reg('plan.misestimate_limit_sorted_instead', '{perf,planning,consistency}', $q$
select id, k_uniq from g_narrow where k_corr > :n_g_narrow * 0.08 order by k_uniq + 0 desc limit 10$q$,
    equiv => 'plan.misestimate_limit');

-- anti-join on a nullable expression
call pgmb.reg('plan.misestimate_anti_join', '{perf,planning}', $q$
select count(*) from g_narrow n
where n.id between :id and :id + 20000
  and not exists (select 1 from g_events e where e.id = n.id and e.cat = n.k_100 % 5)$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- predicate pushdown: into subqueries, views, set operations, joins - and what stops it
------------------------------------------------------------------------------
call pgmb.reg_ddl('plan.create_v_child_totals', 'schema', $q$
create view v_child_totals as
select parent_id, count(*) as n, sum(amount) as total, max(amount) as top from g_child group by parent_id$q$);
call pgmb.reg_ddl('plan.create_v_all_ids', 'schema', $q$
create view v_all_ids as
select 'parent' as src, id, grp as k from g_parent
union all select 'child', id, kind from g_child
union all select 'tree', id, depth from g_tree$q$);
call pgmb.reg_ddl('plan.create_v_parent_plain', 'schema', $q$
create view v_parent_plain as select id, grp, val, name from g_parent where status < 4$q$);
call pgmb.reg_ddl('plan.create_v_parent_barrier', 'schema', $q$
create view v_parent_barrier with (security_barrier) as select id, grp, val, name from g_parent where status < 4$q$);
call pgmb.reg_ddl('plan.create_v_ranked_events', 'schema', $q$
create view v_ranked_events as
select id, entity_id, cat, val, row_number() over (partition by entity_id order by ts) as rn from g_events$q$);

-- through GROUP BY in a subquery and in a view; the manual form must return the same rows
call pgmb.reg('plan.pushdown_group_by_subquery', '{perf,planning,consistency,oltp}', $q$
select * from (select parent_id, count(*) as n, sum(amount) as total, max(amount) as top
               from g_child group by parent_id) s
where parent_id between :id and :id + 10$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'plan.pushdown_group');

call pgmb.reg('plan.pushdown_group_by_view', '{perf,planning,consistency,oltp}', $q$
select * from v_child_totals where parent_id between :id and :id + 10$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'plan.pushdown_group');

call pgmb.reg('plan.pushdown_group_by_manual', '{perf,planning,consistency,oltp}', $q$
select parent_id, count(*) as n, sum(amount) as total, max(amount) as top
from g_child where parent_id between :id and :id + 10 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'plan.pushdown_group');

call pgmb.reg('plan.pushdown_group_by_blocked_offset_0', '{perf,planning,consistency,olap}', $q$
select * from (select parent_id, count(*) as n, sum(amount) as total, max(amount) as top
               from g_child group by parent_id offset 0) s
where parent_id between :id and :id + 10$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'plan.pushdown_group');

-- a filter on the aggregate cannot go below the GROUP BY
call pgmb.reg('plan.pushdown_on_aggregate_stays', '{perf,planning,olap}', $q$
select count(*) from v_child_totals where total > :t$q$,
    setup => '\set t random(1000, 20000)');

-- join condition pushed into a grouped view through an equivalence
call pgmb.reg('plan.pushdown_join_into_view', '{perf,planning,oltp}', $q$
select p.id, p.grp, t.n, t.total
from g_parent p join v_child_totals t on t.parent_id = p.id
where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.pushdown_join_range_not_derived', '{perf,planning,olap}', $q$
select p.id, t.n from g_parent p join v_child_totals t on t.parent_id = p.id
where p.id between :id and :id + 10$q$,
    setup => '\set id random(1, :n_g_parent)');

-- through UNION ALL: into every branch, and removing branches by constant
call pgmb.reg('plan.pushdown_union_all_view', '{perf,planning,oltp}', $q$
select src, id, k from v_all_ids where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.pushdown_union_all_branch_constant', '{perf,planning,oltp}', $q$
select id, k from v_all_ids where src = 'child' and id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('plan.pushdown_union_dedup', '{perf,planning,oltp}', $q$
select * from (select id, grp from g_parent union select parent_id, kind from g_child) u where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.pushdown_intersect_except', '{perf,planning,oltp}', $q$
select * from (select id from g_parent intersect select parent_id from g_child
               except select id from g_tree where depth = 0) s
where id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_parent)');

-- through DISTINCT and DISTINCT ON
call pgmb.reg('plan.pushdown_distinct', '{perf,planning,oltp}', $q$
select * from (select distinct parent_id, kind from g_child) s where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.pushdown_distinct_on_key', '{perf,planning,oltp}', $q$
select * from (select distinct on (parent_id) parent_id, id, amount from g_child order by parent_id, amount desc) s
where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.pushdown_distinct_on_non_key_stays', '{perf,planning,olap}', $q$
select count(*) from (select distinct on (parent_id) parent_id, id, amount from g_child order by parent_id, amount desc) s
where amount < :a$q$,
    setup => '\set a random(100, 900)');

-- through window functions: only on the PARTITION BY column
call pgmb.reg('plan.pushdown_window_partition_key', '{perf,planning,oltp}', $q$
select * from v_ranked_events where entity_id = :e and rn <= 5$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('plan.pushdown_window_other_column_stays', '{perf,planning,olap}', $q$
select count(*) from v_ranked_events where cat = :c and rn = 1$q$,
    setup => '\set c random(0, 4)');

-- outer joins: WHERE on the nullable side vs. the same condition in ON
call pgmb.reg('plan.pushdown_outer_join_where', '{perf,planning}', $q$
select count(*), count(c.id) from g_parent p left join g_child c on c.parent_id = p.id
where p.grp = :g and c.kind = :k$q$,
    setup => E'\\set g random(0, 99)\n\\set k random(0, 7)');

call pgmb.reg('plan.pushdown_outer_join_on', '{perf,planning}', $q$
select count(*), count(c.id) from g_parent p left join g_child c on c.parent_id = p.id and c.kind = :k
where p.grp = :g$q$,
    setup => E'\\set g random(0, 99)\n\\set k random(0, 7)');

-- into LATERAL and into a correlated subquery
call pgmb.reg('plan.pushdown_into_lateral', '{perf,planning,oltp}', $q$
select p.id, s.n from g_parent p,
     lateral (select count(*) as n from v_child_totals t where t.parent_id = p.id) s
where p.id between :id and :id + 10$q$,
    setup => '\set id random(1, :n_g_parent)');

-- HAVING without aggregates is evaluated before grouping
call pgmb.reg('plan.pushdown_having_to_where', '{perf,planning,oltp}', $q$
select parent_id, count(*) from g_child group by parent_id having parent_id between :id and :id + 10$q$,
    setup => '\set id random(1, :n_g_parent)');

-- barriers
call pgmb.reg('plan.pushdown_blocked_by_limit', '{perf,planning}', $q$
select count(*) from (select id, kind from g_child order by id limit 20000) s where kind = :k$q$,
    setup => '\set k random(0, 7)');

call pgmb.reg('plan.pushdown_blocked_by_volatile', '{perf,planning}', $q$
select count(*) from (select id, grp, random() as r from g_parent) s where grp = :g and r >= 0$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('plan.pushdown_blocked_by_srf', '{perf,planning}', $q$
select count(*) from (select id, unnest(a_small) as x from g_array) s where x = :v$q$,
    setup => '\set v random(0, 999)');

-- security barrier view: a leakproof comparison goes in, a user function stays outside
call pgmb.reg('plan.pushdown_view_plain_function', '{perf,planning,consistency}', $q$
select id, val from v_parent_plain where id between :id and :id + 200 and noop_plpgsql(grp) < 50$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'plan.pushdown_barrier');

call pgmb.reg('plan.pushdown_view_barrier_function', '{perf,planning,consistency}', $q$
select id, val from v_parent_barrier where id between :id and :id + 200 and noop_plpgsql(grp) < 50$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'plan.pushdown_barrier');

call pgmb.reg('plan.pushdown_view_barrier_leakproof', '{perf,planning,oltp}', $q$
select id, val from v_parent_barrier where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('plan.pushdown_view_barrier_function_only', '{perf,planning,olap}', $q$
select count(*) from v_parent_barrier where noop_plpgsql(id::int) = :id$q$,
    setup => '\set id random(1, :n_g_parent)');
