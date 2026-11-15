-- Topic: window functions. g_events holds ~100 events per entity.

call pgmb.reg('window.row_number', '{perf,planning,oltp}', $q$
select id, row_number() over (partition by entity_id order by ts)
from g_events where entity_id between :e and :e + 9$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.running_sum', '{perf,planning,oltp}', $q$
select id, sum(val) over (partition by entity_id order by ts)
from g_events where entity_id between :e and :e + 9$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.lag_lead', '{perf,planning,oltp}', $q$
select id, val - lag(val) over w, lead(val, 2, 0) over w
from g_events where entity_id between :e and :e + 9
window w as (partition by entity_id order by ts)$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.moving_avg_rows', '{perf,planning,oltp}', $q$
select id, avg(val) over (partition by entity_id order by ts rows between 9 preceding and current row)
from g_events where entity_id between :e and :e + 9$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.range_interval', '{perf,planning}', $q$
select id, count(*) over (partition by entity_id order by ts
                          range between interval '1 hour' preceding and current row)
from g_events where entity_id between :e and :e + 9$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.groups_exclude', '{perf,planning}', $q$
select id, sum(val) over (partition by entity_id order by cat
                          groups between 1 preceding and 1 following exclude current row)
from g_events where entity_id between :e and :e + 9$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.first_last_nth', '{perf,planning}', $q$
select id, first_value(val) over w, last_value(val) over w, nth_value(val, 3) over w
from g_events where entity_id between :e and :e + 9
window w as (partition by entity_id order by ts rows between unbounded preceding and unbounded following)$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.rank_distribution', '{perf,planning}', $q$
select id, rank() over w, dense_rank() over w, ntile(4) over w, percent_rank() over w, cume_dist() over w
from g_events where entity_id between :e and :e + 9
window w as (partition by entity_id order by cat)$q$,
    setup => '\set e random(1, :n_g_events_entities)');

-- two incompatible windows: two sorts
call pgmb.reg('window.two_sort_orders', '{perf,planning}', $q$
select id,
       row_number() over (partition by entity_id order by ts),
       row_number() over (partition by cat order by val desc)
from g_events where entity_id between :e and :e + 9$q$,
    setup => '\set e random(1, :n_g_events_entities)');

-- top-N filter on row_number(): run condition lets the window stop early
call pgmb.reg('window.top3_run_condition', '{perf,planning}', $q$
select * from (
    select id, entity_id, row_number() over (partition by entity_id order by val desc) as rn
    from g_events where entity_id between :e and :e + 49) s
where rn <= 3$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.aggregate_then_window', '{perf,planning}', $q$
select entity_id, cat, sum(val) as total,
       sum(sum(val)) over (partition by entity_id) as entity_total,
       rank() over (partition by entity_id order by sum(val) desc)
from g_events where entity_id between :e and :e + 49
group by entity_id, cat$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('window.no_partition', '{perf,planning}', $q$
select max(s) from (select sum(val) over (order by id) as s
                    from g_events where id between :id and :id + 9999) x$q$,
    setup => '\set id random(1, :n_g_events)');

call pgmb.reg('window.whole_table_rank', '{perf,planning,olap}', $q$
select cat, max(r) from (select cat, dense_rank() over (partition by cat order by val) as r from g_events) s
group by cat$q$);

call pgmb.reg('window.whole_table_running', '{perf,planning,olap}', $q$
select max(c) from (select count(*) over (partition by entity_id order by ts) as c from g_events) s$q$);

-- running count two ways; the variants must agree
call pgmb.reg('window.running_count_window', '{perf,planning,consistency}', $q$
select id, count(*) over (partition by entity_id order by id) as c
from g_events where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'window.running_count');

call pgmb.reg('window.running_count_subquery', '{perf,planning,consistency}', $q$
select e.id, (select count(*) from g_events x
              where x.entity_id = e.entity_id and x.ts <= e.ts) as c
from g_events e where e.entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'window.running_count');

call pgmb.reg('window.err_nested', '{errors}',
    $q$select sum(row_number() over ()) over () from g_events$q$, expect_error => '42P20');
call pgmb.reg('window.err_in_where', '{errors}',
    $q$select id from g_events where row_number() over () = 1$q$, expect_error => '42P20');
call pgmb.reg('window.err_frame_start_after_end', '{errors}',
    $q$select sum(val) over (order by id rows between current row and 1 preceding) from g_events$q$, expect_error => '42P20');
