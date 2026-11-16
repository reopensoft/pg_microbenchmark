-- Topic: cancel (part 2) - what interrupts a statement, and what is left
-- behind: timeouts and resource limits, exceptions raised in PL/pgSQL,
-- CTEs and recursion cut short, functions and dynamic SQL, locks.
--
-- The helper functions of cancel.sql are used: cancel_now() cancels the
-- backend that runs it, cancel_if(cond) does so when cond is true.
-- Three kinds of test:
--   errors       the statement must end with the given SQLSTATE;
--   consistency  a function interrupts something, catches the error and
--                reports what it finds afterwards, next to the expected text;
--   perf         waits that only happen with several clients, cut short by a
--                timeout that is caught in a DO block. A handler catches only
--                the error that is expected: any other one ends the pgbench
--                client and shows up as a failure.
--                A statement_timeout block ends with pg_sleep(1) and the
--                timeout is switched off right after it (see cancel.sql).
--
-- Not possible here: anything that needs a second session to send the signal
-- or to hold a lock at a chosen moment, anything that ends the session
-- (pg_terminate_backend, the session timeouts, shutdown, a lost connection),
-- a full disk, a real out-of-memory, two-phase commit.

call pgmb.reg_ddl('cancel.create_cause_objects', 'schema', $q$
create sequence g_cancel_seq;
create table g_cancel_rows (id int primary key, v bigint not null);
insert into g_cancel_rows select n, 0 from generate_series(1, 10) n;
create table g_cancel_lock (id int primary key, v bigint not null);
insert into g_cancel_lock select n, 0 from generate_series(1, 10) n;
create table g_cancel_tlock (id int primary key);
create table g_cancel_ddl (id int primary key);
create table g_cancel_trg (id int primary key);
-- counts its own calls in a sequence, which no rollback takes back
create function cancel_tick(v int) returns int language plpgsql as
'begin perform nextval(''pgmb_data.g_cancel_seq''); return v; end';
-- runs a statement, swallows whatever error ends it, returns the number of cancel_tick() calls
create function cancel_calls(p_sql text) returns bigint language plpgsql as
$f$declare
    v0 bigint;
begin
    v0 := nextval('pgmb_data.g_cancel_seq');
    begin
        execute p_sql;
    exception when query_canceled or others then null;
    end;
    return nextval('pgmb_data.g_cancel_seq') - v0 - 1;
end$f$;
create function cancel_then_continue() returns text language plpgsql as
$f$begin
    begin
        perform pgmb_data.cancel_now();
    exception when query_canceled then null;
    end;
    return 'still running: ' || (select count(*) from generate_series(1, 10));
end$f$;
create function cancel_recurse(n int) returns int language plpgsql as
'begin return pgmb_data.cancel_recurse(n + 1); end';
create function fail_custom() returns int language plpgsql as
$f$begin raise exception 'pgmb custom error' using errcode = 'P0077'; end$f$;
create function fail_level_3() returns int language plpgsql as 'begin return pgmb_data.fail_custom(); end';
create function fail_level_2() returns int language plpgsql as 'begin return pgmb_data.fail_level_3(); end';
create function fail_level_1() returns int language plpgsql as 'begin return pgmb_data.fail_level_2(); end';
create function fail_from_sql_function() returns int language sql as 'select pgmb_data.fail_custom()';
create function fail_condition_name() returns int language plpgsql as
$f$begin raise unique_violation using message = 'raised by name'; end$f$;
create function fail_in_loop(n int) returns int language plpgsql as
$f$begin
    for i in 1 .. n loop
        if i = 50 then raise exception 'iteration %', i using errcode = 'P0078'; end if;
    end loop;
    return n;
end$f$;
create function fail_before_write() returns int language plpgsql as
$f$begin
    raise exception 'before the write' using errcode = 'P0079';
    update pgmb_data.g_cancel_rows set v = v + 1;
    return 1;
end$f$;
create function fail_after_write() returns int language plpgsql as
$f$begin
    update pgmb_data.g_cancel_rows set v = v + 1;
    raise exception 'after the write' using errcode = 'P0080';
end$f$;
create procedure fail_procedure() language plpgsql as
$f$begin raise exception 'in a procedure' using errcode = 'P0081'; end$f$;
create function fail_trigger() returns trigger language plpgsql as
$f$begin raise exception 'in a trigger' using errcode = 'P0082'; end$f$;
create trigger g_cancel_trg_fail before insert on g_cancel_trg for each row execute function fail_trigger();
create function fail_reraise_same() returns int language plpgsql as
$f$begin
    return 1 / 0;
exception when division_by_zero then
    raise;
end$f$;
create function fail_reraise_other() returns int language plpgsql as
$f$begin
    return 1 / 0;
exception when division_by_zero then
    raise exception 'translated: %', sqlerrm using errcode = 'P0083';
end$f$;
-- a write, then an exception: caught, the write is undone, the function goes on
create function cancel_handler_facts() returns text language plpgsql as
$f$declare
    caught text;
begin
    begin
        update pgmb_data.g_cancel_rows set v = v + 1;
        perform pgmb_data.fail_custom();
    exception when sqlstate 'P0077' then
        caught := sqlstate;
    end;
    update pgmb_data.g_cancel_rows set v = v + 10 where id = 1;
    return format('caught %s, write undone: %s, went on: %s', caught,
                  (select sum(v) from pgmb_data.g_cancel_rows where id > 1) = 0,
                  (select v from pgmb_data.g_cancel_rows where id = 1) = 10);
end$f$;
-- two nested blocks: the inner one is cancelled first, then the outer one
create function cancel_nested_block_facts() returns text language plpgsql as
$f$declare
    r text;
begin
    begin
        insert into pgmb_data.g_cancel_rows values (-1, 0);
        begin
            insert into pgmb_data.g_cancel_rows values (-2, 0);
            perform pgmb_data.cancel_now();
        exception when query_canceled then null;
        end;
        r := 'after the inner cancel: ' || (select string_agg(id::text, ',' order by id desc)
                                            from pgmb_data.g_cancel_rows where id < 0);
        insert into pgmb_data.g_cancel_rows values (-3, 0);
        perform pgmb_data.cancel_now();
    exception when query_canceled then null;
    end;
    return r || ', after the outer cancel: ' || (select count(*) from pgmb_data.g_cancel_rows where id < 0);
end$f$;
-- an update cancelled on its fifth row
create function cancel_update_facts() returns text language plpgsql as
$f$begin
    begin
        update pgmb_data.g_cancel_rows set v = v + pgmb_data.cancel_if(id = 5);
    exception when query_canceled then null;
    end;
    update pgmb_data.g_cancel_rows set v = v + 1;
    return format('rows: %s, after the cancelled update and one more: %s',
                  (select count(*) from pgmb_data.g_cancel_rows), (select sum(v) from pgmb_data.g_cancel_rows));
end$f$;
-- a writer in a CTE is cancelled by the reader of its RETURNING rows
create function cancel_writer_facts() returns text language plpgsql as
$f$begin
    begin
        execute 'with u as (update pgmb_data.g_cancel_rows set v = v + 1 returning id) '
                'select pgmb_data.cancel_if(id = 5) from u';
    exception when query_canceled then null;
    end;
    return format('writes undone: %s', (select sum(v) from pgmb_data.g_cancel_rows) = 0);
end$f$;
-- a value taken from a sequence inside a cancelled block is gone
create function cancel_sequence_facts() returns bigint language plpgsql as
$f$declare
    a bigint; b bigint;
begin
    a := nextval('pgmb_data.g_cancel_seq');
    begin
        perform nextval('pgmb_data.g_cancel_seq');
        perform pgmb_data.cancel_now();
    exception when query_canceled then null;
    end;
    b := nextval('pgmb_data.g_cancel_seq');
    return b - a;
end$f$;
-- the same statement of a function, cancelled twice, then left alone
create function cancel_statement_reused() returns text language plpgsql as
$f$declare
    cancelled int := 0;
    n bigint;
begin
    for pass in 1 .. 3 loop
        begin
            select count(pgmb_data.cancel_if(g = 5 and pass < 3)) into n from generate_series(1, 10) g;
        exception when query_canceled then
            cancelled := cancelled + 1;
        end;
    end loop;
    return format('cancelled %s times, third run counted %s', cancelled, n);
end$f$;
-- dynamic SQL inside dynamic SQL: the cancel has to unwind every level
create function cancel_dynamic(depth int) returns int language plpgsql as
$f$begin
    if depth = 0 then
        execute 'select pgmb_data.cancel_now()';
    else
        execute format('select pgmb_data.cancel_dynamic(%s)', depth - 1);
    end if;
    return depth;
end$f$;
-- a set-returning function that cancels while it builds its result
create function cancel_srf(n int, at int) returns setof int language plpgsql as
$f$begin
    for i in 1 .. n loop
        if i = at then perform pgmb_data.cancel_now(); end if;
        return next i;
    end loop;
end$f$;
-- Locks around a cancelled block: one taken before it, one inside it, and a
-- session level lock inside it. The session lock is released by hand at the end.
create function cancel_lock_facts() returns text language plpgsql as
$f$declare
    r text;
begin
    perform pg_advisory_xact_lock(7291010);
    begin
        perform pg_advisory_xact_lock(7291011);
        perform pg_advisory_lock(7291012);
        perform pgmb_data.cancel_now();
    exception when query_canceled then null;
    end;
    select format('taken before the block: %s, inside the block: %s, session level inside the block: %s',
                  count(*) filter (where objid = 7291010), count(*) filter (where objid = 7291011),
                  count(*) filter (where objid = 7291012)) into r
    from pg_locks
    where locktype = 'advisory' and pid = pg_backend_pid() and granted and classid = 0
      and objid in (7291010, 7291011, 7291012);
    perform pg_advisory_unlock(7291012);
    return r;
end$f$$q$);

