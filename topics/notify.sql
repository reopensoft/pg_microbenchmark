-- Topic: notify - NOTIFY and pg_notify() outside CTEs (those are in
-- cte_notify.sql): the ways of sending, payload types, savepoints, patterns of
-- repeated notifications, triggers, limits.
--
-- Nothing listens during the benchmark, and nothing could collect what a
-- listener receives. So delivery, deduplication as seen by a listener, and
-- the order of arrival are not tested. What is tested:
--   - that every way of sending runs, and what it costs (perf);
--   - how often pg_notify() is called: notify_fn() takes a value from a
--     sequence before it notifies, notify_count() returns how many were
--     taken. Identical notifications are collapsed by the server, calls are
--     not, and a sequence is not rolled back;
--   - what the server refuses (errors).
-- The checks roll every statement back, so nothing they queue is ever sent.

call pgmb.reg_ddl('notify.create_objects', 'schema', $q$
create sequence g_notify_seq;
create function notify_fn(channel text, payload text) returns int language plpgsql as
$f$begin
    perform nextval('pgmb_data.g_notify_seq');
    perform pg_notify(channel, payload);
    return 1;
end$f$;
create function notify_count(p_sql text) returns bigint language plpgsql as
$f$declare
    v0 bigint;
begin
    v0 := nextval('pgmb_data.g_notify_seq');
    execute p_sql;
    return nextval('pgmb_data.g_notify_seq') - v0 - 1;
end$f$;
create function notify_sql_fn(payload text) returns int language sql as
$f$select pgmb_data.notify_fn('pgmb_events', payload)$f$;
-- NOTIFY takes no expressions: a computed channel or payload has to be quoted into the command
create function notify_dynamic(channel text, payload text) returns text language plpgsql as
$f$begin
    execute format('notify %I, %L', channel, payload);
    return 'sent';
end$f$;
-- one call in a block that fails, one in its handler
create function notify_in_failed_block() returns void language plpgsql as
$f$begin
    begin
        perform pgmb_data.notify_fn('pgmb_events', 'from the failed block');
        perform 1 / 0;
    exception when division_by_zero then
        perform pgmb_data.notify_fn('pgmb_events', 'from the handler');
    end;
end$f$;
-- LISTEN is registered at commit: inside the transaction the channel is not listed yet
create function notify_listen_inside_transaction() returns bigint language plpgsql as
$f$begin
    listen pgmb_probe;
    return (select count(*) from pg_listening_channels() c where c = 'pgmb_probe');
end$f$;
create function notify_trigger() returns trigger language plpgsql as
$f$begin
    perform pgmb_data.notify_fn('pgmb_events', tg_op || ' ' || tg_level || ' ' || tg_when);
    return coalesce(new, old);
end$f$;
create function notify_trigger_transition() returns trigger language plpgsql as
$f$begin
    perform pgmb_data.notify_fn('pgmb_events', 'rows: ' || (select count(*) from new_rows));
    return null;
end$f$;
-- ten rows each: no trigger, AFTER row, BEFORE row, statement level
create table g_ntf (id int primary key, v int not null);
insert into g_ntf select n, 0 from generate_series(1, 10) n;
create table g_ntf_after (id int primary key, v int not null);
insert into g_ntf_after select * from g_ntf;
create table g_ntf_before (id int primary key, v int not null);
insert into g_ntf_before select * from g_ntf;
create table g_ntf_stmt (id int primary key, v int not null);
insert into g_ntf_stmt select * from g_ntf;
create table g_ntf_transition (id int primary key, v int not null);
create trigger g_ntf_after_trg after insert or update or delete on g_ntf_after
    for each row execute function notify_trigger();
create trigger g_ntf_before_trg before insert or update or delete on g_ntf_before
    for each row execute function notify_trigger();
create trigger g_ntf_stmt_trg after insert or update or delete on g_ntf_stmt
    for each statement execute function notify_trigger();
create trigger g_ntf_stmt_truncate after truncate on g_ntf_stmt
    for each statement execute function notify_trigger();
create trigger g_ntf_transition_trg after insert on g_ntf_transition referencing new table as new_rows
    for each statement execute function notify_trigger_transition()$q$);

