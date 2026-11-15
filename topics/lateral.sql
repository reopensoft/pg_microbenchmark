-- Topic: LATERAL joins.

call pgmb.reg('lateral.top3_per_parent', '{perf,planning,oltp}', $q$
select p.id, c.id as child_id, c.amount
from g_parent p
cross join lateral (select id, amount from g_child c where c.parent_id = p.id order by seq desc limit 3) c
where p.id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('lateral.left_join_aggregate', '{perf,planning}', $q$
select p.id, s.cnt, s.total
from g_parent p
left join lateral (select count(*) as cnt, sum(amount) as total from g_child c where c.parent_id = p.id) s on true
where p.grp = :g$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('lateral.left_join_empty', '{perf,planning,oltp}', $q$
select p.id, c.id as child_id
from g_parent p
left join lateral (select id from g_child c where c.parent_id = p.id and c.seq < 0 limit 1) c on true
where p.id between :id and :id + 50$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('lateral.set_returning_function', '{perf,planning,oltp}', $q$
select p.id, g
from g_parent p, lateral generate_series(1, p.status + 1) g
where p.id between :id and :id + 100$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('lateral.unnest_ordinality', '{perf,planning,oltp}', $q$
select a.id, u.x, u.ord
from g_array a, lateral unnest(a.a_med) with ordinality as u(x, ord)
where a.id = :id$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('lateral.values_unpivot', '{perf,planning,oltp}', $q$
select p.id, v.name, v.x
from g_parent p,
     lateral (values ('grp', p.grp), ('status', p.status::int), ('dim', p.dim_id)) as v(name, x)
where p.id between :id and :id + 50$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('lateral.chain_dependent', '{perf,planning,oltp}', $q$
select p.id, c.id as child_id, k.n
from g_parent p,
     lateral (select id, parent_id, kind from g_child c where c.parent_id = p.id order by seq limit 1) c,
     lateral (select count(*) as n from g_child c2 where c2.parent_id = c.parent_id and c2.kind = c.kind) k
where p.id between :id and :id + 10$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('lateral.previous_event', '{perf,planning}', $q$
select e.id, prev.ts as prev_ts
from g_events e
left join lateral (select ts from g_events e2
                   where e2.entity_id = e.entity_id and e2.ts < e.ts
                   order by e2.ts desc limit 1) prev on true
where e.entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('lateral.outer_ref_two_levels', '{perf,planning}', $q$
select d.id, x.best
from g_dim d,
     lateral (select max(s.total) as best
              from g_parent p,
                   lateral (select sum(amount) as total from g_child c where c.parent_id = p.id) s
              where p.dim_id = d.id and p.grp = :g) x
where d.id between :d and :d + 5$q$,
    setup => E'\\set d random(1, :n_g_dim)\n\\set g random(0, 99)');

-- top-1 per group three ways; the variants must agree
call pgmb.reg('lateral.top1_lateral', '{perf,planning,consistency,oltp}', $q$
select p.id, c.id as child_id
from g_parent p, lateral (select id from g_child c where c.parent_id = p.id order by seq desc, id desc limit 1) c
where p.id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'lateral.top1');

call pgmb.reg('lateral.top1_distinct_on', '{perf,planning,consistency,oltp}', $q$
select distinct on (c.parent_id) c.parent_id as id, c.id as child_id
from g_child c
where c.parent_id between :id and :id + 20
order by c.parent_id, c.seq desc, c.id desc$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'lateral.top1');

call pgmb.reg('lateral.top1_row_number', '{perf,planning,consistency,oltp}', $q$
select parent_id as id, id as child_id
from (select parent_id, id, row_number() over (partition by parent_id order by seq desc, id desc) as rn
      from g_child where parent_id between :id and :id + 20) s
where rn = 1$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'lateral.top1');

call pgmb.reg('lateral.err_missing_keyword', '{errors}',
    $q$select * from g_parent p, (select * from g_child c where c.parent_id = p.id) s$q$, expect_error => '42P01');