call pgmb.reg('cancel.expected_0',   '{consistency}', $q$select 0::bigint$q$,   equiv => 'cancel.count_0');
call pgmb.reg('cancel.expected_2',   '{consistency}', $q$select 2::bigint$q$,   equiv => 'cancel.count_2');
call pgmb.reg('cancel.expected_50',  '{consistency}', $q$select 50::bigint$q$,  equiv => 'cancel.count_50');
call pgmb.reg('cancel.expected_100', '{consistency}', $q$select 100::bigint$q$, equiv => 'cancel.count_100');

------------------------------------------------------------------------------
-- 9.1 a cancel request, and the session after it
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_cancel_request_top_level', '{errors}',
    $q$select cancel_now()$q$, expect_error => '57014');
call pgmb.reg('cancel.session_usable_after_cancel', '{consistency}',
    $q$select cancel_then_continue()$q$, equiv => 'cancel.usable');
call pgmb.reg('cancel.session_usable_after_cancel_expected', '{consistency}',
    $q$select 'still running: 10'::text$q$, equiv => 'cancel.usable');

------------------------------------------------------------------------------
-- 9.1 statement_timeout under each protocol
------------------------------------------------------------------------------
-- the timer starts with the statement that is being executed
call pgmb.reg('cancel.timeout_100ms_sleep_simple_protocol', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
commit;$q$, protocol => 'simple');
call pgmb.reg('cancel.timeout_100ms_sleep_extended_protocol', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
commit;$q$, protocol => 'extended');
call pgmb.reg('cancel.timeout_100ms_sleep_prepared', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
commit;$q$, protocol => 'prepared');
-- five statements of 10 ms each: none of them reaches the limit of 100 ms
call pgmb.reg('cancel.timeout_100ms_five_short_statements', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
select pg_sleep(0.01);
select pg_sleep(0.01);
select pg_sleep(0.01);
select pg_sleep(0.01);
select pg_sleep(0.01);
commit;$q$);

