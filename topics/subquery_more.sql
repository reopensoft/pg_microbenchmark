-- Topic: subq (part 2) - subqueries in writes, how often they run, what the
-- planner turns them into, partition pruning by a subquery value, the other
-- places a subquery can sit (ORDER BY, DISTINCT ON, CASE, aggregates, windows,
-- set-returning functions, VALUES, set operations, constructors), edge sets,
-- correlation over several levels, locks, parallel plans, generic plans,
-- memory, the places where a subquery is refused, views and SQL functions.
--
-- Facts that cannot be seen in the rows (calls, plans, locks) are reported
-- by functions next to the value they must return (consistency groups).

------------------------------------------------------------------------------
-- objects
------------------------------------------------------------------------------
call pgmb.reg_ddl('subq.create_objects', 'schema', $q$
-- 100 rows to update, and a source with a value for each of them
create table g_sq_t (id int primary key, v int not null, w int not null);
insert into g_sq_t select n, 0, 0 from generate_series(1, 100) n;
create table g_sq_src (id int primary key, x int not null, y int not null);
insert into g_sq_src select n, n * 3, n * 7 from generate_series(1, 100) n;
-- one row per client for upserts
create table g_sq_upsert (id int primary key, v int not null);
create sequence g_sq_seq;
-- a view whose definition holds subqueries
create view v_sq_parent as
    select p.id, p.grp, (select count(*) from g_child c where c.parent_id = p.id) as children
    from g_parent p where p.dim_id in (select id from g_dim where category < 5);
create view v_sq_barrier with (security_barrier) as
    select id, grp, val from g_parent where grp in (select grp from g_parent where id <= 100);
-- an SQL function whose body is a scalar subquery: it is not inlined
create function sq_children(x bigint) returns bigint language sql stable as
'select (select count(*) from pgmb_data.g_child where parent_id = x)';
-- the plan of a statement as text, and the lines of EXPLAIN ANALYZE that match a pattern
create function sq_plan(p_sql text) returns text language plpgsql as
$f$declare
    r record;
    s text := '';
begin
    for r in execute 'explain (costs off) ' || p_sql loop
        s := s || r."QUERY PLAN" || chr(10);
    end loop;
    return s;
end$f$;
create function sq_analyze_lines(p_sql text, p_pattern text) returns bigint language plpgsql as
$f$declare
    r record;
    n bigint := 0;
begin
    for r in execute 'explain (analyze, costs off, timing off, summary off, buffers off) ' || p_sql loop
        if r."QUERY PLAN" ~ p_pattern then n := n + 1; end if;
    end loop;
    return n;
end$f$$q$);

call pgmb.reg('subq.more_expected_true', '{consistency}', $q$select true$q$, equiv => 'subq.more_true');
call pgmb.reg('subq.more_expected_false', '{consistency}', $q$select false$q$, equiv => 'subq.more_false');

