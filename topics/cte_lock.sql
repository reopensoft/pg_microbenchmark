-- Topic: cte (part 13) - row locks and CTEs.
-- A locking clause on the main query does not reach into a referenced CTE;
-- to lock there, the clause goes inside the CTE, which then is never inlined.
-- All of these take row locks, so they count as writes.

------------------------------------------------------------------------------
-- FOR UPDATE on the main query: the CTE's rows stay unlocked
------------------------------------------------------------------------------
call pgmb.reg('cte.lock_main_for_update_skips_cte', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id from g_parent where id = :id)
select ch.id from c join g_child ch on ch.parent_id = c.id order by ch.id limit 3 for update$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- the same join written without a CTE locks both tables
call pgmb.reg('cte.lock_main_for_update_plain_join', '{perf,planning,locking,concurrency,oltp}', $q$
select ch.id from g_parent c join g_child ch on ch.parent_id = c.id where c.id = :id order by ch.id limit 3 for update$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_main_for_update_only_cte_in_from', '{perf,planning,locking,oltp}', $q$
with c as (select id, val from g_parent where id = :id)
select * from c for update$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.err_lock_for_update_of_cte', '{errors}',
    $q$with c as (select id from g_parent where id = 1) select * from c for update of c$q$, expect_error => '0A000');

------------------------------------------------------------------------------
-- the locking clause inside the CTE, four strengths
------------------------------------------------------------------------------
call pgmb.reg('cte.lock_inside_for_update', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id, val from g_parent where id = :id for update)
select * from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_inside_for_no_key_update', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id, val from g_parent where id = :id for no key update)
select * from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_inside_for_share', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id, val from g_parent where id = :id for share)
select * from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_inside_for_key_share', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id, val from g_parent where id = :id for key share)
select * from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_inside_no_lock_baseline', '{perf,planning,oltp}', $q$
with c as materialized (select id, val from g_parent where id = :id)
select * from c$q$,
    setup => '\set id random(1, :n_g_parent)');

-- lock in the CTE, then update the same rows in the main statement
call pgmb.reg('cte.lock_inside_then_main_update', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id from g_parent where id = :id for update)
update g_parent p set val = p.val + 1 from c where p.id = c.id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- FOR SHARE and FOR UPDATE on different tables of one CTE
call pgmb.reg('cte.lock_inside_share_parent_update_child', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select p.id as pid, ch.id as cid
           from g_parent p join g_child ch on ch.parent_id = p.id
           where p.id = :id order by ch.id limit 3
           for share of p for update of ch)
select count(*) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- SKIP LOCKED and NOWAIT inside the CTE
------------------------------------------------------------------------------
-- the queue pattern: claim a few unlocked rows, then work on them
call pgmb.reg('cte.lock_skip_locked_queue_update', '{perf,planning,locking,concurrency,oltp}', $q$
with job as (select id from g_parent where grp = :g order by id limit 5 for update skip locked)
update g_parent p set val = p.val + 1 from job where p.id = job.id$q$,
    kind => 'write', setup => '\set g random(0, 99)');

call pgmb.reg('cte.lock_skip_locked_queue_returning', '{perf,planning,locking,concurrency,oltp}', $q$
with job as (select id from g_parent where grp = :g order by id limit 5 for update skip locked),
     done as (update g_parent p set updated_at = now() from job where p.id = job.id returning p.id)
select count(*) from done$q$,
    kind => 'write', setup => '\set g random(0, 99)');

call pgmb.reg('cte.lock_skip_locked_single_row', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id, val from g_parent where id = :id for update skip locked)
select count(*) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- NOWAIT fails when the row is locked, and pgbench would drop the client.
-- Every client therefore locks its own row of g_dml_defer (ids 1 .. n/2 are
-- reserved for this), so this measures NOWAIT without a conflict.
call pgmb.reg('cte.lock_nowait_own_row', '{perf,planning,locking,oltp}', $q$
with c as (select id, qty from g_dml_defer where id = :id for update nowait)
select * from c$q$,
    kind => 'write', setup => '\set id 1 + :client_id % (:n_g_dml / 2)');

call pgmb.reg('cte.lock_wait_own_row', '{perf,planning,locking,oltp}', $q$
with c as (select id, qty from g_dml_defer where id = :id for update)
select * from c$q$,
    kind => 'write', setup => '\set id 1 + :client_id % (:n_g_dml / 2)');

------------------------------------------------------------------------------
-- several readers, outer LIMIT
------------------------------------------------------------------------------
-- the rows are locked once, however many readers there are
call pgmb.reg('cte.lock_inside_three_readers', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id, val from g_parent where id between :id and :id + 4 order by id for update)
select (select count(*) from c) as n, (select sum(val) from c) as total, (select max(id) from c) as last_id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_inside_self_join', '{perf,planning,locking,concurrency}', $q$
with c as (select id, val from g_parent where id between :id and :id + 9 order by id for update)
select count(*) from c a join c b on b.id = a.id + 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- the reader stops after one row: the CTE is read lazily, so only the rows
-- actually fetched get locked
call pgmb.reg('cte.lock_inside_outer_limit_1', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id from g_parent where id between :id and :id + 49 order by id for update)
select id from c limit 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- the reader needs every row: all 50 are locked
call pgmb.reg('cte.lock_inside_outer_count_all', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id from g_parent where id between :id and :id + 49 order by id for update)
select count(*) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_inside_inner_limit_1', '{perf,planning,locking,concurrency,oltp}', $q$
with c as (select id from g_parent where id between :id and :id + 49 order by id limit 1 for update)
select id from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- an unreferenced locking CTE is never executed: nothing is locked
call pgmb.reg('cte.lock_inside_unreferenced', '{perf,planning,locking,oltp}', $q$
with c as (select id from g_parent where id between :id and :id + 49 for update)
select 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- CTE against derived table
------------------------------------------------------------------------------
call pgmb.reg('cte.lock_derived_table_for_update', '{perf,planning,locking,concurrency,oltp}', $q$
select * from (select id, val from g_parent where id = :id for update) s$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- the outer clause does reach into a derived table
call pgmb.reg('cte.lock_derived_table_main_for_update', '{perf,planning,locking,concurrency,oltp}', $q$
select * from (select id, val from g_parent where id = :id) s for update$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.lock_derived_table_outer_limit_1', '{perf,planning,locking,concurrency,oltp}', $q$
select id from (select id from g_parent where id between :id and :id + 49 order by id for update) s limit 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- the outer predicate cannot move below the row locks, in either form
call pgmb.reg('cte.lock_cte_outer_filter', '{perf,planning,locking,concurrency}', $q$
with c as (select id, grp from g_parent where id between :id and :id + 49 order by id for update)
select count(*) from c where grp = :g$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)');

call pgmb.reg('cte.lock_derived_table_outer_filter', '{perf,planning,locking,concurrency}', $q$
select count(*) from (select id, grp from g_parent where id between :id and :id + 49 order by id for update) s where grp = :g$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_parent)\n\\set g random(0, 99)');
