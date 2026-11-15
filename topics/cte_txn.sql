-- Topic: cte (part 14) - constraints timing, parallel safety, isolation
-- levels, snapshots, security barrier views and statement_timeout.
-- Tests with several statements (begin; ...; commit;) are perf-only.

call pgmb.reg_ddl('cte.create_noop_par_functions', 'schema', $q$
create function noop_par_safe(int) returns int language plpgsql stable parallel safe as 'begin return $1; end';
create function noop_par_restricted(int) returns int language plpgsql stable parallel restricted as 'begin return $1; end';
create function noop_par_unsafe(int) returns int language plpgsql stable parallel unsafe as 'begin return $1; end'$q$);
call pgmb.reg_ddl('cte.create_dml_qty_functions', 'schema', $q$
create function dml_qty_stable(bigint) returns int language plpgsql stable as
'begin return (select qty from pgmb_data.g_dml where id = $1); end';
create function dml_qty_volatile(bigint) returns int language plpgsql volatile as
'begin return (select qty from pgmb_data.g_dml where id = $1); end'$q$);

------------------------------------------------------------------------------
-- constraints: checked per row, at the end of the statement, or at commit
------------------------------------------------------------------------------
-- swapping two unique values in one statement needs a deferrable constraint,
-- even when it is checked immediately (that is: at the end of the statement)
call pgmb.reg('cte.defer_unique_swap_one_writer', '{perf,planning,oltp}', $q$
with u as (update g_dml_defer t set code = o.code from g_dml_defer o
           where t.id in (:id, :id + 1) and o.id = case when t.id = :id then :id + 1 else :id end
           returning t.id)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(:n_g_dml / 2 + 1, :n_g_dml - 1)');

-- each writer alone would leave a duplicate; together they are consistent
call pgmb.reg('cte.defer_unique_swap_two_writers', '{perf,planning,oltp}', $q$
with a as (update g_dml_defer set code = (select code from g_dml_defer where id = :id + 1) where id = :id returning id),
     b as (update g_dml_defer set code = (select code from g_dml_defer where id = :id) where id = :id + 1 returning id)
select (select count(*) from a) + (select count(*) from b)$q$,
    kind => 'write', setup => '\set id random(:n_g_dml / 2 + 1, :n_g_dml - 1)');

call pgmb.reg('cte.defer_unique_swap_checked_at_commit', '{perf,oltp}', $q$
begin;
set constraints all deferred;
with a as (update g_dml_defer set code = (select code from g_dml_defer where id = :id + 1) where id = :id returning id),
     b as (update g_dml_defer set code = (select code from g_dml_defer where id = :id) where id = :id + 1 returning id)
select (select count(*) from a) + (select count(*) from b);
commit;$q$,
    kind => 'write', setup => '\set id random(:n_g_dml / 2 + 1, :n_g_dml - 1)');

-- the same swap against the non-deferrable constraint of g_dml fails on the first row
call pgmb.reg('cte.err_defer_unique_swap_not_deferrable', '{errors}', $q$
with a as (update g_dml set code = (select code from g_dml where id = 2) where id = 1 returning id),
     b as (update g_dml set code = (select code from g_dml where id = 1) where id = 2 returning id)
select (select count(*) from a) + (select count(*) from b)$q$, expect_error => '23505');

-- foreign key checks queue up: 100 rows checked at statement end or at commit
call pgmb.reg('cte.defer_fk_100_rows_checked_at_statement_end', '{perf,planning}', $q$
with u as (update g_dml_defer set dim_id = 1 + dim_id % :n_g_dim where id between :id and :id + 99 returning id)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(:n_g_dml / 2 + 1, :n_g_dml)');

call pgmb.reg('cte.defer_fk_100_rows_checked_at_commit', '{perf}', $q$
begin;
set constraints all deferred;
with u as (update g_dml_defer set dim_id = 1 + dim_id % :n_g_dim where id between :id and :id + 99 returning id)
select count(*) from u;
commit;$q$,
    kind => 'write', setup => '\set id random(:n_g_dml / 2 + 1, :n_g_dml)');

-- a foreign key is checked after the statement even when not deferrable: the
-- child may be inserted before its parent by an earlier CTE. Rolled back to
-- keep the tree; the ids are per client.
call pgmb.reg('cte.defer_fk_child_before_parent_same_statement', '{perf,oltp}', $q$
begin;
with child as (insert into g_tree values (:p + 1, :p, 1, 0, 'child') returning id),
     parent as (insert into g_tree values (:p, 1, 0, 0, 'parent') returning id)
select (select count(*) from child) + (select count(*) from parent);
rollback;$q$,
    kind => 'write', setup => '\set p :n_g_tree + 1 + 2 * :client_id');

call pgmb.reg('cte.err_defer_fk_missing_parent_in_cte', '{errors}',
    $q$with child as (insert into g_tree values (-1, -2, 0, 0, 'orphan')) select 1$q$, expect_error => '23503');

------------------------------------------------------------------------------
-- parallel safety of functions inside a CTE
-- (CTE Scan itself: cte.parallel_materialized; inlined: cte.parallel_inlined)
------------------------------------------------------------------------------
call pgmb.reg('cte.parallel_function_safe', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with c as (select cat, noop_par_safe(cat::int) as v from g_events where val > 1)
select cat, count(*), sum(v) from c group by cat;
commit;$q$);

-- runs, but only in the leader, above the Gather
call pgmb.reg('cte.parallel_function_restricted', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with c as (select cat, noop_par_restricted(cat::int) as v from g_events where val > 1)
select cat, count(*), sum(v) from c group by cat;
commit;$q$);

-- one unsafe function anywhere makes the whole statement serial
call pgmb.reg('cte.parallel_function_unsafe', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with c as (select cat, noop_par_unsafe(cat::int) as v from g_events where val > 1)
select cat, count(*), sum(v) from c group by cat;
commit;$q$);

call pgmb.reg('cte.parallel_function_unsafe_in_unrelated_cte', '{perf,olap}', $q$
begin;
set local max_parallel_workers_per_gather = 4;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
with one as materialized (select noop_par_unsafe(1) as x),
     c as (select cat, val from g_events where val > 1)
select cat, count(*), avg(val), (select x from one) from c group by cat;
commit;$q$);

------------------------------------------------------------------------------
-- isolation levels
------------------------------------------------------------------------------
call pgmb.reg('cte.iso_read_committed_two_reads', '{perf,oltp}', $q$
begin isolation level read committed;
with c as (select id, val from g_parent where id between :id and :id + 9) select count(*), sum(val) from c;
with c as (select id, val from g_parent where id between :id and :id + 9) select count(*), sum(val) from c;
commit;$q$,
    setup => '\set id random(1, :n_g_parent)');

-- one snapshot for both statements
call pgmb.reg('cte.iso_repeatable_read_two_reads', '{perf,oltp}', $q$
begin isolation level repeatable read;
with c as (select id, val from g_parent where id between :id and :id + 9) select count(*), sum(val) from c;
with c as (select id, val from g_parent where id between :id and :id + 9) select count(*), sum(val) from c;
commit;$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.iso_read_committed_writer', '{perf,oltp,concurrency}', $q$
begin isolation level read committed;
with u as (update g_parent set val = val + 1 where id = :id returning id, val) select * from u;
commit;$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

-- concurrent updates of one row end in a serialization failure; pgbench retries
call pgmb.reg('cte.iso_repeatable_read_writer', '{perf,oltp,concurrency}', $q$
begin isolation level repeatable read;
with u as (update g_parent set val = val + 1 where id = :id returning id, val) select * from u;
commit;$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('cte.iso_serializable_writer', '{perf,oltp,concurrency}', $q$
begin isolation level serializable;
with u as (update g_parent set val = val + 1 where id = :id returning id, val) select * from u;
commit;$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

-- read in one statement, write in the next: the classic lost-update shape
call pgmb.reg('cte.iso_repeatable_read_read_then_write', '{perf,oltp,concurrency}', $q$
begin isolation level repeatable read;
with c as (select val from g_parent where id = :id) select val from c;
with u as (update g_parent set val = val + 1 where id = :id returning val) select val from u;
commit;$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

------------------------------------------------------------------------------
-- snapshots inside one statement
------------------------------------------------------------------------------
-- next to a writer: RETURNING shows the new value, a STABLE function reads with
-- the statement's snapshot (old value), a VOLATILE one sees the statement's own change
call pgmb.reg('cte.snapshot_stable_vs_volatile_beside_writer', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id = :id returning id, qty)
select qty as returned, dml_qty_stable(id) as stable_sees, dml_qty_volatile(id) as volatile_sees from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.snapshot_stable_function_100_calls', '{perf,planning}', $q$
with c as (select id, dml_qty_stable(id) as q from g_dml where id between :id and :id + 99)
select count(*), sum(q) from c$q$,
    setup => '\set id random(1, :n_g_dml)');

-- every call takes a new snapshot
call pgmb.reg('cte.snapshot_volatile_function_100_calls', '{perf,planning}', $q$
with c as (select id, dml_qty_volatile(id) as q from g_dml where id between :id and :id + 99)
select count(*), sum(q) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.snapshot_subquery_100_rows', '{perf,planning}', $q$
with c as (select t.id, (select qty from g_dml where id = t.id) as q from g_dml t where t.id between :id and :id + 99)
select count(*), sum(q) from c$q$,
    setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- security barrier views read through a CTE (views from topics/plan.sql)
------------------------------------------------------------------------------
-- a leakproof comparison crosses both the CTE and the barrier: index scan
call pgmb.reg('cte.barrier_view_leakproof_filter', '{perf,planning,consistency,oltp}', $q$
with c as (select id, grp, val from v_parent_barrier)
select id, val from c where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.barrier_pk');

call pgmb.reg('cte.barrier_plain_view_same_filter', '{perf,planning,consistency,oltp}', $q$
with c as (select id, grp, val from v_parent_plain)
select id, val from c where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.barrier_pk');

-- a user function is not leakproof: it stays above the view's own condition
call pgmb.reg('cte.barrier_view_function_filter', '{perf,planning,consistency}', $q$
with c as (select id, grp, val from v_parent_barrier)
select count(*) from c where id between :id and :id + 999 and noop_plpgsql(grp) = :g$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'cte.barrier_fn');

call pgmb.reg('cte.barrier_plain_view_function_filter', '{perf,planning,consistency}', $q$
with c as (select id, grp, val from v_parent_plain)
select count(*) from c where id between :id and :id + 999 and noop_plpgsql(grp) = :g$q$,
    setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)', equiv => 'cte.barrier_fn');

call pgmb.reg('cte.barrier_view_materialized_cte', '{perf,planning,olap}', $q$
with c as materialized (select id, grp, val from v_parent_barrier)
select id, val from c where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.barrier_view_joined_in_cte', '{perf,planning,oltp}', $q$
with c as (select v.id, v.val, d.code from v_parent_barrier v join g_dim d on d.id = v.grp % :n_g_dim + 1)
select * from c where id between :id and :id + 9$q$,
    setup => '\set id random(1, :n_g_parent)');

-- writing through the barrier view from a CTE
call pgmb.reg('cte.barrier_view_update_in_cte', '{perf,planning,oltp}', $q$
with u as (update v_parent_barrier set val = val + 1 where id = :id returning id, val)
select * from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- statement_timeout against a long recursion
------------------------------------------------------------------------------
-- pgbench drops a client on any error, so the cancellation is caught in a DO
-- block: the measured time is the timeout plus the cost of unwinding.
-- The recursion is bounded as a safety net in case the timeout does not fire.
call pgmb.reg('cte.timeout_cancels_long_recursion_20ms', '{perf}', $q$
begin;
set local statement_timeout = '20ms';
do $do$
begin
    perform count(*) from (with recursive t(n) as (select 1 union all select n + 1 from t where n < 3000000) select n from t) s;
exception when query_canceled then null;
end $do$;
commit;$q$);

call pgmb.reg('cte.timeout_not_reached_short_recursion', '{perf}', $q$
begin;
set local statement_timeout = '20ms';
do $do$
begin
    perform count(*) from (with recursive t(n) as (select 1 union all select n + 1 from t where n < 1000) select n from t) s;
exception when query_canceled then null;
end $do$;
commit;$q$);

-- the same recursion without the exception block and without a timeout
call pgmb.reg('cte.timeout_none_short_recursion', '{perf,planning}', $q$
with recursive t(n) as (select 1 union all select n + 1 from t where n < 1000) select count(*) from t$q$);