------------------------------------------------------------------------------
-- writes
------------------------------------------------------------------------------
-- Each pair of statements is run against the same rows, the table is put
-- back in between, and the two results are compared.
call pgmb.reg_ddl('subq.create_write_facts', 'schema', $q$
create function sq_write_facts() returns text language plpgsql as
$f$declare
    a text; b text;
    out text[] := '{}';
begin
    -- SET col = (subquery) against UPDATE ... FROM
    with u as (update pgmb_data.g_sq_t t set v = (select x from pgmb_data.g_sq_src s where s.id = t.id) returning v)
    select count(*) || '/' || sum(v) into a from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    with u as (update pgmb_data.g_sq_t t set v = s.x from pgmb_data.g_sq_src s where s.id = t.id returning t.v)
    select count(*) || '/' || sum(v) into b from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    out := out || format('set=from %s', a = b);
    -- SET (a, b) = (subquery) against two columns from UPDATE ... FROM
    with u as (update pgmb_data.g_sq_t t set (v, w) = (select x, y from pgmb_data.g_sq_src s where s.id = t.id) returning v, w)
    select count(*) || '/' || sum(v) || '/' || sum(w) into a from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    with u as (update pgmb_data.g_sq_t t set v = s.x, w = s.y from pgmb_data.g_sq_src s where s.id = t.id returning t.v, t.w)
    select count(*) || '/' || sum(v) || '/' || sum(w) into b from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    out := out || format('row set=from %s', a = b);
    -- UPDATE ... FROM (subquery) against WHERE id IN (subquery)
    with u as (update pgmb_data.g_sq_t t set v = 1 from (select id from pgmb_data.g_sq_src where x % 2 = 0) s
               where s.id = t.id returning t.id)
    select count(*) || '/' || sum(id) into a from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    with u as (update pgmb_data.g_sq_t set v = 1 where id in (select id from pgmb_data.g_sq_src where x % 2 = 0) returning id)
    select count(*) || '/' || sum(id) into b from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    out := out || format('update from=in %s', a = b);
    -- DELETE ... USING (subquery) against DELETE ... WHERE EXISTS
    with d as (delete from pgmb_data.g_sq_t t using (select id from pgmb_data.g_sq_src where y > 350) s
               where s.id = t.id returning t.id)
    select count(*) || '/' || sum(id) into a from d;
    insert into pgmb_data.g_sq_t select n, 0, 0 from generate_series(1, 100) n on conflict do nothing;
    with d as (delete from pgmb_data.g_sq_t t where exists (select from pgmb_data.g_sq_src s where s.id = t.id and s.y > 350)
               returning t.id)
    select count(*) || '/' || sum(id) into b from d;
    insert into pgmb_data.g_sq_t select n, 0, 0 from generate_series(1, 100) n on conflict do nothing;
    out := out || format('delete using=exists %s', a = b);
    -- MERGE USING (subquery) against UPDATE ... FROM
    with m as (merge into pgmb_data.g_sq_t t using (select id, x from pgmb_data.g_sq_src where id <= 50) s on t.id = s.id
               when matched then update set v = s.x returning t.v)
    select count(*) || '/' || sum(v) into a from m;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    with u as (update pgmb_data.g_sq_t t set v = s.x from pgmb_data.g_sq_src s where s.id = t.id and s.id <= 50 returning t.v)
    select count(*) || '/' || sum(v) into b from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    out := out || format('merge=from %s', a = b);
    -- a subquery in RETURNING against a join after the update
    with u as (update pgmb_data.g_sq_t t set v = 1 where id <= 10 returning (select x from pgmb_data.g_sq_src s where s.id = t.id) as x)
    select sum(x)::text into a from u;
    update pgmb_data.g_sq_t set v = 0, w = 0;
    with u as (update pgmb_data.g_sq_t set v = 1 where id <= 10 returning id)
    select sum(s.x)::text into b from u join pgmb_data.g_sq_src s using (id);
    update pgmb_data.g_sq_t set v = 0, w = 0;
    out := out || format('returning=join %s', a = b);
    -- INSERT ... VALUES with a scalar subquery, and ON CONFLICT DO UPDATE with one
    insert into pgmb_data.g_sq_upsert values (-1, (select x from pgmb_data.g_sq_src where id = 5));
    insert into pgmb_data.g_sq_upsert values (-1, 0)
        on conflict (id) do update set v = g_sq_upsert.v + (select y from pgmb_data.g_sq_src where id = 5);
    select v::text into a from pgmb_data.g_sq_upsert where id = -1;
    delete from pgmb_data.g_sq_upsert where id = -1;
    out := out || format('insert and upsert %s', a = '50');
    return array_to_string(out, ', ');
end$f$$q$);

call pgmb.reg('subq.write_forms_agree', '{consistency}', $q$select sq_write_facts()$q$, equiv => 'subq.write');
call pgmb.reg('subq.write_forms_agree_expected', '{consistency}', $q$
select 'set=from t, row set=from t, update from=in t, delete using=exists t, merge=from t, returning=join t, insert and upsert t'::text$q$,
    equiv => 'subq.write');

-- the same writes, timed. Each client updates its own ten rows (clients that
-- overlap would deadlock, as hash joins visit the rows in different orders).
call pgmb.reg('subq.write_update_set_subquery', '{perf}', $q$
update g_sq_t t set v = (select x from g_sq_src s where s.id = t.id) where t.id between :id and :id + 9$q$,
    kind => 'write', setup => '\set id (:client_id % 10) * 10 + 1');
call pgmb.reg('subq.write_update_from', '{perf}', $q$
update g_sq_t t set v = s.x from g_sq_src s where s.id = t.id and t.id between :id and :id + 9$q$,
    kind => 'write', setup => '\set id (:client_id % 10) * 10 + 1');
call pgmb.reg('subq.write_update_row_set_subquery', '{perf}', $q$
update g_sq_t t set (v, w) = (select x, y from g_sq_src s where s.id = t.id) where t.id between :id and :id + 9$q$,
    kind => 'write', setup => '\set id (:client_id % 10) * 10 + 1');
call pgmb.reg('subq.write_merge_using_subquery', '{perf}', $q$
merge into g_sq_t t using (select id, x from g_sq_src where id between :id and :id + 9) s on t.id = s.id
when matched then update set v = s.x$q$,
    kind => 'write', setup => '\set id (:client_id % 10) * 10 + 1');
call pgmb.reg('subq.write_upsert_subquery', '{perf,oltp}', $q$
insert into g_sq_upsert values (:client_id, (select x from g_sq_src where id = :id))
on conflict (id) do update set v = (select y from g_sq_src where id = :id)$q$,
    kind => 'write', setup => '\set id random(1, 100)');