------------------------------------------------------------------------------
-- 9.1 lock_timeout and NOWAIT (several clients)
------------------------------------------------------------------------------
-- Whoever gets the lock keeps it for 150 ms; the others give up after 20 ms
-- with lock_not_available. With one client nobody waits.
call pgmb.reg('cancel.lock_timeout_20ms_advisory_lock', '{perf,locking,concurrency}', $q$
begin;
set local lock_timeout = '20ms';
do $do$ begin perform pg_advisory_xact_lock(7291002); exception when lock_not_available then null; end $do$;
set local lock_timeout = 0;
select pg_sleep(0.15);
commit;$q$);
call pgmb.reg('cancel.lock_timeout_20ms_row_lock', '{perf,locking,concurrency}', $q$
begin;
set local lock_timeout = '20ms';
do $do$ begin perform 1 from g_cancel_lock where id = 4 for update; exception when lock_not_available then null; end $do$;
set local lock_timeout = 0;
select pg_sleep(0.15);
commit;$q$, kind => 'write');
-- NOWAIT gives the same error at once
call pgmb.reg('cancel.nowait_row_lock', '{perf,locking,concurrency}', $q$
begin;
do $do$ begin perform 1 from g_cancel_lock where id = 5 for update nowait; exception when lock_not_available then null; end $do$;
select pg_sleep(0.15);
commit;$q$, kind => 'write');

------------------------------------------------------------------------------
-- 9.1 temp_file_limit (the setting needs a superuser)
------------------------------------------------------------------------------
-- A million rows from a join of two short series, so that the input itself
-- needs no temporary file; 64 kB of work_mem and a limit of 1 MB.
select rolsuper as pgmb_cancel_super from pg_roles where rolname = current_user \gset
\if :pgmb_cancel_super
\set pgmb_cancel_tfl 'begin;\nset local work_mem = ''64kB'';\nset local temp_file_limit = ''1MB'';\n'
call pgmb.reg('cancel.err_temp_file_limit_sort', '{errors}', :'pgmb_cancel_tfl' || $q$
select count(*) from (select a * 1000 + b as x from generate_series(1, 1000) a, generate_series(1, 1000) b
                      order by 1 desc offset 0) s;
commit;$q$, expect_error => '53400');
call pgmb.reg('cancel.err_temp_file_limit_hash_aggregate', '{errors}', :'pgmb_cancel_tfl' || $q$
set local enable_sort = off;
select count(*) from (select a * 1000 + b as x, count(*) as c from generate_series(1, 1000) a, generate_series(1, 1000) b
                      group by 1 offset 0) s;
commit;$q$, expect_error => '53400');
call pgmb.reg('cancel.err_temp_file_limit_hash_join', '{errors}', :'pgmb_cancel_tfl' || $q$
set local enable_mergejoin = off;
set local enable_nestloop = off;
select count(*)
from (select a * 1000 + b as x from generate_series(1, 1000) a, generate_series(1, 1000) b offset 0) l
     join (select a * 1000 + b as x from generate_series(1, 1000) a, generate_series(1, 1000) b offset 0) r using (x);
commit;$q$, expect_error => '53400');
call pgmb.reg('cancel.err_temp_file_limit_materialized_cte', '{errors}', :'pgmb_cancel_tfl' || $q$
with c as materialized (select a * 1000 + b as x, repeat('x', 50) as pad
                        from generate_series(1, 1000) a, generate_series(1, 1000) b)
select count(*) from c;
commit;$q$, expect_error => '53400');
call pgmb.reg('cancel.err_temp_file_limit_recursive_cte', '{errors}', :'pgmb_cancel_tfl' || $q$
with recursive r(n, pad) as (select 1, repeat('x', 50) union all select n + 1, pad from r where n < 1000000)
select count(*) from r;
commit;$q$, expect_error => '53400');
\endif

