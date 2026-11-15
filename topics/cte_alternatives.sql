-- Topic: cte (part 26) - the same task written as a CTE and as its alternatives:
-- a subquery in FROM, LATERAL, a view, a materialized view, a temporary table.
-- Six tasks over g_events (which no test modifies, so the materialized views
-- stay exact) and g_tree. The forms of one task are a consistency group.
-- Temporary tables are created and dropped inside the test's transaction: the
-- catalog work, the write and the missing statistics are part of what they cost.
-- sum(val::numeric) keeps results exact whatever the order of the rows.

call pgmb.reg_ddl('cte.create_alt_views', 'schema', $q$
create view v_entity_totals as
    select entity_id, count(*) as n, sum(val::numeric) as total, max(ts) as last_ts from g_events group by entity_id;
create view v_events_ranked as
    select entity_id, id, ts, val, row_number() over (partition by entity_id order by ts desc) as rn from g_events;
create view v_events_cat01 as
    select id, entity_id, val, cat from g_events where cat in (0, 1);
create view v_entity_totals_cat01 as
    select entity_id, count(*) as n, sum(val::numeric) as total from v_events_cat01 group by entity_id;
create view v_category_totals_cat01 as
    select d.category, count(*) as entities, sum(t.n) as n, sum(t.total) as total
    from v_entity_totals_cat01 t join g_dim d on d.id = t.entity_id % (select count(*) from g_dim)::int + 1
    group by d.category$q$);

-- precomputed: one row per entity
call pgmb.reg_ddl('cte.create_alt_matview', 'load', $q$
create materialized view mv_entity_totals as
    select entity_id, count(*) as n, sum(val::numeric) as total, max(ts) as last_ts from g_events group by entity_id$q$,
    target => 'mv_entity_totals');
call pgmb.reg_ddl('cte.index_alt_matview', 'index', $q$create unique index mv_entity_totals_pk on mv_entity_totals (entity_id)$q$, target => 'mv_entity_totals_pk');
call pgmb.reg_ddl('cte.vacuum_alt_matview', 'maintenance', $q$vacuum (analyze) mv_entity_totals$q$);