------------------------------------------------------------------------------
-- how often a subquery runs
------------------------------------------------------------------------------
-- uncorrelated: once (InitPlan); correlated: once per row (SubPlan); a hashed
-- subplan reads its whole input once
call pgmb.reg('subq.calls_expected_1', '{consistency}', $q$select 1::bigint$q$, equiv => 'subq.calls_1');
call pgmb.reg('subq.calls_expected_0', '{consistency}', $q$select 0::bigint$q$, equiv => 'subq.calls_0');
call pgmb.reg('subq.calls_uncorrelated_initplan', '{consistency}', $q$
select cte_calls($s$select count(x) from (select n, (select cte_volatile(1)) as x from generate_series(1, 100) n) s$s$)$q$,
    equiv => 'subq.calls_1');
call pgmb.reg('subq.calls_correlated_subplan', '{consistency}', $q$
select cte_calls($s$select count(x) from (select n, (select cte_volatile(n)) as x from generate_series(1, 100) n) s$s$)$q$,
    equiv => 'subq.calls_100');
call pgmb.reg('subq.calls_hashed_subplan', '{consistency}', $q$
select cte_calls($s$select count(*) from generate_series(1, 1000) n
                    where n not in (select nullif(cte_volatile(m), -1) from generate_series(1, 100) m)$s$)$q$,
    equiv => 'subq.calls_100');
-- nextval(): one value for the whole statement, or one per row
call pgmb.reg('subq.calls_nextval_uncorrelated', '{consistency}', $q$
select count(distinct x) from (select (select nextval('g_sq_seq')) as x from generate_series(1, 10) n) s$q$,
    equiv => 'subq.calls_1');
call pgmb.reg('subq.calls_nextval_correlated', '{consistency}', $q$
select count(distinct x) from (select (select nextval('g_sq_seq') + 0 * n) as x from generate_series(1, 10) n) s$q$,
    equiv => 'subq.ten');
call pgmb.reg('subq.calls_expected_10', '{consistency}', $q$select 10::bigint$q$, equiv => 'subq.ten');

------------------------------------------------------------------------------
-- what the planner turns a subquery into
------------------------------------------------------------------------------
-- converted to a join: no SubPlan left
call pgmb.reg('subq.plan_exists_becomes_join', '{consistency}', $q$
select sq_plan($s$select count(*) from g_parent p where exists (select from g_child c where c.parent_id = p.id and c.kind = 1)$s$) ~ 'SubPlan'$q$,
    equiv => 'subq.more_false');
call pgmb.reg('subq.plan_in_becomes_join', '{consistency}', $q$
select sq_plan($s$select count(*) from g_parent where id in (select parent_id from g_child where kind = 1)$s$) ~ 'SubPlan'$q$,
    equiv => 'subq.more_false');
call pgmb.reg('subq.plan_in_with_limit_becomes_join', '{consistency}', $q$
select sq_plan($s$select count(*) from g_parent where id in (select parent_id from g_child where kind = 1 limit 100)$s$) ~ 'SubPlan'$q$,
    equiv => 'subq.more_false');
call pgmb.reg('subq.plan_not_exists_becomes_anti_join', '{consistency}', $q$
select sq_plan($s$select count(*) from g_parent p where not exists (select from g_child c where c.parent_id = p.id)$s$) ~ 'Anti Join'$q$,
    equiv => 'subq.more_true');
-- left as a SubPlan
call pgmb.reg('subq.plan_or_of_two_exists_stays_subplan', '{consistency}', $q$
select sq_plan($s$select count(*) from g_parent p
                  where exists (select from g_child c where c.parent_id = p.id and c.kind = 1)
                     or exists (select from g_child c where c.parent_id = p.id and c.kind = 2)$s$) ~ 'SubPlan'$q$,
    equiv => 'subq.more_true');
call pgmb.reg('subq.plan_exists_with_having_stays_subplan', '{consistency}', $q$
select sq_plan($s$select count(*) from g_parent p
                  where exists (select 1 from g_child c where c.parent_id = p.id having count(*) > 5)$s$) ~ 'SubPlan'$q$,
    equiv => 'subq.more_true');
call pgmb.reg('subq.plan_not_in_nullable_stays_subplan', '{consistency}', $q$
select sq_plan($s$select count(*) from g_parent where id not in (select nullif(parent_id, -1) from g_child where kind = 1)$s$) ~ 'SubPlan'$q$,
    equiv => 'subq.more_true');
-- NOT IN on a NOT NULL column: an anti join in recent versions, a SubPlan in
-- older ones; the planning check records the plan shape, to compare versions
call pgmb.reg('subq.plan_not_in_not_null_column', '{perf,planning,analyze}', $q$
select count(*) from g_parent where id not in (select parent_id from g_child where kind = 1)$q$);