------------------------------------------------------------------------------
-- 9.1 limits of the server itself
------------------------------------------------------------------------------
-- a function that calls itself without end runs into max_stack_depth
call pgmb.reg('cancel.err_stack_depth_endless_recursion', '{errors}',
    $q$select cancel_recurse(1)$q$, expect_error => '54001');
-- values that could never be allocated are refused before any memory is taken
call pgmb.reg('cancel.err_array_larger_than_allowed', '{errors}',
    $q$select array_fill(0, array[200000000])$q$, expect_error => '54000');
call pgmb.reg('cancel.err_string_larger_than_allowed', '{errors}',
    $q$select repeat('x', 1073741824)$q$, expect_error => '54000');

------------------------------------------------------------------------------
-- 9.1, 9.6 RAISE EXCEPTION: where it is raised and what reaches the caller
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_raise_custom_sqlstate', '{errors}',
    $q$select fail_custom()$q$, expect_error => 'P0077');
call pgmb.reg('cancel.err_raise_three_functions_deep', '{errors}',
    $q$select fail_level_1()$q$, expect_error => 'P0077');
call pgmb.reg('cancel.err_raise_through_sql_function', '{errors}',
    $q$select fail_from_sql_function()$q$, expect_error => 'P0077');
call pgmb.reg('cancel.err_raise_by_condition_name', '{errors}',
    $q$select fail_condition_name()$q$, expect_error => '23505');
call pgmb.reg('cancel.err_raise_in_do_block', '{errors}',
    $q$do $do$ begin raise exception 'in a DO block' using errcode = 'P0084'; end $do$$q$, expect_error => 'P0084');
call pgmb.reg('cancel.err_raise_in_loop', '{errors}',
    $q$select fail_in_loop(100)$q$, expect_error => 'P0078');
call pgmb.reg('cancel.err_raise_before_write', '{errors}',
    $q$select fail_before_write()$q$, expect_error => 'P0079');
call pgmb.reg('cancel.err_raise_after_write', '{errors}',
    $q$select fail_after_write()$q$, expect_error => 'P0080');
call pgmb.reg('cancel.err_raise_in_procedure', '{errors}',
    $q$call fail_procedure()$q$, expect_error => 'P0081');
call pgmb.reg('cancel.err_raise_in_trigger', '{errors}',
    $q$insert into g_cancel_trg values (1)$q$, expect_error => 'P0082');
call pgmb.reg('cancel.err_raise_in_trigger_from_cte', '{errors}',
    $q$with i as (insert into g_cancel_trg values (1) returning id) select 1$q$, expect_error => 'P0082');
call pgmb.reg('cancel.err_raise_for_one_row_of_many', '{errors}',
    $q$select case when n = 50 then fail_custom() else n end from generate_series(1, 100) n$q$, expect_error => 'P0077');

-- a handler that raises again: the same error, or one of its own
call pgmb.reg('cancel.err_handler_reraises_same_error', '{errors}',
    $q$select fail_reraise_same()$q$, expect_error => '22012');
call pgmb.reg('cancel.err_handler_raises_other_error', '{errors}',
    $q$select fail_reraise_other()$q$, expect_error => 'P0083');

call pgmb.reg('cancel.handler_undoes_block_and_continues', '{consistency}',
    $q$select cancel_handler_facts()$q$, equiv => 'cancel.handler');
call pgmb.reg('cancel.handler_undoes_block_and_continues_expected', '{consistency}',
    $q$select 'caught P0077, write undone: t, went on: t'::text$q$, equiv => 'cancel.handler');

-- 9.6 nested subtransactions
call pgmb.reg('cancel.nested_blocks_inner_then_outer', '{consistency}',
    $q$select cancel_nested_block_facts()$q$, equiv => 'cancel.nested_blocks');
