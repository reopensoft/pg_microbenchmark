-- Topic: cte (part 4) - WHERE clauses in and around CTEs.
-- Kinds of predicates, and where a predicate written outside the CTE may or
-- may not be pushed into it. Pairs "inside"/"outside" must return the same rows.

------------------------------------------------------------------------------
-- predicate inside vs. outside the CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.where_eq_inside', '{perf,planning,consistency,oltp}', $q$
with c as (select id, parent_id, amount from g_child where parent_id = :id)
select * from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_eq');
call pgmb.reg('cte.where_eq_outside', '{perf,planning,consistency,oltp}', $q$
with c as (select id, parent_id, amount from g_child)
select * from c where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_eq');
call pgmb.reg('cte.where_eq_outside_two_levels', '{perf,planning,consistency,oltp}', $q$
with a as (select id, parent_id, amount, kind from g_child),
     b as (select id, parent_id, amount from a),
     c as (select * from b)
select * from c where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_eq');

call pgmb.reg('cte.where_range_inside', '{perf,planning,consistency,oltp}', $q$
with c as (select id, k_100 from g_narrow where id between :id and :id + 99 and k_100 < 50)
select * from c$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.where_range');
call pgmb.reg('cte.where_range_outside', '{perf,planning,consistency,oltp}', $q$
with c as (select id, k_100 from g_narrow)
select * from c where id between :id and :id + 99 and k_100 < 50$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.where_range');
call pgmb.reg('cte.where_range_split', '{perf,planning,consistency,oltp}', $q$
with c as (select id, k_100 from g_narrow where id >= :id)
select * from c where id <= :id + 99 and k_100 < 50$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.where_range');

-- through GROUP BY: a filter on the grouping key can be pushed down, one on the aggregate cannot
call pgmb.reg('cte.where_group_key_inside', '{perf,planning,consistency,oltp}', $q$
with c as (select parent_id, count(*) as n, sum(amount) as total from g_child
           where parent_id between :id and :id + 20 group by parent_id)
select * from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_group_key');
call pgmb.reg('cte.where_group_key_outside', '{perf,planning,consistency,oltp}', $q$
with c as (select parent_id, count(*) as n, sum(amount) as total from g_child group by parent_id)
select * from c where parent_id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_group_key');

call pgmb.reg('cte.where_on_aggregate_having', '{perf,planning,consistency}', $q$
with c as (select parent_id, count(*) as n from g_child
           where parent_id between :id and :id + 200 group by parent_id having count(*) > 12)
select * from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_aggregate');
call pgmb.reg('cte.where_on_aggregate_outside', '{perf,planning,consistency}', $q$
with c as (select parent_id, count(*) as n from g_child
           where parent_id between :id and :id + 200 group by parent_id)
select * from c where n > 12$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_aggregate');

-- through DISTINCT and UNION ALL
call pgmb.reg('cte.where_through_distinct', '{perf,planning,oltp}', $q$
with c as (select distinct parent_id, kind from g_child)
select * from c where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_through_union_all', '{perf,planning,oltp}', $q$
with c as (select id, grp as k from g_parent
           union all
           select id, kind from g_child
           union all
           select id, depth from g_tree)
select count(*), sum(k) from c where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_through_union_dedup', '{perf,planning,oltp}', $q$
with c as (select id from g_parent union select parent_id from g_tree)
select * from c where id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_parent)');

-- through window functions: only a filter on the PARTITION BY column can go down
call pgmb.reg('cte.where_window_partition_key', '{perf,planning}', $q$
with c as (select id, entity_id, row_number() over (partition by entity_id order by ts) as rn from g_events)
select * from c where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('cte.where_window_not_pushable', '{perf,planning}', $q$
with c as (select id, entity_id, cat, row_number() over (partition by entity_id order by ts) as rn
           from g_events where entity_id between :e and :e + 9)
select * from c where cat = 1 and rn <= 20$q$,
    setup => '\set e random(1, :n_g_events_entities)');

-- barriers: LIMIT, OFFSET 0, volatile function, MATERIALIZED
call pgmb.reg('cte.where_blocked_by_limit', '{perf,planning}', $q$
with c as (select id, k_100 from g_narrow order by id limit 5000)
select count(*) from c where k_100 = :k$q$,
    setup => '\set k random(0, 99)');

call pgmb.reg('cte.where_blocked_by_offset_0', '{perf,planning}', $q$
with c as (select id, grp, val from g_parent offset 0)
select * from c where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_blocked_by_volatile', '{perf,planning}', $q$
with c as (select id, grp, random() as r from g_parent where grp = :g)
select count(*) from c where id % 2 = 0$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('cte.where_blocked_by_materialized', '{perf,planning}', $q$
with c as materialized (select id, grp, val from g_parent where grp = :g)
select * from c where id % 10 = 3$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('cte.where_outside_recursive', '{perf,planning}', $q$
with recursive sub as (
    select id, parent_id, 0 as lvl from g_tree where id = :id
    union all
    select t.id, t.parent_id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 3)
select count(*) from sub where lvl = 3$q$,
    setup => '\set id random(1, :n_g_tree / 64 + 1)');

------------------------------------------------------------------------------
-- kinds of predicates
------------------------------------------------------------------------------
call pgmb.reg('cte.where_in_list', '{perf,planning,oltp}', $q$
with c as (select id, grp, val from g_parent where id in (:a, :a + 2, :a + 5, :a + 11, :a + 23, :a + 47, :a + 95, :a + 191))
select * from c$q$,
    setup => '\set a random(1, :n_g_parent)');

call pgmb.reg('cte.where_any_array', '{perf,planning,oltp}', $q$
with c as (select id, grp, val from g_parent where id = any (array[:a, :a + 2, :a + 5, :a + 11]::bigint[]))
select * from c where grp <> all (array[1, 2, 3])$q$,
    setup => '\set a random(1, :n_g_parent)');

call pgmb.reg('cte.where_not_in_list', '{perf,planning,oltp}', $q$
with c as (select id, status from g_parent where id between :id and :id + 100)
select count(*) from c where status not in (0, 1)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_like_patterns', '{perf,planning}', $q$
with c as (select id, pad from g_narrow where id between :id and :id + 2000)
select count(*) filter (where pad like 'a%') as prefix,
       count(*) filter (where pad like '%ff') as suffix,
       count(*) filter (where pad like '%00%') as infix,
       count(*) filter (where pad ~ '^[0-9]{3}') as regex
from c$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.where_is_null', '{perf,planning}', $q$
with c as (select id, k_null from g_narrow where id between :id and :id + 500)
select (select count(*) from c where k_null is null) as nulls,
       (select count(*) from c where k_null is not null) as not_nulls,
       (select count(*) from c where k_null is distinct from 5) as distinct_from,
       (select count(*) from c where coalesce(k_null, -1) < 100) as coalesced$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.where_or_two_indexes', '{perf,planning,oltp}', $q$
with c as (select id, k_10k, k_uniq from g_narrow)
select count(*) from c where k_10k = :b or k_uniq = :id$q$,
    setup => E'\\set b random(0, 9999)\n\\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.where_and_or_nested', '{perf,planning}', $q$
with c as (select id, k_100, k_10k, k_skew, k_null from g_narrow where id between :id and :id + 3000)
select count(*) from c
where (k_100 < 10 and (k_10k > 5000 or k_skew = 0))
   or (k_100 >= 90 and not (k_null is null or k_10k < 100))
   or (k_100 = 50 and k_skew between 1 and 10)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.where_ten_ands', '{perf,planning}', $q$
with c as (select * from g_wide where id between :id and :id + 2000)
select count(*) from c
where i1 = 1 and i2 < 8 and i3 > 5 and i4 <> 500 and i5 between 100 and 9900
  and i6 >= 1000 and i7 >= 0 and b1 is not null and n1 > 10 and d1 > date '2001-01-01'$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('cte.where_expression', '{perf,planning}', $q$
with c as (select id, k_100, k_10k from g_narrow where id between :id and :id + 2000)
select count(*) from c where (k_100 * 100 + k_10k % 100) % 7 = 3 and abs(k_10k - 5000) < 2000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.where_case', '{perf,planning}', $q$
with c as (select id, status, val from g_parent where id between :id and :id + 300)
select count(*) from c
where case status when 0 then val > 5000 when 1 then val < 2000 else val between 4000 and 6000 end$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_row_comparison_keyset', '{perf,planning,oltp}', $q$
with page as (select k_100, k_10k, id from g_narrow
              where (k_100, k_10k) > (:a, :b) order by k_100, k_10k limit 20)
select * from page$q$,
    setup => E'\\set a random(0, 99)\n\\set b random(0, 9999)');

call pgmb.reg('cte.where_between_symmetric', '{perf,planning,oltp}', $q$
with c as (select id, k_10k from g_narrow where id between symmetric :id + 50 and :id)
select count(*) from c where k_10k not between 100 and 200$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.where_timestamp_range', '{perf,planning}', $q$
with c as (select id, ts, val from g_events
           where ts >= timestamptz '2024-01-01 00:00:00+00' + :id * interval '1 second'
             and ts <  timestamptz '2024-01-01 00:00:00+00' + :id * interval '1 second' + interval '15 minutes')
select count(*), avg(val) from c where extract(minute from ts)::int % 2 = 0$q$,
    setup => '\set id random(1, :n_g_events)');

call pgmb.reg('cte.where_stable_function', '{perf,planning}', $q$
with c as (select id, updated_at from g_parent where updated_at < now() - interval '1 year' and id between :id and :id + 300)
select count(*) from c where updated_at > now() - interval '5 years'$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_array_predicates', '{perf,planning}', $q$
with c as (select id, a_small, tags from g_array where a_small && array[:v, :v + 1, :v + 2])
select count(*) from c where cardinality(a_small) >= 3 and tags @> array['tag0']$q$,
    setup => '\set v random(0, 997)');

call pgmb.reg('cte.where_cast_defeats_index', '{perf,planning,consistency}', $q$
with c as (select id, grp from g_parent)
select * from c where id::text = :id::text$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_cast');
call pgmb.reg('cte.where_cast_keeps_index', '{perf,planning,consistency,oltp}', $q$
with c as (select id, grp from g_parent)
select * from c where id = :id::int$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.where_cast');

call pgmb.reg('cte.where_contradiction', '{perf,planning,oltp}', $q$
with c as (select id, grp from g_parent where id = :id)
select * from c where id = :id + 1$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_tautology', '{perf,planning,oltp}', $q$
with c as (select id, grp from g_parent where id = :id and (1 = 1 or grp > 5) and true)
select * from c where id is not null$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_aggregate_filter_clause', '{perf,planning}', $q$
with c as (select parent_id, kind, amount from g_child where parent_id between :id and :id + 50)
select parent_id,
       count(*) filter (where kind = 0) as k0,
       sum(amount) filter (where amount > 500) as big,
       avg(amount) filter (where kind in (1, 2, 3)) as mid
from c group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- predicates that depend on another CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.where_scalar_from_cte', '{perf,planning}', $q$
with scope as (select id, val from g_parent where grp = :g),
     stats as (select avg(val) as av, stddev(val) as sd from scope)
select id, val from scope where val > (select av + sd from stats)$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('cte.where_exists_in_cte', '{perf,planning}', $q$
with busy as (select parent_id from g_child where seq < 20),
     p as (select id, grp from g_parent where id between :id and :id + 100)
select count(*) from p where exists (select 1 from busy b where b.parent_id = p.id)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_in_cte_of_cte', '{perf,planning}', $q$
with dims as (select id from g_dim where category = :c),
     parents as (select id from g_parent where dim_id in (select id from dims) and grp = :g),
     kids as (select id, amount from g_child where parent_id in (select id from parents))
select count(*), sum(amount) from kids$q$,
    setup => E'\\set c random(0, 9)\n\\set g random(0, 99)');

call pgmb.reg('cte.where_correlated_to_cte', '{perf,planning}', $q$
with p as (select id, val from g_parent where id between :id and :id + 30),
     c as (select parent_id, amount from g_child where parent_id between :id and :id + 30)
select p.id from p
where p.val / 100 > (select coalesce(avg(c.amount), 0) from c where c.parent_id = p.id)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_all_any_quantified', '{perf,planning}', $q$
with c as (select parent_id, amount from g_child where parent_id between :id and :id + 5),
     top as (select amount from c where parent_id = :id)
select count(*) filter (where amount > all (select amount from top)) as above_all,
       count(*) filter (where amount < any (select amount from top)) as below_any
from c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_transitive_equality', '{perf,planning,oltp}', $q$
with p as (select id, dim_id from g_parent),
     c as (select id, parent_id from g_child),
     t as (select id, depth from g_tree)
select c.id, t.depth from p join c on c.parent_id = p.id join t on t.id = p.id where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_on_both_join_sides', '{perf,planning}', $q$
with p as (select id, grp, status from g_parent),
     c as (select id, parent_id, kind, amount from g_child)
select count(*) from p join c on c.parent_id = p.id
where p.grp = :g and c.kind = :k and (p.status = 0 or c.amount > 900)$q$,
    setup => E'\\set g random(0, 99)\n\\set k random(0, 7)');

call pgmb.reg('cte.where_on_outer_join_nullable', '{perf,planning,oltp}', $q$
with p as (select id from g_parent where id between :id and :id + 50),
     c as (select parent_id, kind from g_child)
select p.id, c.kind from p left join c on c.parent_id = p.id and c.kind = 0
where c.kind is null or p.id % 2 = 0$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_same_parameter_many_ctes', '{perf,planning,oltp}', $q$
with p as (select id, val from g_parent where id = :id),
     c as (select count(*) as n from g_child where parent_id = :id),
     t as (select depth from g_tree where id = :id),
     a as (select cardinality(a_small) as len from g_array where id = :id)
select p.id, p.val, c.n, t.depth, a.len from p cross join c left join t on true left join a on true$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.where_update_with_cte_filter', '{perf,planning,oltp}', $q$
with rich as (select id from g_parent where id between :id and :id + 20 and val > 5000 order by id limit 3)
update g_parent set val = val - 1 where id in (select id from rich) and status < 4$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- errors
------------------------------------------------------------------------------
call pgmb.reg('cte.err_where_aggregate', '{errors}',
    $q$with c as (select id, val from g_parent) select id from c where sum(val) > 10$q$, expect_error => '42803');
call pgmb.reg('cte.err_where_window', '{errors}',
    $q$with c as (select id, val from g_parent) select id from c where rank() over (order by val) = 1$q$, expect_error => '42P20');
call pgmb.reg('cte.err_where_unknown_column', '{errors}',
    $q$with c as (select id from g_parent) select * from c where val > 1$q$, expect_error => '42703');
call pgmb.reg('cte.err_where_not_boolean', '{errors}',
    $q$with c as (select id from g_parent) select * from c where id + 1$q$, expect_error => '42804');
call pgmb.reg('cte.err_cte_not_visible_in_sibling', '{errors}',
    $q$select * from (with inner_cte as (select 1 as x) select x from inner_cte) s join inner_cte on true$q$, expect_error => '42P01');
call pgmb.reg('cte.err_column_count_mismatch', '{errors}',
    $q$with c(a, b, c) as (select 1, 2) select * from c$q$, expect_error => '42P10');