------------------------------------------------------------------------------
-- ways of sending
------------------------------------------------------------------------------
call pgmb.reg('notify.command_without_payload', '{perf,oltp,concurrency}', $q$notify pgmb_events$q$, kind => 'write');
call pgmb.reg('notify.command_with_payload', '{perf,oltp,concurrency}', $q$notify pgmb_events, 'changed'$q$, kind => 'write');
call pgmb.reg('notify.function_constant', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', 'changed')$q$, kind => 'write');
-- channel and payload computed
call pgmb.reg('notify.function_computed_channel_and_payload', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_ch_' || (:id % 10), 'row ' || :id)$q$,
    kind => 'write', setup => '\set id random(1, 1000000)');
call pgmb.reg('notify.dynamic_command_quoted', '{perf,oltp,concurrency}',
    $q$select notify_dynamic('pgmb_events', 'row ' || :id)$q$,
    kind => 'write', setup => '\set id random(1, 1000000)');

-- the payload as a bound parameter under each protocol
call pgmb.reg('notify.function_parameter_simple_protocol', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', (:id)::text)$q$,
    kind => 'write', setup => '\set id random(1, 1000000)', protocol => 'simple');
call pgmb.reg('notify.function_parameter_extended_protocol', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', (:id)::text)$q$,
    kind => 'write', setup => '\set id random(1, 1000000)', protocol => 'extended');
call pgmb.reg('notify.function_parameter_prepared', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', (:id)::text)$q$,
    kind => 'write', setup => '\set id random(1, 1000000)', protocol => 'prepared');

-- payloads that start as something other than text
call pgmb.reg('notify.payload_jsonb', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', jsonb_build_object('id', :id, 'tags', jsonb_build_array('a', 'b'))::text)$q$,
    kind => 'write', setup => '\set id random(1, 1000000)');
call pgmb.reg('notify.payload_json_row', '{perf,oltp,concurrency,needs_data}',
    $q$select pg_notify('pgmb_events', row_to_json(p)::text) from g_parent p where id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_parent)');
call pgmb.reg('notify.payload_integer_array', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', array[:id, :id + 1, :id + 2]::text)$q$,
    kind => 'write', setup => '\set id random(1, 1000000)');
call pgmb.reg('notify.payload_uuid', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', gen_random_uuid()::text)$q$, kind => 'write');
call pgmb.reg('notify.payload_timestamp', '{perf,oltp,concurrency}',
    $q$select pg_notify('pgmb_events', clock_timestamp()::text)$q$, kind => 'write');

------------------------------------------------------------------------------
-- transactions and savepoints
------------------------------------------------------------------------------
call pgmb.reg('notify.savepoint_released', '{perf,oltp,concurrency}', $q$
begin;
notify pgmb_events, 'before';
savepoint s;
notify pgmb_events, 'inside';
release savepoint s;
commit;$q$, kind => 'write');

-- the notification queued after the savepoint is dropped with it
call pgmb.reg('notify.savepoint_rolled_back', '{perf,oltp,concurrency}', $q$
begin;
notify pgmb_events, 'before';
savepoint s;
notify pgmb_events, 'inside';
rollback to savepoint s;
notify pgmb_events, 'after';
commit;$q$, kind => 'write');

call pgmb.reg('notify.savepoint_three_levels_middle_rolled_back', '{perf,oltp,concurrency}', $q$
begin;
savepoint a;
notify pgmb_events, 'a';
savepoint b;
notify pgmb_events, 'b';
savepoint c;
notify pgmb_events, 'c';
rollback to savepoint b;
notify pgmb_events, 'after b';
release savepoint a;
commit;$q$, kind => 'write');

-- a PL/pgSQL block with an exception handler is a subtransaction too
call pgmb.reg('notify.exception_block', '{perf,oltp,concurrency}',
    $q$select notify_in_failed_block()$q$, kind => 'write');

-- LISTEN and UNLISTEN in one transaction: never registered, so nothing is
-- ever delivered to the pgbench client
call pgmb.reg('notify.listen_unlisten_in_one_transaction', '{perf,oltp}', $q$
begin;
listen pgmb_probe;
unlisten pgmb_probe;
commit;$q$, kind => 'write');
call pgmb.reg('notify.unlisten_all', '{perf,oltp}', $q$unlisten *$q$, kind => 'write');

------------------------------------------------------------------------------
-- repeated notifications in one transaction
------------------------------------------------------------------------------
-- The server compares each new notification with those already queued in
-- the transaction.
call pgmb.reg('notify.pattern_a_a_a', '{perf,oltp,concurrency}', $q$
begin;
notify pgmb_events, 'A';
notify pgmb_events, 'A';
notify pgmb_events, 'A';
commit;$q$, kind => 'write');
call pgmb.reg('notify.pattern_a_b_a', '{perf,oltp,concurrency}', $q$
begin;
notify pgmb_events, 'A';
notify pgmb_events, 'B';
notify pgmb_events, 'A';
commit;$q$, kind => 'write');
call pgmb.reg('notify.pattern_a_b_c_a_b_c', '{perf,oltp,concurrency}', $q$
begin;
notify pgmb_events, 'A';
notify pgmb_events, 'B';
notify pgmb_events, 'C';
notify pgmb_events, 'A';
notify pgmb_events, 'B';
notify pgmb_events, 'C';
commit;$q$, kind => 'write');
-- the same payload on two channels is two notifications
call pgmb.reg('notify.pattern_same_payload_two_channels', '{perf,oltp,concurrency}', $q$
begin;
notify pgmb_events, 'A';
notify pgmb_other, 'A';
commit;$q$, kind => 'write');
-- 10,000 in one statement: all different, and all the same
call pgmb.reg('notify.many_10k_distinct', '{perf,concurrency}',
    $q$select count(pg_notify('pgmb_events', n::text)::text) from generate_series(1, 10000) n$q$, kind => 'write');
call pgmb.reg('notify.many_10k_identical', '{perf,concurrency}',
    $q$select count(pg_notify('pgmb_events', 'same')::text) from generate_series(1, 10000) n$q$, kind => 'write');

------------------------------------------------------------------------------
-- how often pg_notify() is called
------------------------------------------------------------------------------
call pgmb.reg('notify.expected_0',   '{consistency}', $q$select 0::bigint$q$,   equiv => 'notify.count_0');
call pgmb.reg('notify.expected_1',   '{consistency}', $q$select 1::bigint$q$,   equiv => 'notify.count_1');
call pgmb.reg('notify.expected_2',   '{consistency}', $q$select 2::bigint$q$,   equiv => 'notify.count_2');
call pgmb.reg('notify.expected_3',   '{consistency}', $q$select 3::bigint$q$,   equiv => 'notify.count_3');
call pgmb.reg('notify.expected_5',   '{consistency}', $q$select 5::bigint$q$,   equiv => 'notify.count_5');
call pgmb.reg('notify.expected_7',   '{consistency}', $q$select 7::bigint$q$,   equiv => 'notify.count_7');
call pgmb.reg('notify.expected_10',  '{consistency}', $q$select 10::bigint$q$,  equiv => 'notify.count_10');
call pgmb.reg('notify.expected_100', '{consistency}', $q$select 100::bigint$q$, equiv => 'notify.count_100');

-- 100 identical notifications become one, but the function ran 100 times
call pgmb.reg('notify.calls_identical_payloads', '{consistency}', $q$
select notify_count($s$select notify_fn('pgmb_events', 'same') from generate_series(1, 100)$s$)$q$,
    equiv => 'notify.count_100');

-- sources of the calls
call pgmb.reg('notify.calls_from_values', '{consistency}', $q$
select notify_count($s$select notify_fn('pgmb_events', v) from (values ('a'), ('b'), ('c')) t(v)$s$)$q$,
    equiv => 'notify.count_3');
call pgmb.reg('notify.calls_from_table', '{consistency}', $q$
select notify_count($s$select notify_fn('pgmb_events', id::text) from g_ntf$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.calls_from_scalar_subquery', '{consistency}', $q$
select notify_count($s$select (select notify_fn('pgmb_events', 'x'))$s$)$q$, equiv => 'notify.count_1');
call pgmb.reg('notify.calls_from_case_taken_branch', '{consistency}', $q$
select notify_count($s$select case when n % 2 = 0 then notify_fn('pgmb_events', n::text) end
                       from generate_series(1, 10) n$s$)$q$, equiv => 'notify.count_5');
call pgmb.reg('notify.calls_from_sql_function', '{consistency}', $q$
select notify_count($s$select notify_sql_fn(n::text) from generate_series(1, 10) n$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.calls_from_lateral', '{consistency}', $q$
select notify_count($s$select s.x from generate_series(1, 5) o(i),
                       lateral (select notify_fn('pgmb_events', o.i::text) as x) s$s$)$q$, equiv => 'notify.count_5');
-- no outer rows: the LATERAL side is never run
call pgmb.reg('notify.calls_from_lateral_no_outer_rows', '{consistency}', $q$
select notify_count($s$select s.x from generate_series(1, 0) o(i),
                       lateral (select notify_fn('pgmb_events', o.i::text) as x) s$s$)$q$, equiv => 'notify.count_0');
call pgmb.reg('notify.calls_from_returning', '{consistency}', $q$
select notify_count($s$update g_ntf set v = v + 1 where id <= 7 returning notify_fn('pgmb_events', id::text)$s$)$q$,
    equiv => 'notify.count_7');
call pgmb.reg('notify.calls_from_failed_block_and_handler', '{consistency}', $q$
select notify_count($s$select notify_in_failed_block()$s$)$q$, equiv => 'notify.count_2');

-- readers that do not need every row
call pgmb.reg('notify.calls_under_limit', '{consistency}', $q$
select notify_count($s$select notify_fn('pgmb_events', n::text) from generate_series(1, 100) n limit 5$s$)$q$,
    equiv => 'notify.count_5');
call pgmb.reg('notify.calls_under_exists', '{consistency}', $q$
select notify_count($s$select exists (select 1 from generate_series(1, 100) n
                                      where notify_fn('pgmb_events', n::text) = 1)$s$)$q$, equiv => 'notify.count_1');
call pgmb.reg('notify.calls_under_count', '{consistency}', $q$
select notify_count($s$with c as (select notify_fn('pgmb_events', n::text) as x from generate_series(1, 10) n)
                       select count(*) from c$s$)$q$, equiv => 'notify.count_10');

-- a CTE is evaluated once however many times it is read
call pgmb.reg('notify.calls_cte_two_readers', '{consistency}', $q$
select notify_count($s$with c as materialized (select notify_fn('pgmb_events', n::text) as x from generate_series(1, 10) n)
                       select (select count(x) from c), (select sum(x) from c)$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.calls_cte_diamond', '{consistency}', $q$
select notify_count($s$with a as (select n, notify_fn('pgmb_events', n::text) as x from generate_series(1, 10) n),
                            b as (select n, x from a where n <= 5),
                            c as (select n, x from a where n > 3)
                       select count(*) from b join c using (n)$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.calls_cte_unreferenced', '{consistency}', $q$
select notify_count($s$with c as (select notify_fn('pgmb_events', n::text) as x from generate_series(1, 10) n)
                       select 1$s$)$q$, equiv => 'notify.count_0');

------------------------------------------------------------------------------
-- triggers that notify
------------------------------------------------------------------------------
call pgmb.reg('notify.trigger_after_row_insert_10', '{consistency}', $q$
select notify_count($s$insert into g_ntf_after select n, 0 from generate_series(11, 20) n$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.trigger_after_row_update_10', '{consistency}',
    $q$select notify_count($s$update g_ntf_after set v = v + 1$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.trigger_after_row_delete_10', '{consistency}',
    $q$select notify_count($s$delete from g_ntf_after$s$)$q$, equiv => 'notify.count_10');
-- rows 6 to 15: five updated, five inserted
call pgmb.reg('notify.trigger_after_row_on_conflict', '{consistency}', $q$
select notify_count($s$insert into g_ntf_after select n, 0 from generate_series(6, 15) n
                       on conflict (id) do update set v = g_ntf_after.v + 1$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.trigger_after_row_merge', '{consistency}', $q$
select notify_count($s$merge into g_ntf_after t using generate_series(6, 15) s(n) on t.id = s.n
                       when matched then update set v = t.v + 1
                       when not matched then insert values (s.n, 0)$s$)$q$, equiv => 'notify.count_10');
call pgmb.reg('notify.trigger_before_row_update_10', '{consistency}',
    $q$select notify_count($s$update g_ntf_before set v = v + 1$s$)$q$, equiv => 'notify.count_10');
-- no row matches: a row trigger is not called at all
call pgmb.reg('notify.trigger_before_row_update_no_rows', '{consistency}',
    $q$select notify_count($s$update g_ntf_before set v = v + 1 where id < 0$s$)$q$, equiv => 'notify.count_0');

call pgmb.reg('notify.trigger_statement_update_10', '{consistency}',
    $q$select notify_count($s$update g_ntf_stmt set v = v + 1$s$)$q$, equiv => 'notify.count_1');
call pgmb.reg('notify.trigger_statement_update_no_rows', '{consistency}',
    $q$select notify_count($s$update g_ntf_stmt set v = v + 1 where id < 0$s$)$q$, equiv => 'notify.count_1');
call pgmb.reg('notify.trigger_statement_truncate', '{consistency}',
    $q$select notify_count($s$truncate g_ntf_stmt$s$)$q$, equiv => 'notify.count_1');
call pgmb.reg('notify.trigger_statement_on_conflict', '{consistency}', $q$
select notify_count($s$insert into g_ntf_stmt select n, 0 from generate_series(6, 15) n
                       on conflict (id) do update set v = g_ntf_stmt.v + 1$s$)$q$, equiv => 'notify.count_2');
call pgmb.reg('notify.trigger_statement_merge', '{consistency}', $q$
select notify_count($s$merge into g_ntf_stmt t using generate_series(6, 15) s(n) on t.id = s.n
                       when matched then update set v = t.v + 1
                       when not matched then insert values (s.n, 0)$s$)$q$, equiv => 'notify.count_2');
-- one notification that carries the number of rows, from the transition table
call pgmb.reg('notify.trigger_transition_table_insert_100', '{consistency}', $q$
select notify_count($s$insert into g_ntf_transition select n, 0 from generate_series(1, 100) n$s$)$q$,
    equiv => 'notify.count_1');

-- cost: ten rows updated with a notification per row, per statement, and with none
call pgmb.reg('notify.trigger_cost_none', '{perf,concurrency}',
    $q$update g_ntf set v = v + 1$q$, kind => 'write');
call pgmb.reg('notify.trigger_cost_after_row', '{perf,concurrency}',
    $q$update g_ntf_after set v = v + 1$q$, kind => 'write');
call pgmb.reg('notify.trigger_cost_before_row', '{perf,concurrency}',
    $q$update g_ntf_before set v = v + 1$q$, kind => 'write');
call pgmb.reg('notify.trigger_cost_statement', '{perf,concurrency}',
    $q$update g_ntf_stmt set v = v + 1$q$, kind => 'write');

------------------------------------------------------------------------------
-- limits and the queue
------------------------------------------------------------------------------
call pgmb.reg('notify.listen_not_registered_before_commit', '{consistency}',
    $q$select notify_listen_inside_transaction()$q$, equiv => 'notify.count_0');

-- a fraction of the queue's capacity, not a number of notifications
call pgmb.reg('notify.queue_usage_is_a_fraction', '{consistency}',
    $q$select pg_notification_queue_usage() between 0 and 1, pg_typeof(pg_notification_queue_usage())::text$q$,
    equiv => 'notify.queue_usage');
call pgmb.reg('notify.queue_usage_is_a_fraction_expected', '{consistency}',
    $q$select true, 'double precision'::text$q$, equiv => 'notify.queue_usage');
call pgmb.reg('notify.queue_usage_call', '{perf,oltp}', $q$select pg_notification_queue_usage()$q$);

-- the payload limit is 8000 bytes, the last one for the terminator
call pgmb.reg('notify.payload_7999_bytes', '{perf,concurrency}',
    $q$select pg_notify('pgmb_events', repeat('x', 7999))$q$, kind => 'write');
call pgmb.reg('notify.err_payload_8000_bytes', '{errors}',
    $q$select pg_notify('pgmb_events', repeat('x', 8000))$q$, expect_error => '22023');
call pgmb.reg('notify.err_channel_name_64_characters', '{errors}',
    $q$select pg_notify(repeat('c', 64), 'x')$q$, expect_error => '22023');
call pgmb.reg('notify.err_channel_name_empty', '{errors}',
    $q$select pg_notify('', 'x')$q$, expect_error => '22023');
select format('notify pgmb_events, %L', repeat('x', 8000)) as pgmb_notify_long \gset
call pgmb.reg('notify.err_command_payload_8000_bytes', '{errors}', :'pgmb_notify_long', expect_error => '22023');

-- the limit counts bytes: 4000 two-byte characters are too long, 3999 are not
select current_setting('server_encoding') = 'UTF8' as pgmb_notify_utf8 \gset
\if :pgmb_notify_utf8
call pgmb.reg('notify.payload_3999_two_byte_characters', '{perf,concurrency}',
    $q$select pg_notify('pgmb_events', repeat('ż', 3999))$q$, kind => 'write');
call pgmb.reg('notify.err_payload_4000_two_byte_characters', '{errors}',
    $q$select pg_notify('pgmb_events', repeat('ż', 4000))$q$, expect_error => '22023');
\endif

-- a command built without quoting breaks on the first space
call pgmb.reg('notify.err_dynamic_command_not_quoted', '{errors}',
    $q$do $do$ begin execute 'notify ' || 'two words' || ', ' || 'payload'; end $do$$q$, expect_error => '42601');
call pgmb.reg('notify.dynamic_command_odd_channel_and_payload', '{consistency}', $q$
select notify_dynamic('Mixed Case "channel"', 'it''s; drop table g_ntf; --')$q$, equiv => 'notify.dynamic');
call pgmb.reg('notify.dynamic_command_odd_channel_and_payload_expected', '{consistency}',
    $q$select 'sent'::text$q$, equiv => 'notify.dynamic');