call pgmb.reg('cancel.nested_blocks_inner_then_outer_expected', '{consistency}',
    $q$select 'after the inner cancel: -1, after the outer cancel: 0'::text$q$, equiv => 'cancel.nested_blocks');

------------------------------------------------------------------------------
-- 9.3 CTEs: which part is cancelled
------------------------------------------------------------------------------
-- a chain of three: the cancel in the first, in the middle and in the reader
call pgmb.reg('cancel.err_cte_chain_cancel_in_root', '{errors}', $q$
with a as (select n, cancel_if(n = 50) as x from generate_series(1, 100) n),
     b as (select n from a where n > 0),
     c as (select n from b where n < 1000)
select count(*) from c$q$, expect_error => '57014');
call pgmb.reg('cancel.err_cte_chain_cancel_in_middle', '{errors}', $q$
with a as (select n from generate_series(1, 100) n),
     b as (select n, cancel_if(n = 50) as x from a),
     c as (select n from b where n < 1000)
select count(*) from c$q$, expect_error => '57014');
call pgmb.reg('cancel.err_cte_chain_cancel_in_reader', '{errors}', $q$
with a as (select n from generate_series(1, 100) n),
     b as (select n from a where n > 0),
     c as (select n from b where n < 1000)
select count(cancel_if(n = 50)) from c$q$, expect_error => '57014');

-- a diamond: one branch has read the shared CTE to the end, the other is cancelled
call pgmb.reg('cancel.err_cte_diamond_second_branch', '{errors}', $q$
with a as materialized (select n from generate_series(1, 100) n),
     b as (select count(*) as c from a),
     c as (select count(cancel_if(n = 50)) as c from a)
select b.c, c.c from b, c$q$, expect_error => '57014');
-- three readers of one store, the third is cancelled
call pgmb.reg('cancel.err_cte_three_readers_third_cancelled', '{errors}', $q$
with c as materialized (select n from generate_series(1, 100) n)
select (select count(*) from c), (select max(n) from c), (select count(cancel_if(n = 50)) from c)$q$,
    expect_error => '57014');

-- MATERIALIZED: while the store is filled, and while it is scanned again and again
call pgmb.reg('cancel.err_cte_materialized_while_filling', '{errors}', $q$
with c as materialized (select n, cancel_if(n = 50000) as x from generate_series(1, 100000) n)
select count(*) from c$q$, expect_error => '57014');
call pgmb.reg('cancel.err_cte_materialized_while_rescanning', '{errors}', $q$
with c as materialized (select n from generate_series(1, 100) n)
select count(*) from generate_series(1, 10) o, c where cancel_if(o = 5 and c.n = 50) = 1$q$, expect_error => '57014');

-- NOT MATERIALIZED: two copies of the body, the second one is cancelled
call pgmb.reg('cancel.err_cte_not_materialized_second_copy', '{errors}', $q$
with c as not materialized (select n from generate_series(1, 100) n)
select (select count(*) from c where n < 0), (select count(cancel_if(n = 50)) from c)$q$, expect_error => '57014');

-- a store that is only partly filled when the cancel arrives
call pgmb.reg('cancel.err_cte_partial_under_limit', '{errors}', $q$
with c as materialized (select n from generate_series(1, 100000) n)
select cancel_if(n = 5) from c limit 10$q$, expect_error => '57014');
call pgmb.reg('cancel.err_cte_partial_under_exists', '{errors}', $q$
with c as materialized (select n from generate_series(1, 100000) n)
select exists (select 1 from c where cancel_if(n = 5) = 0)$q$, expect_error => '57014');
call pgmb.reg('cancel.err_cte_partial_correlated_subquery', '{errors}', $q$
with c as materialized (select n from generate_series(1, 100000) n)
select (select cancel_if(o = 5) from c where c.n = o) from generate_series(1, 10) o$q$, expect_error => '57014');

-- a CTE nobody reads is not started before the cancel either
call pgmb.reg('cancel.cte_unread_not_run_before_cancel', '{consistency}', $q$
select cancel_calls($s$with dead as (select cancel_tick(n::int) from generate_series(1, 100) n)
                       select cancel_if(n = 50) from generate_series(1, 100) n$s$)$q$, equiv => 'cancel.count_0');
-- a volatile function in a CTE that is read lazily: it ran for the rows that
-- were fetched, and those calls are not taken back
call pgmb.reg('cancel.cte_volatile_calls_before_cancel_lazy', '{consistency}', $q$
select cancel_calls($s$with c as (select cancel_tick(n::int) as n from generate_series(1, 100) n)
                       select cancel_if(n = 50) from c$s$)$q$, equiv => 'cancel.count_50');
-- read to the end first, then cancelled by a second reader: it ran for every row
call pgmb.reg('cancel.cte_volatile_calls_before_cancel_second_reader', '{consistency}', $q$
select cancel_calls($s$with c as (select cancel_tick(n::int) as n from generate_series(1, 100) n)
                       select (select count(*) from c), (select count(cancel_if(n = 50)) from c)$s$)$q$,
    equiv => 'cancel.count_100');