-- the forms that stay SubPlans return the same rows as forms that are joins
call pgmb.reg('subq.or_of_two_exists', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from g_parent p where p.id between :id and :id + 999
  and (exists (select from g_child c where c.parent_id = p.id and c.kind = 1)
       or exists (select from g_child c where c.parent_id = p.id and c.kind = 2))$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.or_exists');
call pgmb.reg('subq.or_of_two_exists_as_one_exists', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from g_parent p where p.id between :id and :id + 999
  and exists (select from g_child c where c.parent_id = p.id and c.kind in (1, 2))$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.or_exists');
call pgmb.reg('subq.exists_with_having', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_parent p where p.id between :id and :id + 999
  and exists (select 1 from g_child c where c.parent_id = p.id having count(*) > 5)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.exists_having');
call pgmb.reg('subq.exists_with_having_as_group_join', '{perf,planning,analyze,consistency}', $q$
select count(*) from g_parent p
     join (select parent_id from g_child group by parent_id having count(*) > 5) c on c.parent_id = p.id
where p.id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.exists_having');

------------------------------------------------------------------------------
-- partition pruning at run time by a subquery value
------------------------------------------------------------------------------
-- the value comes from an InitPlan: 15 of the 16 partitions are never scanned
call pgmb.reg('subq.pruning_initplan_partitions_skipped', '{consistency}', $q$
begin;
set local max_parallel_workers_per_gather = 0;
select sq_analyze_lines($s$select count(*) from g_part where bucket = (select 3)$s$, 'never executed');
commit;$q$, equiv => 'subq.fifteen');
call pgmb.reg('subq.pruning_expected_15', '{consistency}', $q$select 15::bigint$q$, equiv => 'subq.fifteen');

call pgmb.reg('subq.pruning_initplan', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val::numeric) from g_part where bucket = (select :b)$q$,
    setup => '\set b random(0, 15)', equiv => 'subq.pruning');
call pgmb.reg('subq.pruning_literal', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val::numeric) from g_part where bucket = :b$q$,
    setup => '\set b random(0, 15)', equiv => 'subq.pruning');
-- a new value for every outer row: pruning on every rescan
call pgmb.reg('subq.pruning_per_outer_row', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(s.n) from (values (:b), ((:b + 5) % 16), ((:b + 9) % 16)) v(b),
     lateral (select count(*) as n from g_part where bucket = v.b) s$q$,
    setup => '\set b random(0, 15)', equiv => 'subq.pruning_rescan');
call pgmb.reg('subq.pruning_per_outer_row_as_in', '{perf,planning,analyze,consistency}', $q$
select 3::bigint, count(*) from g_part where bucket in (:b, (:b + 5) % 16, (:b + 9) % 16)$q$,
    setup => '\set b random(0, 15)', equiv => 'subq.pruning_rescan');

------------------------------------------------------------------------------
-- ORDER BY and DISTINCT ON by a subquery
------------------------------------------------------------------------------
-- the order is returned as an array, so a wrong order fails the comparison
call pgmb.reg('subq.order_by_correlated_subquery', '{perf,planning,analyze,consistency}', $q$
select array(select p.id from g_parent p where p.id between :id and :id + 99
             order by (select count(*) from g_child c where c.parent_id = p.id) desc, p.id limit 10)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.order_by');
call pgmb.reg('subq.order_by_join', '{perf,planning,analyze,consistency}', $q$
select array(select p.id from g_parent p left join g_child c on c.parent_id = p.id
             where p.id between :id and :id + 99 group by p.id order by count(c.id) desc, p.id limit 10)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.order_by');
-- an uncorrelated key is the same for every row and changes nothing
call pgmb.reg('subq.order_by_uncorrelated_subquery', '{perf,planning,consistency}', $q$
select array(select id from g_parent where id between :id and :id + 99 order by (select 1), id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.order_by_constant');
call pgmb.reg('subq.order_by_column_only', '{perf,planning,consistency}', $q$
select array(select id from g_parent where id between :id and :id + 99 order by id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.order_by_constant');

-- the first parent of each dimension category
call pgmb.reg('subq.distinct_on_subquery', '{perf,planning,analyze,consistency}', $q$
select array(select distinct on ((select category from g_dim d where d.id = p.dim_id)) p.id
             from g_parent p where p.id between :id and :id + 999
             order by (select category from g_dim d where d.id = p.dim_id), p.id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.distinct_on');
call pgmb.reg('subq.distinct_on_join', '{perf,planning,analyze,consistency}', $q$
select array(select distinct on (d.category) p.id
             from g_parent p join g_dim d on d.id = p.dim_id where p.id between :id and :id + 999
             order by d.category, p.id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.distinct_on');

------------------------------------------------------------------------------
-- CASE, COALESCE, NULLIF: is the subquery in an untaken branch run?
------------------------------------------------------------------------------
call pgmb.reg('subq.case_untaken_branch_correlated', '{consistency}', $q$
select cte_calls($s$select count(x) from (select case when n > 0 then 1 else (select cte_volatile(n)) end as x
                                          from generate_series(1, 100) n) s$s$)$q$,
    equiv => 'subq.calls_0');
call pgmb.reg('subq.case_untaken_branch_uncorrelated', '{consistency}', $q$
select cte_calls($s$select count(x) from (select case when n > 0 then 1 else (select cte_volatile(1)) end as x
                                          from generate_series(1, 100) n) s$s$)$q$,
    equiv => 'subq.calls_0');
call pgmb.reg('subq.coalesce_second_argument_not_needed', '{consistency}', $q$
select cte_calls($s$select count(x) from (select coalesce(n, (select cte_volatile(n))) as x
                                          from generate_series(1, 100) n) s$s$)$q$,
    equiv => 'subq.calls_0');
-- NULLIF needs both arguments: an uncorrelated one is computed once
call pgmb.reg('subq.nullif_argument_computed_once', '{consistency}', $q$
select cte_calls($s$select count(x) from (select nullif(n, (select cte_volatile(1))) as x
                                          from generate_series(1, 100) n) s$s$)$q$,
    equiv => 'subq.calls_1');
-- the branch taken for half of the rows
call pgmb.reg('subq.case_branch_for_half_of_the_rows', '{consistency}', $q$
select cte_calls($s$select count(x) from (select case when n % 2 = 0 then (select cte_volatile(n)) end as x
                                          from generate_series(1, 100) n) s$s$)$q$,
    equiv => 'subq.calls_50');
call pgmb.reg('subq.calls_expected_50', '{consistency}', $q$select 50::bigint$q$, equiv => 'subq.calls_50');

------------------------------------------------------------------------------
-- aggregates and windows
------------------------------------------------------------------------------
-- a subquery as the argument of an aggregate, in FILTER, in its ORDER BY
call pgmb.reg('subq.aggregate_argument', '{perf,planning,analyze,consistency}', $q$
select sum((select count(*) from g_child c where c.parent_id = p.id)) from g_parent p where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.agg_argument');
call pgmb.reg('subq.aggregate_argument_as_join', '{perf,planning,analyze,consistency}', $q$
select count(c.id) from g_parent p left join g_child c on c.parent_id = p.id where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.agg_argument');
call pgmb.reg('subq.aggregate_filter', '{perf,planning,analyze,consistency}', $q$
select count(*) filter (where p.id in (select parent_id from g_child where kind = 7)), count(*)
from g_parent p where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.agg_filter');
call pgmb.reg('subq.aggregate_filter_as_case', '{perf,planning,analyze,consistency}', $q$
select count(*) filter (where k.parent_id is not null), count(*)
from g_parent p left join (select distinct parent_id from g_child where kind = 7) k on k.parent_id = p.id
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.agg_filter');
call pgmb.reg('subq.aggregate_order_by_subquery', '{perf,planning,analyze,consistency}', $q$
select array_agg(p.id order by (select count(*) from g_child c where c.parent_id = p.id) desc, p.id)
from g_parent p where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.agg_order_by');
call pgmb.reg('subq.aggregate_order_by_join', '{perf,planning,analyze,consistency}', $q$
select array_agg(id order by n desc, id)
from (select p.id, count(c.id) as n from g_parent p left join g_child c on c.parent_id = p.id
      where p.id between :id and :id + 19 group by p.id) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.agg_order_by');

-- a window partitioned and ordered by subqueries
call pgmb.reg('subq.window_partition_by_subquery', '{perf,planning,analyze,consistency}', $q$
select p.id, rank() over (partition by (select category from g_dim d where d.id = p.dim_id) order by p.val, p.id)
from g_parent p where p.id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.window');
call pgmb.reg('subq.window_partition_by_join', '{perf,planning,analyze,consistency}', $q$
select p.id, rank() over (partition by d.category order by p.val, p.id)
from g_parent p join g_dim d on d.id = p.dim_id where p.id between :id and :id + 199$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.window');

------------------------------------------------------------------------------
-- set-returning functions, VALUES, set operations
------------------------------------------------------------------------------
call pgmb.reg('subq.srf_argument', '{perf,planning,consistency}', $q$
select count(*), sum(g) from generate_series(1, (select count(*)::int from g_child where parent_id = :id) * 10) g$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.srf');
call pgmb.reg('subq.srf_argument_computed_first', '{perf,planning,consistency}', $q$
select count(*), sum(g) from (select count(*)::int * 10 as n from g_child where parent_id = :id) c, generate_series(1, c.n) g$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.srf');

call pgmb.reg('subq.values_with_subqueries', '{perf,planning,consistency}', $q$
select * from (values (1, (select count(*) from g_child where parent_id = :id)),
                      (2, (select max(grp) from g_parent where id = :id))) v(k, x)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.values');
call pgmb.reg('subq.values_as_union_all', '{perf,planning,consistency}', $q$
select 1, count(*) from g_child where parent_id = :id
union all
select 2, max(grp) from g_parent where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.values');

-- set operation branches with their own ORDER BY and LIMIT
call pgmb.reg('subq.set_operation_branches_with_limits', '{perf,planning,analyze,consistency}', $q$
select array(select id from ((select id from g_parent where grp = :g order by val desc, id limit 5)
                             union
                             (select id from g_parent where grp = :g order by val, id limit 5)) s order by id)$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.set_ops');
call pgmb.reg('subq.set_operation_branches_as_window', '{perf,planning,analyze,consistency}', $q$
select array(select id from (select id, row_number() over (order by val desc, id) as hi,
                                    row_number() over (order by val, id) as lo
                             from g_parent where grp = :g) s
             where hi <= 5 or lo <= 5 order by id)$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.set_ops');

------------------------------------------------------------------------------
-- constructors
------------------------------------------------------------------------------
call pgmb.reg('subq.array_constructor_ordered', '{perf,planning,consistency,oltp}', $q$
select array(select amount from g_child where parent_id = :id order by amount desc, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.array_ctor');
call pgmb.reg('subq.array_agg_ordered', '{perf,planning,consistency,oltp}', $q$
select coalesce(array_agg(amount order by amount desc, id), '{}') from g_child where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.array_ctor');
call pgmb.reg('subq.row_constructor_from_subqueries', '{perf,planning,consistency,oltp}', $q$
select row((select min(id) from g_parent where grp = :g), (select max(id) from g_parent where grp = :g))::text$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.row_ctor');
call pgmb.reg('subq.row_constructor_one_subquery', '{perf,planning,consistency,oltp}', $q$
select (select row(min(id), max(id)) from g_parent where grp = :g)::text$q$,
    setup => '\set g random(0, 99)', equiv => 'subq.row_ctor');

------------------------------------------------------------------------------
-- edge sets
------------------------------------------------------------------------------
call pgmb.reg('subq.edge_sets', '{consistency}', $q$
select (select 1 where false) is null,
       5 > all (select 1 where false), 5 = any (select 1 where false),
       5 in (select 5 union all select 5 union all select 5),
       (select count(*) from generate_series(1, 3) n where n in (select 2 union all select 2)),
       null::int in (select 1), 1 in (select null::int), 1 in (select null::int union all select 1),
       1 not in (select null::int), 2 not in (select 1 where false)$q$,
    equiv => 'subq.edge');
call pgmb.reg('subq.edge_sets_expected', '{consistency}', $q$
select true, true, false, true, 1::bigint, null::boolean, null::boolean, true, null::boolean, true$q$,
    equiv => 'subq.edge');

------------------------------------------------------------------------------
-- correlation over several levels
------------------------------------------------------------------------------
-- the innermost subquery reads the outermost row (two levels up) and the one between
call pgmb.reg('subq.correlation_two_levels_up', '{perf,planning,analyze,consistency}', $q$
select p.id,
       (select sum((select count(*) from g_child c where c.parent_id = p.id and c.kind = d.category))
        from g_dim d where d.id <= 8) as n
from g_parent p where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.corr_two');
call pgmb.reg('subq.correlation_two_levels_up_as_join', '{perf,planning,analyze,consistency}', $q$
select p.id, coalesce(sum(n), 0) as n
from g_parent p
     left join (select c.parent_id, count(*) as n from g_child c join g_dim d on d.category = c.kind and d.id <= 8
                group by c.parent_id, d.id) x on x.parent_id = p.id
where p.id between :id and :id + 19 group by p.id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.corr_two');
-- three levels: parent, its dimension, the children of the dimension's parents
call pgmb.reg('subq.correlation_three_levels_up', '{perf,planning,analyze,consistency}', $q$
select p.id,
       (select (select (select count(*) from g_child c where c.parent_id = p.id and c.kind < d.category)
                from g_dim d where d.id = q.dim_id)
        from g_parent q where q.id = p.id) as n
from g_parent p where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.corr_three');
call pgmb.reg('subq.correlation_three_levels_up_as_join', '{perf,planning,analyze,consistency}', $q$
select p.id, count(c.id) as n
from g_parent p join g_dim d on d.id = p.dim_id left join g_child c on c.parent_id = p.id and c.kind < d.category
where p.id between :id and :id + 19 group by p.id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.corr_three');

------------------------------------------------------------------------------
-- FOR UPDATE inside a subquery: which rows are locked
------------------------------------------------------------------------------
-- In FROM, the outer filter reaches the locking subquery: only the rows that
-- pass it are locked. In WHERE, the subquery locks every row it returns.
call pgmb.reg_ddl('subq.create_lock_facts', 'schema', $q$
create function sq_lock_facts() returns text language plpgsql as
$f$declare
    from_rows bigint; from_locked bigint;
    where_rows bigint; where_locked bigint;
begin
    -- rows 1 to 10, then 11 to 20, so that the two counts do not mix
    select count(*) into where_rows from pgmb_data.g_sq_t
    where id <= 5 and id in (select id from pgmb_data.g_sq_t where id <= 10 for update);
    select count(*) into where_locked from pgmb_data.g_sq_t where id <= 10 and xmax = pg_current_xact_id()::xid;
    select count(*) into from_rows from (select id from pgmb_data.g_sq_t where id between 11 and 20 for update) s where id <= 15;
    select count(*) into from_locked from pgmb_data.g_sq_t where id between 11 and 20 and xmax = pg_current_xact_id()::xid;
    return format('from: %s rows, %s locked; where: %s rows, %s locked', from_rows, from_locked, where_rows, where_locked);
end$f$$q$);
call pgmb.reg('subq.lock_rows_in_subquery', '{consistency}', $q$select sq_lock_facts()$q$, equiv => 'subq.lock');
call pgmb.reg('subq.lock_rows_in_subquery_expected', '{consistency}',
    $q$select 'from: 5 rows, 5 locked; where: 5 rows, 10 locked'::text$q$, equiv => 'subq.lock');

------------------------------------------------------------------------------
-- parallel plans
------------------------------------------------------------------------------
\set pgmb_sq_par 'begin;\nset local max_parallel_workers_per_gather = 2;\nset local min_parallel_table_scan_size = 0;\nset local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\n'
-- an uncorrelated value computed once and used by every worker
call pgmb.reg('subq.parallel_initplan', '{perf,planning,analyze,consistency}', :'pgmb_sq_par' || $q$
select count(*), sum(k_10k) from g_narrow where k_100 = (select min(k_100) + :k from g_narrow where id <= 100)$q$ || E';\ncommit;',
    setup => '\set k random(0, 50)', equiv => 'subq.parallel_initplan');
call pgmb.reg('subq.parallel_initplan_serial', '{perf,planning,analyze,consistency}', $q$
begin;
set local max_parallel_workers_per_gather = 0;
select count(*), sum(k_10k) from g_narrow where k_100 = (select min(k_100) + :k from g_narrow where id <= 100);
commit;$q$,
    setup => '\set k random(0, 50)', equiv => 'subq.parallel_initplan');
-- (index paths off: on small data an index would be cheaper than any parallel scan)
call pgmb.reg('subq.parallel_initplan_has_gather', '{consistency}', :'pgmb_sq_par' || $q$
set local enable_indexscan = off;
set local enable_indexonlyscan = off;
set local enable_bitmapscan = off;
select sq_plan($s$select count(*) from g_narrow where k_100 = (select min(k_100) from g_narrow where id <= 100)$s$) ~ 'Gather'$q$
    || E';\ncommit;', equiv => 'subq.more_true');
-- a correlated subquery per row of a parallel scan
call pgmb.reg('subq.parallel_correlated_subplan', '{perf,planning,analyze,consistency}', :'pgmb_sq_par' || $q$
select count(*), sum((select category from g_dim d where d.id = n.k_100 % 10 + 1)) from g_narrow n where n.id <= 50000$q$
    || E';\ncommit;', equiv => 'subq.parallel_subplan');
call pgmb.reg('subq.parallel_correlated_subplan_as_join', '{perf,planning,analyze,consistency}', :'pgmb_sq_par' || $q$
select count(*), sum(d.category) from g_narrow n join g_dim d on d.id = n.k_100 % 10 + 1 where n.id <= 50000$q$
    || E';\ncommit;', equiv => 'subq.parallel_subplan');

------------------------------------------------------------------------------
-- generic and custom plans with a parameter inside the subquery
------------------------------------------------------------------------------
call pgmb.reg_ddl('subq.create_prepared_facts', 'schema', $q$
create function sq_prepared_facts() returns text language plpgsql as
$f$declare
    g bigint; c bigint; plain bigint;
begin
    begin
        execute 'deallocate sq_ps';
    exception when invalid_sql_statement_name then null;
    end;
    execute 'prepare sq_ps(int) as select count(*) from pgmb_data.g_parent p
             where p.id in (select parent_id from pgmb_data.g_child where kind = $1)
               and p.grp < (select max(grp) from pgmb_data.g_parent where id <= $1 * 100 + 100)';
    perform set_config('plan_cache_mode', 'force_generic_plan', true);
    execute 'execute sq_ps(3)' into g;
    perform set_config('plan_cache_mode', 'force_custom_plan', true);
    execute 'execute sq_ps(3)' into c;
    perform set_config('plan_cache_mode', 'auto', true);
    execute 'deallocate sq_ps';
    select count(*) into plain from pgmb_data.g_parent p
    where p.id in (select parent_id from pgmb_data.g_child where kind = 3)
      and p.grp < (select max(grp) from pgmb_data.g_parent where id <= 400);
    return format('generic = custom: %s, custom = literal: %s', g = c, c = plain);
end$f$$q$);
call pgmb.reg('subq.prepared_generic_and_custom', '{consistency}', $q$select sq_prepared_facts()$q$, equiv => 'subq.prepared');
call pgmb.reg('subq.prepared_generic_and_custom_expected', '{consistency}',
    $q$select 'generic = custom: t, custom = literal: t'::text$q$, equiv => 'subq.prepared');

-- the same statement under the prepared protocol, with the parameter in the subquery
call pgmb.reg('subq.prepared_parameter_in_subquery', '{perf,planning,oltp}', $q$
select count(*) from g_parent p where p.id between :id and :id + 99
  and p.id in (select parent_id from g_child where kind = :k)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', protocol => 'prepared');
call pgmb.reg('subq.simple_parameter_in_subquery', '{perf,planning,oltp}', $q$
select count(*) from g_parent p where p.id between :id and :id + 99
  and p.id in (select parent_id from g_child where kind = :k)$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set k random(0, 7)', protocol => 'simple');

------------------------------------------------------------------------------
-- memory: a hashed subplan must fit in memory
------------------------------------------------------------------------------
-- It cannot spill to disk, so the planner only hashes a set it expects to fit;
-- with little memory the set is searched for every outer row instead.
call pgmb.reg('subq.memory_hashed_with_enough_memory', '{consistency}', $q$
begin;
set local work_mem = '64MB';
select sq_plan($s$select count(*) from g_narrow where id <= 10000
                  and k_uniq not in (select nullif(k_uniq, -1) from g_narrow where id <= 5000)$s$) ~ 'hashed SubPlan';
commit;$q$, equiv => 'subq.more_true');
call pgmb.reg('subq.memory_not_hashed_with_little_memory', '{consistency}', $q$
begin;
set local work_mem = '64kB';
select sq_plan($s$select count(*) from g_narrow where id <= 10000
                  and k_uniq not in (select nullif(k_uniq, -1) from g_narrow where id <= 5000)$s$) ~ 'hashed SubPlan';
commit;$q$, equiv => 'subq.more_false');

------------------------------------------------------------------------------
-- places where a subquery is refused
------------------------------------------------------------------------------
call pgmb.reg('subq.err_in_check_constraint', '{errors}',
    $q$create table g_sq_bad (a int check (a > (select 1)))$q$, expect_error => '0A000');
call pgmb.reg('subq.err_in_default', '{errors}',
    $q$create table g_sq_bad (a int default (select 1))$q$, expect_error => '0A000');
call pgmb.reg('subq.err_in_generated_column', '{errors}',
    $q$create table g_sq_bad (a int, b int generated always as (a + (select 1)) stored)$q$, expect_error => '0A000');
call pgmb.reg('subq.err_in_index_expression', '{errors}',
    $q$create index g_sq_bad_ix on g_sq_t ((v + (select 1)))$q$, expect_error => '0A000');
call pgmb.reg('subq.err_in_partial_index_predicate', '{errors}',
    $q$create index g_sq_bad_ix on g_sq_t (v) where v > (select 1)$q$, expect_error => '0A000');

------------------------------------------------------------------------------
-- views and SQL functions
------------------------------------------------------------------------------
-- a view with a subquery in its select list and in its WHERE
call pgmb.reg('subq.view_with_subqueries', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(children) from v_sq_parent where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.view');
call pgmb.reg('subq.view_with_subqueries_written_out', '{perf,planning,analyze,consistency}', $q$
select count(*), sum((select count(*) from g_child c where c.parent_id = p.id))
from g_parent p where p.id between :id and :id + 99 and p.dim_id in (select id from g_dim where category < 5)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.view');
-- a security barrier view: the outer filter is applied after the view's own
call pgmb.reg('subq.security_barrier_view_with_subquery', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from v_sq_barrier where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.barrier');
call pgmb.reg('subq.security_barrier_view_written_out', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(val) from g_parent
where id between :id and :id + 999 and grp in (select grp from g_parent where id <= 100)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.barrier');
-- an SQL function made of a scalar subquery is not inlined: it stays a call
call pgmb.reg('subq.sql_function_with_subquery', '{perf,planning,analyze,consistency}', $q$
select count(*), sum(sq_children(id)) from g_parent where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.sql_function');
call pgmb.reg('subq.sql_function_written_out', '{perf,planning,analyze,consistency}', $q$
select count(*), sum((select count(*) from g_child where parent_id = p.id)) from g_parent p where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'subq.sql_function');
call pgmb.reg('subq.sql_function_with_subquery_not_inlined', '{consistency}', $q$
select sq_plan($s$select sq_children(id) from g_parent where id < 3$s$) ~ 'SubPlan'$q$,
    equiv => 'subq.more_false');