------------------------------------------------------------------------------
-- task 1: an intermediate result used twice
-- (totals per entity for 200 entities: how many are above the average)
------------------------------------------------------------------------------
call pgmb.reg('cte.alt_reuse_cte', '{perf,planning,analyze,consistency}', $q$
with t as (select entity_id, count(*) as n, sum(val::numeric) as total from g_events where entity_id between :e and :e + 199 group by entity_id)
select count(*), sum(n) from t where total > (select avg(total) from t)$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

call pgmb.reg('cte.alt_reuse_cte_not_materialized', '{perf,planning,analyze,consistency}', $q$
with t as not materialized (select entity_id, count(*) as n, sum(val::numeric) as total from g_events where entity_id between :e and :e + 199 group by entity_id)
select count(*), sum(n) from t where total > (select avg(total) from t)$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

-- the subquery is simply written twice
call pgmb.reg('cte.alt_reuse_subquery_twice', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(n)
from (select entity_id, count(*) as n, sum(val::numeric) as total from g_events where entity_id between :e and :e + 199 group by entity_id) t
where total > (select avg(total)
               from (select sum(val::numeric) as total from g_events where entity_id between :e and :e + 199 group by entity_id) a)$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

-- one pass with a window function instead of a second use
call pgmb.reg('cte.alt_reuse_window_one_pass', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(n)
from (select n, total, avg(total) over () as avg_total
      from (select entity_id, count(*) as n, sum(val::numeric) as total from g_events where entity_id between :e and :e + 199 group by entity_id) t) w
where total > avg_total$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

call pgmb.reg('cte.alt_reuse_view', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(n) from v_entity_totals
where entity_id between :e and :e + 199
  and total > (select avg(total) from v_entity_totals where entity_id between :e and :e + 199)$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

call pgmb.reg('cte.alt_reuse_materialized_view', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(n) from mv_entity_totals
where entity_id between :e and :e + 199
  and total > (select avg(total) from mv_entity_totals where entity_id between :e and :e + 199)$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

call pgmb.reg('cte.alt_reuse_temp_table', '{perf,planning,analyze,consistency}', $q$
begin;
create temp table pgmb_tmp on commit drop as
    select entity_id, count(*) as n, sum(val::numeric) as total from g_events where entity_id between :e and :e + 199 group by entity_id;
select count(*), sum(n) from pgmb_tmp where total > (select avg(total) from pgmb_tmp);
commit;$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

call pgmb.reg('cte.alt_reuse_temp_table_analyzed', '{perf,planning,analyze,consistency}', $q$
begin;
create temp table pgmb_tmp on commit drop as
    select entity_id, count(*) as n, sum(val::numeric) as total from g_events where entity_id between :e and :e + 199 group by entity_id;
analyze pgmb_tmp;
select count(*), sum(n) from pgmb_tmp where total > (select avg(total) from pgmb_tmp);
commit;$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_reuse');

------------------------------------------------------------------------------
-- task 2: the three latest events of each of 100 entities
------------------------------------------------------------------------------
call pgmb.reg('cte.alt_top3_cte_row_number', '{perf,planning,analyze,consistency}', $q$
with r as (select entity_id, id, val, row_number() over (partition by entity_id order by ts desc) as rn
           from g_events where entity_id between :e and :e + 99)
select count(*), sum(id), sum(val::numeric) from r where rn <= 3$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

call pgmb.reg('cte.alt_top3_cte_row_number_materialized', '{perf,planning,analyze,consistency}', $q$
with r as materialized (select entity_id, id, val, row_number() over (partition by entity_id order by ts desc) as rn
           from g_events where entity_id between :e and :e + 99)
select count(*), sum(id), sum(val::numeric) from r where rn <= 3$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

call pgmb.reg('cte.alt_top3_subquery_row_number', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(id), sum(val::numeric)
from (select entity_id, id, val, row_number() over (partition by entity_id order by ts desc) as rn
      from g_events where entity_id between :e and :e + 99) r
where rn <= 3$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

-- LATERAL with LIMIT: three index entries per entity instead of all its events
call pgmb.reg('cte.alt_top3_lateral_limit', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(l.id), sum(l.val::numeric)
from generate_series(:e, :e + 99) as ent(entity_id),
     lateral (select id, val from g_events ev where ev.entity_id = ent.entity_id order by ts desc limit 3) l$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

-- the same LATERAL, the entity list from a CTE
call pgmb.reg('cte.alt_top3_cte_feeding_lateral', '{perf,planning,analyze,consistency}', $q$
with ent as (select distinct entity_id from g_events where entity_id between :e and :e + 99)
select count(*), sum(l.id), sum(l.val::numeric)
from ent, lateral (select id, val from g_events ev where ev.entity_id = ent.entity_id order by ts desc limit 3) l$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

-- the view ranks every event of the table; the entity range has to get below the window
call pgmb.reg('cte.alt_top3_view', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(id), sum(val::numeric) from v_events_ranked where entity_id between :e and :e + 99 and rn <= 3$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

call pgmb.reg('cte.alt_top3_correlated_subquery', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(id), sum(val::numeric) from g_events ev
where ev.entity_id between :e and :e + 99
  and (select count(*) from g_events newer where newer.entity_id = ev.entity_id and newer.ts > ev.ts) < 3$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

call pgmb.reg('cte.alt_top3_temp_table', '{perf,planning,analyze,consistency}', $q$
begin;
create temp table pgmb_tmp on commit drop as
    select entity_id, id, val, row_number() over (partition by entity_id order by ts desc) as rn
    from g_events where entity_id between :e and :e + 99;
select count(*), sum(id), sum(val::numeric) from pgmb_tmp where rn <= 3;
commit;$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_top3');

------------------------------------------------------------------------------
-- task 3: one entity's summary (a short query behind an abstraction)
------------------------------------------------------------------------------
call pgmb.reg('cte.alt_lookup_direct', '{perf,planning,analyze,consistency,oltp,needs_data}', $q$
select count(*) as n, sum(val::numeric) as total, max(ts) as last_ts from g_events where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_lookup');

call pgmb.reg('cte.alt_lookup_cte', '{perf,planning,analyze,consistency,oltp,needs_data}', $q$
with t as (select entity_id, count(*) as n, sum(val::numeric) as total, max(ts) as last_ts from g_events group by entity_id)
select n, total, last_ts from t where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_lookup');

call pgmb.reg('cte.alt_lookup_cte_materialized', '{perf,planning,analyze,consistency,olap,needs_data}', $q$
with t as materialized (select entity_id, count(*) as n, sum(val::numeric) as total, max(ts) as last_ts from g_events group by entity_id)
select n, total, last_ts from t where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_lookup');

call pgmb.reg('cte.alt_lookup_subquery', '{perf,planning,analyze,consistency,oltp,needs_data}', $q$
select n, total, last_ts
from (select entity_id, count(*) as n, sum(val::numeric) as total, max(ts) as last_ts from g_events group by entity_id) t
where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_lookup');

call pgmb.reg('cte.alt_lookup_view', '{perf,planning,analyze,consistency,oltp,needs_data}', $q$
select n, total, last_ts from v_entity_totals where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_lookup');

call pgmb.reg('cte.alt_lookup_materialized_view', '{perf,planning,analyze,consistency,oltp,needs_data}', $q$
select n, total, last_ts from mv_entity_totals where entity_id = :e$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_lookup');

call pgmb.reg('cte.alt_lookup_lateral', '{perf,planning,analyze,consistency,oltp,needs_data}', $q$
select s.n, s.total, s.last_ts
from (values (:e)) as ent(entity_id),
     lateral (select count(*) as n, sum(val::numeric) as total, max(ts) as last_ts from g_events ev where ev.entity_id = ent.entity_id) s$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'cte.alt_lookup');

------------------------------------------------------------------------------
-- task 4: a pipeline of three steps (filter, aggregate per entity, roll up by category)
------------------------------------------------------------------------------
call pgmb.reg('cte.alt_pipeline_cte_chain', '{perf,planning,analyze,consistency,olap}', $q$
with filtered as (select id, entity_id, val, cat from g_events where cat in (0, 1)),
     per_entity as (select entity_id, count(*) as n, sum(val::numeric) as total from filtered group by entity_id),
     per_category as (select d.category, count(*) as entities, sum(t.n) as n, sum(t.total) as total
                      from per_entity t join g_dim d on d.id = t.entity_id % :n_g_dim + 1 group by d.category)
select * from per_category$q$, equiv => 'cte.alt_pipeline');

call pgmb.reg('cte.alt_pipeline_cte_chain_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with filtered as materialized (select id, entity_id, val, cat from g_events where cat in (0, 1)),
     per_entity as materialized (select entity_id, count(*) as n, sum(val::numeric) as total from filtered group by entity_id),
     per_category as materialized (select d.category, count(*) as entities, sum(t.n) as n, sum(t.total) as total
                      from per_entity t join g_dim d on d.id = t.entity_id % :n_g_dim + 1 group by d.category)
select * from per_category$q$, equiv => 'cte.alt_pipeline');

call pgmb.reg('cte.alt_pipeline_nested_subqueries', '{perf,planning,analyze,consistency,olap}', $q$
select d.category, count(*) as entities, sum(t.n) as n, sum(t.total) as total
from (select entity_id, count(*) as n, sum(val::numeric) as total
      from (select id, entity_id, val, cat from g_events where cat in (0, 1)) filtered
      group by entity_id) t
     join g_dim d on d.id = t.entity_id % :n_g_dim + 1
group by d.category$q$, equiv => 'cte.alt_pipeline');

-- three views stacked on each other
call pgmb.reg('cte.alt_pipeline_stacked_views', '{perf,planning,analyze,consistency,olap}', $q$
select * from v_category_totals_cat01$q$, equiv => 'cte.alt_pipeline');

-- three temporary tables, one per step
call pgmb.reg('cte.alt_pipeline_temp_tables', '{perf,consistency,olap}', $q$
begin;
create temp table pgmb_step1 on commit drop as select id, entity_id, val, cat from g_events where cat in (0, 1);
create temp table pgmb_step2 on commit drop as select entity_id, count(*) as n, sum(val::numeric) as total from pgmb_step1 group by entity_id;
select d.category, count(*) as entities, sum(t.n) as n, sum(t.total) as total
from pgmb_step2 t join g_dim d on d.id = t.entity_id % :n_g_dim + 1 group by d.category;
commit;$q$, equiv => 'cte.alt_pipeline');

-- one selective question to each form: totals of a single category
call pgmb.reg('cte.alt_pipeline_one_category_cte_chain', '{perf,planning,analyze,consistency,olap}', $q$
with filtered as (select id, entity_id, val, cat from g_events where cat in (0, 1)),
     per_entity as (select entity_id, count(*) as n, sum(val::numeric) as total from filtered group by entity_id),
     per_category as (select d.category, count(*) as entities, sum(t.n) as n, sum(t.total) as total
                      from per_entity t join g_dim d on d.id = t.entity_id % :n_g_dim + 1 group by d.category)
select * from per_category where category = :c$q$,
    setup => '\set c random(0, 9)', equiv => 'cte.alt_pipeline_one');

call pgmb.reg('cte.alt_pipeline_one_category_stacked_views', '{perf,planning,analyze,consistency,olap}', $q$
select * from v_category_totals_cat01 where category = :c$q$,
    setup => '\set c random(0, 9)', equiv => 'cte.alt_pipeline_one');

------------------------------------------------------------------------------
-- task 5: a large intermediate result read once (half of the table)
------------------------------------------------------------------------------
call pgmb.reg('cte.alt_large_cte_inlined', '{perf,planning,analyze,consistency,olap}', $q$
with big as (select entity_id, cat, val from g_events where val > 500)
select cat, count(*), sum(val::numeric) from big group by cat$q$, equiv => 'cte.alt_large');

call pgmb.reg('cte.alt_large_cte_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with big as materialized (select entity_id, cat, val from g_events where val > 500)
select cat, count(*), sum(val::numeric) from big group by cat$q$, equiv => 'cte.alt_large');

call pgmb.reg('cte.alt_large_subquery', '{perf,planning,analyze,consistency,olap}', $q$
select cat, count(*), sum(val::numeric) from (select entity_id, cat, val from g_events where val > 500) big group by cat$q$,
    equiv => 'cte.alt_large');

call pgmb.reg('cte.alt_large_temp_table', '{perf,planning,analyze,consistency,olap}', $q$
begin;
create temp table pgmb_tmp on commit drop as select entity_id, cat, val from g_events where val > 500;
select cat, count(*), sum(val::numeric) from pgmb_tmp group by cat;
commit;$q$, equiv => 'cte.alt_large');

-- the intermediate result is joined afterwards: here its statistics matter
call pgmb.reg('cte.alt_large_then_join_cte_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with big as materialized (select entity_id, cat, val from g_events where val > 990)
select count(*), sum(big.val::numeric) from big join mv_entity_totals t using (entity_id) where t.n > 0$q$,
    equiv => 'cte.alt_large_join');

call pgmb.reg('cte.alt_large_then_join_cte_inlined', '{perf,planning,analyze,consistency,olap}', $q$
with big as (select entity_id, cat, val from g_events where val > 990)
select count(*), sum(big.val::numeric) from big join mv_entity_totals t using (entity_id) where t.n > 0$q$,
    equiv => 'cte.alt_large_join');

call pgmb.reg('cte.alt_large_then_join_temp_table', '{perf,planning,analyze,consistency,olap}', $q$
begin;
create temp table pgmb_tmp on commit drop as select entity_id, cat, val from g_events where val > 990;
select count(*), sum(big.val::numeric) from pgmb_tmp big join mv_entity_totals t using (entity_id) where t.n > 0;
commit;$q$, equiv => 'cte.alt_large_join');

call pgmb.reg('cte.alt_large_then_join_temp_table_analyzed', '{perf,planning,analyze,consistency,olap}', $q$
begin;
create temp table pgmb_tmp on commit drop as select entity_id, cat, val from g_events where val > 990;
analyze pgmb_tmp;
select count(*), sum(big.val::numeric) from pgmb_tmp big join mv_entity_totals t using (entity_id) where t.n > 0;
commit;$q$, equiv => 'cte.alt_large_join');

------------------------------------------------------------------------------
-- task 6: a node of the tree with its children and grandchildren
------------------------------------------------------------------------------
call pgmb.reg('cte.alt_tree_recursive_cte', '{perf,planning,analyze,consistency,oltp}', $q$
with recursive sub(id, lvl) as (
    select id, 0 from g_tree where id = :id
    union all
    select t.id, s.lvl + 1 from g_tree t join sub s on t.parent_id = s.id where s.lvl < 2)
select count(*), sum(id) from sub$q$,
    setup => '\set id random(1, :n_g_tree)', equiv => 'cte.alt_tree');

-- the depth is known, so plain joins do
call pgmb.reg('cte.alt_tree_union_of_joins', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(id) from (
    select t0.id from g_tree t0 where t0.id = :id
    union all
    select t1.id from g_tree t0 join g_tree t1 on t1.parent_id = t0.id where t0.id = :id
    union all
    select t2.id from g_tree t0 join g_tree t1 on t1.parent_id = t0.id join g_tree t2 on t2.parent_id = t1.id where t0.id = :id) s$q$,
    setup => '\set id random(1, :n_g_tree)', equiv => 'cte.alt_tree');

call pgmb.reg('cte.alt_tree_cte_per_level', '{perf,planning,analyze,consistency,oltp}', $q$
with l0 as (select id from g_tree where id = :id),
     l1 as (select t.id from g_tree t join l0 on t.parent_id = l0.id),
     l2 as (select t.id from g_tree t join l1 on t.parent_id = l1.id)
select count(*), sum(id) from (select id from l0 union all select id from l1 union all select id from l2) s$q$,
    setup => '\set id random(1, :n_g_tree)', equiv => 'cte.alt_tree');

-- the numbering of the tree makes the range of each level computable
call pgmb.reg('cte.alt_tree_computed_ranges', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(id) from g_tree
where id = :id
   or id between 4 * :id - 2 and 4 * :id + 1
   or id between 4 * (4 * :id - 2) - 2 and 4 * (4 * :id + 1) + 1$q$,
    setup => '\set id random(1, :n_g_tree)', equiv => 'cte.alt_tree');

------------------------------------------------------------------------------
-- what the alternatives cost to keep
------------------------------------------------------------------------------
call pgmb.reg('cte.alt_cost_refresh_materialized_view', '{perf,olap}', $q$
refresh materialized view mv_entity_totals$q$, kind => 'write');

call pgmb.reg('cte.alt_cost_refresh_materialized_view_concurrently', '{perf,olap}', $q$
refresh materialized view concurrently mv_entity_totals$q$, kind => 'write');

-- an empty temporary table created and dropped: the fixed catalog cost
call pgmb.reg('cte.alt_cost_empty_temp_table', '{perf,oltp}', $q$
begin;
create temp table pgmb_tmp (entity_id int, n bigint, total numeric) on commit drop;
select count(*) from pgmb_tmp;
commit;$q$, kind => 'write');

call pgmb.reg('cte.alt_cost_empty_cte', '{perf,planning,oltp}', $q$
with t(entity_id, n, total) as (select 1, 1::bigint, 1::numeric where false)
select count(*) from t$q$);