call pgmb.reg('cancel.cte_writer_undone_when_reader_cancels', '{consistency}',
    $q$select cancel_writer_facts()$q$, equiv => 'cancel.writer');
call pgmb.reg('cancel.cte_writer_undone_when_reader_cancels_expected', '{consistency}',
    $q$select 'writes undone: t'::text$q$, equiv => 'cancel.writer');

------------------------------------------------------------------------------
-- 9.3 recursion
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_recursive_cancel_in_anchor', '{errors}', $q$
with recursive r(n) as (select cancel_now() union all select n + 1 from r where n < 10)
select count(*) from r$q$, expect_error => '57014');
call pgmb.reg('cancel.err_recursive_cancel_in_recursive_term', '{errors}', $q$
with recursive r(n) as (select 1 union all select n + 1 from r where n < 1000 and cancel_if(n = 500) = 1)
select count(*) from r$q$, expect_error => '57014');
-- UNION keeps a hash table of every row seen so far
call pgmb.reg('cancel.err_recursive_union_dedup', '{errors}', $q$
with recursive r(n) as (select 1 union select n + 1 from r where n < 1000 and cancel_if(n = 500) = 1)
select count(*) from r$q$, expect_error => '57014');
-- the working table is joined to a table in the recursive term
call pgmb.reg('cancel.err_recursive_join_in_recursive_term', '{errors,needs_data}', $q$
with recursive w(id, depth) as (
    select id, 0 from g_tree where id = 1
    union all
    select t.id, w.depth + 1 from g_tree t join w on t.parent_id = w.id where cancel_if(w.depth = 2) = 1)
select count(*) from w$q$, expect_error => '57014');
call pgmb.reg('cancel.err_recursive_search_and_cycle', '{errors}', $q$
with recursive r(n) as (select 1 union all select n + 1 from r where n < 1000 and cancel_if(n = 500) = 1)
    search depth first by n set ord
    cycle n set is_cycle using cycle_path
select count(*) from r$q$, expect_error => '57014');
-- a path that is 500 elements long when the cancel arrives
call pgmb.reg('cancel.err_recursive_growing_array', '{errors}', $q$
with recursive r(n, path) as (
    select 1, array[1]
    union all
    select n + 1, path || (n + cancel_if(n = 500)) from r where n < 1000)
select count(*), max(cardinality(path)) from r$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- 9.3 stores, sorts and hash tables in temporary files
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_cte_spilled_store_second_reader', '{errors}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select n, repeat('x', 100) as pad from generate_series(1, 100000) n)
select (select count(*) from c), (select count(cancel_if(n = 90000)) from c);
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_cte_spilled_sort_inside', '{errors}', $q$
begin;
set local work_mem = '64kB';
with c as materialized (select n, repeat('x', 100) as pad from generate_series(1, 100000) n order by n desc)
select count(cancel_if(n = 10000)) from c;
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_cte_spilled_hash_aggregate_inside', '{errors}', $q$
begin;
set local work_mem = '64kB';
set local enable_sort = off;
with c as materialized (select n % 50000 as k, count(*) as cnt from generate_series(1, 100000) n group by 1)
select count(cancel_if(k = 25000)) from c;
commit;$q$, expect_error => '57014');

-- after a cancelled statement that had temporary files, this backend has none left
select has_function_privilege(current_user, 'pg_ls_tmpdir()', 'execute') as pgmb_cancel_tmpdir \gset
\if :pgmb_cancel_tmpdir
call pgmb.reg_ddl('cancel.create_temp_file_function', 'schema', $q$
create function cancel_temp_files_left() returns bigint language plpgsql as
$f$begin
    perform set_config('work_mem', '64kB', true);
    begin
        execute 'with c as materialized (select n, repeat(''x'', 100) as pad from generate_series(1, 100000) n) '
                'select (select count(*) from c), (select count(pgmb_data.cancel_if(n = 90000)) from c)';
    exception when query_canceled then null;
    end;
    return (select count(*) from pg_ls_tmpdir() where name like 'pgsql_tmp' || pg_backend_pid() || '.%');
end$f$$q$);
call pgmb.reg('cancel.temp_files_removed_after_cancel', '{consistency}',
    $q$select cancel_temp_files_left()$q$, equiv => 'cancel.count_0');
\endif

------------------------------------------------------------------------------
-- 9.6 functions: set-returning, dynamic SQL, reuse after a cancel
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_srf_in_from', '{errors}',
    $q$select count(*) from cancel_srf(100, 50)$q$, expect_error => '57014');
call pgmb.reg('cancel.err_srf_in_select_list', '{errors}',
    $q$select cancel_srf(100, 50)$q$, expect_error => '57014');
