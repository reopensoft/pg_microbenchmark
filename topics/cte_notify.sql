-- Topic: cte (part 7) - CTEs and NOTIFY.
-- NOTIFY itself is a utility command and cannot appear inside WITH, so a CTE
-- sends notifications through pg_notify(). Notifications are queued at commit,
-- and committing transactions that notify are serialized on the queue.
-- Nothing listens during the benchmark: pgbench would never drain its
-- notification buffer. All of these have side effects, so they count as writes.

------------------------------------------------------------------------------
-- baselines without notification
------------------------------------------------------------------------------
call pgmb.reg('cte.notify_baseline_select', '{perf,planning,oltp}', $q$
with c as (select id, val from g_parent where id = :id)
select id::text from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_baseline_update', '{perf,planning,oltp,concurrency}', $q$
with u as (update g_parent set val = val + 1 where id = :id returning id, val)
select id::text || ':' || val::text from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- one notification per statement
------------------------------------------------------------------------------
call pgmb.reg('cte.notify_from_select', '{perf,planning,oltp,concurrency}', $q$
with c as (select id, val from g_parent where id = :id)
select pg_notify('pgmb_events', id::text) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_after_update_returning', '{perf,planning,oltp,concurrency}', $q$
with u as (update g_parent set val = val + 1 where id = :id returning id, val)
select pg_notify('pgmb_events', id::text || ':' || val::text) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_after_insert_returning', '{perf,planning,oltp,concurrency}', $q$
with ins as (insert into g_child (parent_id, seq, kind, amount, ts, note)
             values (:id, 0, 0, 1.00, now(), 'notify') returning id, parent_id)
select pg_notify('pgmb_events', format('child %s of %s', id, parent_id)) from ins$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_after_delete_returning', '{perf,planning,oltp,concurrency}', $q$
with victim as (select id from g_child where parent_id = :id and note = 'notify' limit 1),
     gone as (delete from g_child where id in (select id from victim) returning id)
select pg_notify('pgmb_events', 'deleted ' || id) from gone$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_json_payload', '{perf,planning,oltp,concurrency}', $q$
with u as (update g_parent set val = val + 1 where id = :id returning *)
select pg_notify('pgmb_events', to_jsonb(u)::text) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- many notifications from one statement
------------------------------------------------------------------------------
call pgmb.reg('cte.notify_100_distinct_payloads', '{perf,planning,concurrency}', $q$
with c as (select id from g_parent where id between :id and :id + 99)
select count(pg_notify('pgmb_events', id::text)::text) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- identical notifications within one transaction are collapsed into one
call pgmb.reg('cte.notify_100_identical_payloads', '{perf,planning,concurrency}', $q$
with c as (select id from g_parent where id between :id and :id + 99)
select count(pg_notify('pgmb_events', 'same')::text) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_1000_distinct_payloads', '{perf,planning,concurrency}', $q$
with c as (select i from generate_series(1, 1000) i)
select count(pg_notify('pgmb_events', :id::text || '/' || i)::text) from c$q$,
    kind => 'write', setup => '\set id random(1, 1000000)');

call pgmb.reg('cte.notify_100_channels', '{perf,planning,concurrency}', $q$
with c as (select i from generate_series(1, 100) i)
select count(pg_notify('pgmb_ch_' || i, :id::text)::text) from c$q$,
    kind => 'write', setup => '\set id random(1, 1000000)');

call pgmb.reg('cte.notify_large_payload', '{perf,planning,concurrency}', $q$
with c as (select id, pad from g_narrow where id = :id)
select pg_notify('pgmb_events', repeat(pad, 190)) from c$q$,
    kind => 'write', setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('cte.notify_bulk_update_per_row', '{perf,planning,concurrency}', $q$
with u as (update g_parent set val = val + 1 where id between :id and :id + 19 returning id)
select count(pg_notify('pgmb_events', id::text)::text) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_bulk_update_one_summary', '{perf,planning,concurrency}', $q$
with u as (update g_parent set val = val + 1 where id between :id and :id + 19 returning id)
select pg_notify('pgmb_events', (select string_agg(id::text, ',' order by id) from u))$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- where the pg_notify() call sits
------------------------------------------------------------------------------
-- inside the CTE body: volatile, so the CTE is never inlined
call pgmb.reg('cte.notify_inside_cte_body', '{perf,planning,oltp,concurrency}', $q$
with n as (select pg_notify('pgmb_events', id::text)::text as sent from g_parent where id = :id)
select count(*) from n$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- in a SELECT CTE nobody reads: never executed, nothing is sent
call pgmb.reg('cte.notify_unreferenced_cte_not_sent', '{perf,planning,oltp}', $q$
with n as (select pg_notify('pgmb_events', id::text)::text as sent from g_parent where id = :id)
select 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

-- read with LIMIT: the materialized CTE is filled lazily, so only some rows notify
call pgmb.reg('cte.notify_limit_cuts_notifications', '{perf,planning,concurrency}', $q$
with n as (select id, pg_notify('pgmb_events', id::text)::text as sent from g_parent where id between :id and :id + 99)
select count(*) from (select id from n limit 5) s$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_in_returning_clause', '{perf,planning,oltp,concurrency}', $q$
with u as (update g_parent set val = val + 1 where id = :id
           returning id, pg_notify('pgmb_events', id::text)::text as sent)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_only_when_changed', '{perf,planning,oltp,concurrency}', $q$
with u as (update g_parent set status = :s where id = :id and status is distinct from :s returning id)
select pg_notify('pgmb_events', id::text) from u$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_parent)\n\\set s random(0, 4)');

------------------------------------------------------------------------------
-- the NOTIFY command next to a CTE in one transaction
------------------------------------------------------------------------------
call pgmb.reg('cte.notify_command_after_cte_write', '{perf,oltp,concurrency}', $q$
begin;
with u as (update g_parent set val = val + 1 where id = :id returning id)
select count(*) from u;
notify pgmb_events, 'changed';
commit;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_command_and_function_mixed', '{perf,oltp,concurrency}', $q$
begin;
notify pgmb_events;
with u as (update g_parent set val = val + 1 where id = :id returning id)
select pg_notify('pgmb_events', id::text) from u;
notify pgmb_other, 'done';
commit;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.notify_rolled_back', '{perf,oltp}', $q$
begin;
with u as (update g_parent set val = val + 1 where id = :id returning id)
select pg_notify('pgmb_events', id::text) from u;
rollback;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- errors
------------------------------------------------------------------------------
call pgmb.reg('cte.err_notify_command_in_cte', '{errors}',
    $q$with n as (notify pgmb_events) select 1$q$, expect_error => '42601');
call pgmb.reg('cte.err_notify_payload_too_long', '{errors}',
    $q$with c as (select repeat('x', 8000) as p) select pg_notify('pgmb_events', p) from c$q$, expect_error => '22023');
call pgmb.reg('cte.err_notify_empty_channel', '{errors}',
    $q$with c as (select '' as ch) select pg_notify(ch, 'x') from c$q$, expect_error => '22023');