-- called again for every outer row: cancelled in the third call
call pgmb.reg('cancel.err_srf_lateral_third_call', '{errors}', $q$
select count(*) from generate_series(1, 5) o, lateral cancel_srf(10, case when o = 3 then 5 else 0 end) s$q$,
    expect_error => '57014');
-- a built-in set-returning function in the select list streams its rows
call pgmb.reg('cancel.err_srf_builtin_select_list', '{errors}',
    $q$select cancel_if(g = 50) from (select generate_series(1, 100) as g) s$q$, expect_error => '57014');

call pgmb.reg('cancel.err_dynamic_sql_four_levels', '{errors}',
    $q$select cancel_dynamic(3)$q$, expect_error => '57014');
call pgmb.reg('cancel.statement_reused_after_cancel', '{consistency}',
    $q$select cancel_statement_reused()$q$, equiv => 'cancel.reused');
call pgmb.reg('cancel.statement_reused_after_cancel_expected', '{consistency}',
    $q$select 'cancelled 2 times, third run counted 10'::text$q$, equiv => 'cancel.reused');

-- 9.6 sequences
call pgmb.reg('cancel.sequence_value_lost_in_cancelled_block', '{consistency}',
    $q$select cancel_sequence_facts()$q$, equiv => 'cancel.count_2');

-- 9.6 bad input to regular expressions
call pgmb.reg('cancel.err_regex_invalid', '{errors}',
    $q$select 'abc' ~ '(unclosed'$q$, expect_error => '2201B');
call pgmb.reg('cancel.err_regex_invalid_in_cte', '{errors}',
    $q$with c as (select n::text as t from generate_series(1, 10) n) select count(*) from c where t ~ '[z-a]'$q$,
    expect_error => '2201B');

------------------------------------------------------------------------------
-- 9.6 how soon expensive work notices a timeout
------------------------------------------------------------------------------
-- a PL/pgSQL loop checks at every statement
call pgmb.reg('cancel.timeout_100ms_plpgsql_empty_loop', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        for i in 1 .. 20000000 loop null; end loop;
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
commit;$q$);
-- one call that hashes 64 MB: nothing inside it looks for a cancel
call pgmb.reg('cancel.timeout_100ms_single_long_call', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform md5(repeat('x', 64000000));
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
commit;$q$);
call pgmb.reg('cancel.timeout_none_single_long_call', '{perf}', $q$
do $do$
begin
    perform md5(repeat('x', 64000000));
end $do$;$q$);
call pgmb.reg('cancel.timeout_100ms_regex_over_many_rows', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform count(*) from generate_series(1, 2000000) n where repeat('ab', 20) || n ~ '^(a|b)*[0-9]+7$';
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
commit;$q$);
call pgmb.reg('cancel.timeout_100ms_jsonb_aggregate', '{perf}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform jsonb_agg(jsonb_build_object('n', n, 't', md5(n::text))) from generate_series(1, 500000) n;
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
commit;$q$);

------------------------------------------------------------------------------
-- 9.7 locks around a cancelled block
------------------------------------------------------------------------------
call pgmb.reg('cancel.locks_after_cancelled_block', '{consistency}',
    $q$select cancel_lock_facts()$q$, equiv => 'cancel.locks');
call pgmb.reg('cancel.locks_after_cancelled_block_expected', '{consistency}', $q$
select 'taken before the block: 1, inside the block: 0, session level inside the block: 1'::text$q$,
    equiv => 'cancel.locks');

call pgmb.reg('cancel.update_cancelled_halfway_leaves_rows', '{consistency}',
    $q$select cancel_update_facts()$q$, equiv => 'cancel.update');
call pgmb.reg('cancel.update_cancelled_halfway_leaves_rows_expected', '{consistency}',
    $q$select 'rows: 10, after the cancelled update and one more: 10'::text$q$, equiv => 'cancel.update');

------------------------------------------------------------------------------
-- 9.7 a timeout while waiting for a lock (several clients)
------------------------------------------------------------------------------
-- The pattern of cancel.timeout_100ms_waiting_for_lock: the client that gets
-- the lock keeps it for 150 ms, the others are cancelled in the queue.
call pgmb.reg('cancel.timeout_100ms_waiting_for_row_update', '{perf,locking,concurrency}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        update g_cancel_lock set v = v + 1 where id = 1; perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
select pg_sleep(0.15);
commit;$q$, kind => 'write');
call pgmb.reg('cancel.timeout_100ms_waiting_for_row_delete', '{perf,locking,concurrency}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        with d as (delete from g_cancel_lock where id = 2 returning id, v)
        insert into g_cancel_lock select id, v + 1 from d;
        perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
select pg_sleep(0.15);
commit;$q$, kind => 'write');
call pgmb.reg('cancel.timeout_100ms_waiting_for_select_for_update', '{perf,locking,concurrency}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform 1 from g_cancel_lock where id = 3 for update; perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
select pg_sleep(0.15);
commit;$q$, kind => 'write');
call pgmb.reg('cancel.timeout_100ms_waiting_for_table_lock', '{perf,locking,concurrency}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        lock table g_cancel_tlock in access exclusive mode; perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
select pg_sleep(0.15);
commit;$q$, kind => 'write');
-- ALTER TABLE takes a lock that conflicts with itself
call pgmb.reg('cancel.timeout_100ms_waiting_for_ddl_lock', '{perf,locking,concurrency}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        alter table g_cancel_ddl set (fillfactor = 90); perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
select pg_sleep(0.15);
commit;$q$, kind => 'write');

-- Two timeouts at once: the shorter one decides which error the waiter gets.
-- Each handler catches only that error.
call pgmb.reg('cancel.lock_timeout_before_statement_timeout', '{perf,locking,concurrency}', $q$
begin;
set local lock_timeout = '10ms';
set local statement_timeout = '1s';
do $do$ begin perform pg_advisory_xact_lock(7291003); exception when lock_not_available then null; end $do$;
set local lock_timeout = 0;
select pg_sleep(0.15);
commit;$q$);
call pgmb.reg('cancel.statement_timeout_before_lock_timeout', '{perf,locking,concurrency}', $q$
begin;
set local lock_timeout = '1s';
set local statement_timeout = '100ms';
do $do$
begin
    begin
        perform pg_advisory_xact_lock(7291004); perform pg_sleep(1);
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
set local lock_timeout = 0;
select pg_sleep(0.15);
commit;$q$);

------------------------------------------------------------------------------
-- 9.3, 9.6 intarray: errors of the extension in every part of a statement
------------------------------------------------------------------------------
\if :pgmb_has_intarray
call pgmb.reg_ddl('cancel.create_intarray_functions', 'schema', pgmb.ia($q$
-- 100 failures of an extension function in a row, then a call that works
create function cancel_intarray_after_errors() returns text language plpgsql as
$f$declare
    failed int := 0;
begin
    for i in 1 .. 100 loop
        begin
            perform pgmb_intarray.sort(array[i, null]);
        exception when others then
            failed := failed + 1;
        end;
    end loop;
    return failed || ' ' || pgmb_intarray.sort(array[3, 1, 2])::text;
end$f$$q$));

call pgmb.reg('cancel.intarray_works_after_100_errors', '{consistency}',
    $q$select cancel_intarray_after_errors()$q$, equiv => 'cancel.intarray_after_errors');
call pgmb.reg('cancel.intarray_works_after_100_errors_expected', '{consistency}',
    $q$select '100 {1,2,3}'::text$q$, equiv => 'cancel.intarray_after_errors');

-- a NULL element reaches the extension in a filter, a join condition, a sort
-- key and an aggregate (an index build accepts it)
call pgmb.reg('cancel.err_intarray_null_in_filter', '{errors,needs_data}', pgmb.ia($q$
select count(*) from g_intarr where id <= 100 and arr_nulls operator(pgmb_intarray.@>) array[1]$q$), expect_error => '22004');
call pgmb.reg('cancel.err_intarray_null_in_join_condition', '{errors,needs_data}', pgmb.ia($q$
select count(*) from g_intarr a join g_intarr b on a.arr_nulls operator(pgmb_intarray.&&) b.arr5
where a.id <= 100 and b.id <= 10$q$), expect_error => '22004');
call pgmb.reg('cancel.err_intarray_null_in_sort_key', '{errors,needs_data}', pgmb.ia($q$
select id from g_intarr where id <= 100 order by pgmb_intarray.sort(arr_nulls)$q$), expect_error => '22004');
call pgmb.reg('cancel.err_intarray_null_in_aggregate', '{errors,needs_data}', pgmb.ia($q$
select max(pgmb_intarray.icount(pgmb_intarray.uniq(pgmb_intarray.sort(arr_nulls)))) from g_intarr where id <= 100$q$),
    expect_error => '22004');

-- recursion with a growing array that the extension sorts at every step
call pgmb.reg('cancel.err_intarray_recursive_growing_sorted_array', '{errors}', pgmb.ia($q$
with recursive r(n, path) as (
    select 1, array[1]
    union all
    select n + 1, pgmb_intarray.sort(path operator(pgmb_intarray.+) (n + cancel_if(n = 500))) from r where n < 1000)
select count(*), max(pgmb_intarray.icount(path)) from r$q$), expect_error => '57014');
call pgmb.reg('cancel.err_intarray_recursive_cycle_search', '{errors}', pgmb.ia($q$
with recursive r(n, path) as (
    select 1, array[1]
    union all
    select n + 1, path operator(pgmb_intarray.+) (n + 1) from r
    where n < 1000 and pgmb_intarray.idx(path, n + cancel_if(n = 500)) = 0)
select count(*) from r$q$), expect_error => '57014');
\endif
