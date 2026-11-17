-- Topic: cancel (part 3) - what is left after an error, and what the error
-- costs: cursors that survive a cancelled block, statements that leave no
-- partial result, locks, memory, indexes on expressions, triggers, cached
-- plans; and the cost of an error against the amount of work, the depth of
-- subtransactions, the number of locks and of parallel workers.
--
-- The helpers of cancel.sql are used (cancel_now(), cancel_if()). The
-- checks are functions that cause an error, catch it, and report what they
-- find next to the text they must return (consistency groups). The cost
-- tests catch their error in a DO block, so that pgbench goes on.

call pgmb.reg_ddl('cancel.create_after_tables', 'schema', $q$
create table g_cancel_atomic (id int primary key, v int not null);
insert into g_cancel_atomic select n, 0 from generate_series(1, 100) n;
-- an expression index whose function fails for one value
create function cancel_expr_fn(v int) returns int language plpgsql immutable as
$f$begin
    if v = 13 then raise exception 'cancel_expr_fn(13)' using errcode = 'P0090'; end if;
    return v * 2;
end$f$;
create table g_cancel_expr (id int primary key, v int not null);
create index g_cancel_expr_fn on g_cancel_expr (cancel_expr_fn(v));
-- a BEFORE trigger with two side effects, one of which cannot be rolled back
create sequence g_cancel_audit_seq;
create table g_cancel_audit (id int not null, seq bigint not null);
create table g_cancel_audited (id int primary key, v int not null check (v >= 0));
create function cancel_audit_trigger() returns trigger language plpgsql as
$f$begin
    insert into pgmb_data.g_cancel_audit values (new.id, nextval('pgmb_data.g_cancel_audit_seq'));
    return new;
end$f$;
create trigger g_cancel_audited_before before insert on g_cancel_audited
    for each row execute function cancel_audit_trigger();
create table g_cancel_bulk (n int not null)$q$);

call pgmb.reg_ddl('cancel.create_after_functions', 'schema', $q$
-- a cursor opened before a cancelled block, and one opened inside it
create function cancel_cursor_facts() returns text language plpgsql as
$f$declare
    c_outer cursor for select n from generate_series(1, 100) n;
    c_inner cursor for select pgmb_data.cancel_if(n = 5) as x, n from generate_series(1, 100) n;
    v int;
    r record;
    fetched int := 0;
    inner_left text;
begin
    open c_outer;
    for i in 1 .. 10 loop fetch c_outer into v; end loop;
    begin
        open c_inner;
        loop
            fetch c_inner into r;
            exit when not found;
            fetched := fetched + 1;
        end loop;
    exception when query_canceled then null;
    end;
    fetch c_outer into v;
    begin
        fetch c_inner into r;
        inner_left := 'open';
    exception when invalid_cursor_name then
        inner_left := 'gone';
    end;
    close c_outer;
    return format('outer cursor goes on at row %s, inner cursor gave %s rows and is %s', v, fetched, inner_left);
end$f$;

-- each kind of statement fails on its 50th row: nothing of it is left
create function cancel_atomic_facts() returns text language plpgsql as
$f$declare
    failed int := 0;
begin
    begin
        insert into pgmb_data.g_cancel_atomic select 1000 + n, 1 / (n - 50) from generate_series(1, 100) n;
    exception when division_by_zero then failed := failed + 1;
    end;
    begin
        update pgmb_data.g_cancel_atomic set v = v + 1 / (id - 50);
    exception when division_by_zero then failed := failed + 1;
    end;
    begin
        delete from pgmb_data.g_cancel_atomic where 1 / (id - 50) <> 99;
    exception when division_by_zero then failed := failed + 1;
    end;
    begin
        merge into pgmb_data.g_cancel_atomic t using generate_series(1, 100) s(n) on t.id = s.n
        when matched then update set v = 1 / (s.n - 50)
        when not matched then insert values (s.n, 0);
    exception when division_by_zero then failed := failed + 1;
    end;
    begin
        with u as (update pgmb_data.g_cancel_atomic set v = v + 1 returning id)
        insert into pgmb_data.g_cancel_atomic select 2000 + id, 1 / (id - 50) from u;
    exception when division_by_zero then failed := failed + 1;
    end;
    return format('%s statements failed, rows %s, sum %s', failed,
                  (select count(*) from pgmb_data.g_cancel_atomic), (select sum(v) from pgmb_data.g_cancel_atomic));
end$f$;

-- a table lock taken before a failed block is kept, one taken inside it is not
create function cancel_table_lock_facts() returns text language plpgsql as
$f$begin
    lock table pgmb_data.g_cancel_ddl in share mode;
    begin
        lock table pgmb_data.g_cancel_tlock in access exclusive mode;
        perform 1 / 0;
    exception when division_by_zero then null;
    end;
    return format('taken before the block: %s, inside the block: %s',
                  (select count(*) from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
                      and relation = 'pgmb_data.g_cancel_ddl'::regclass and mode = 'ShareLock' and granted),
                  (select count(*) from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
                      and relation = 'pgmb_data.g_cancel_tlock'::regclass and mode = 'AccessExclusiveLock'));
end$f$;

-- a failed insert into a table with an expression index, then one that works:
-- the index finds exactly the rows the table has
create function cancel_expression_index_facts() returns text language plpgsql as
$f$declare
    by_index bigint;
    by_table bigint;
begin
    begin
        insert into pgmb_data.g_cancel_expr select n, n from generate_series(1, 20) n;
    exception when sqlstate 'P0090' then null;
    end;
    insert into pgmb_data.g_cancel_expr select n, n from generate_series(21, 40) n;
    perform set_config('enable_seqscan', 'off', true);
    execute 'select count(*) from pgmb_data.g_cancel_expr where pgmb_data.cancel_expr_fn(v) between 0 and 1000' into by_index;
    perform set_config('enable_seqscan', 'on', true);
    perform set_config('enable_indexscan', 'off', true);
    perform set_config('enable_bitmapscan', 'off', true);
    execute 'select count(*) from pgmb_data.g_cancel_expr where pgmb_data.cancel_expr_fn(v) between 0 and 1000' into by_table;
    perform set_config('enable_indexscan', 'on', true);
    perform set_config('enable_bitmapscan', 'on', true);
    return format('index %s, table %s', by_index, by_table);
end$f$;

-- the trigger ran for rows 1 to 5 before row 5 broke the CHECK constraint:
-- its rows are gone, the sequence values it took are not
create function cancel_trigger_facts() returns text language plpgsql as
$f$declare
    v0 bigint;
begin
    v0 := nextval('pgmb_data.g_cancel_audit_seq');
    begin
        insert into pgmb_data.g_cancel_audited
        select n, case when n = 5 then -1 else n end from generate_series(1, 10) n;
    exception when check_violation then null;
    end;
    return format('audit rows %s, audited rows %s, sequence values taken %s',
                  (select count(*) from pgmb_data.g_cancel_audit),
                  (select count(*) from pgmb_data.g_cancel_audited),
                  nextval('pgmb_data.g_cancel_audit_seq') - v0 - 1);
end$f$;

-- a prepared statement and a cached PL/pgSQL plan, used after they failed
create function cancel_divide(x int) returns int language plpgsql as
'begin return 100 / x; end';
create function cancel_reuse_after_error_facts() returns text language plpgsql as
$f$declare
    a int;
    b int;
begin
    begin
        execute 'deallocate cancel_ps';
    exception when invalid_sql_statement_name then null;
    end;
    execute 'prepare cancel_ps(int) as select 100 / $1';
    begin
        execute 'execute cancel_ps(0)' into a;
    exception when division_by_zero then null;
    end;
    execute 'execute cancel_ps(5)' into a;
    execute 'deallocate cancel_ps';
    begin
        b := pgmb_data.cancel_divide(0);
    exception when division_by_zero then null;
    end;
    b := pgmb_data.cancel_divide(4);
    return format('prepared statement after the error: %s, function after the error: %s', a, b);
end$f$;

-- an error passed up through d nested exception blocks, one per call
create function cancel_nested(d int) returns int language plpgsql as
$f$begin
    if d <= 1 then
        return 1 / 0;
    end if;
    return pgmb_data.cancel_nested(d - 1);
exception when division_by_zero then
    raise;
end$f$;

-- n advisory locks of its own (keys from the backend's pid), then an error or not
create function cancel_locks_then_error(n int, fail boolean) returns int language plpgsql as
$f$declare
    base bigint := pg_backend_pid()::bigint * 1000;
begin
    for i in 1 .. n loop
        perform pg_advisory_xact_lock(base + i);
    end loop;
    if fail then
        return 1 / 0;
    end if;
    return n;
end$f$$q$);

------------------------------------------------------------------------------
-- 9.8 a cursor that was being read when the cancel came
------------------------------------------------------------------------------
call pgmb.reg('cancel.cursor_outside_cancelled_block', '{consistency}',
    $q$select cancel_cursor_facts()$q$, equiv => 'cancel.cursor');
call pgmb.reg('cancel.cursor_outside_cancelled_block_expected', '{consistency}', $q$
select 'outer cursor goes on at row 11, inner cursor gave 4 rows and is gone'::text$q$, equiv => 'cancel.cursor');

-- a cursor cancelled on a row of its second batch
call pgmb.reg('cancel.err_cursor_cancelled_in_second_fetch', '{errors}', $q$
do $do$
declare
    c cursor for select pgmb_data.cancel_if(n = 15) as x from generate_series(1, 100) n;
    r record;
begin
    open c;
    for i in 1 .. 20 loop fetch c into r; end loop;
end $do$$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- 9.9 what is left after an error
------------------------------------------------------------------------------
call pgmb.reg('cancel.atomic_statements', '{consistency}',
    $q$select cancel_atomic_facts()$q$, equiv => 'cancel.atomic');
call pgmb.reg('cancel.atomic_statements_expected', '{consistency}',
    $q$select '5 statements failed, rows 100, sum 0'::text$q$, equiv => 'cancel.atomic');

call pgmb.reg('cancel.table_lock_released_with_block', '{consistency}',
    $q$select cancel_table_lock_facts()$q$, equiv => 'cancel.table_lock');
call pgmb.reg('cancel.table_lock_released_with_block_expected', '{consistency}',
    $q$select 'taken before the block: 1, inside the block: 0'::text$q$, equiv => 'cancel.table_lock');

call pgmb.reg('cancel.expression_index_after_failed_insert', '{consistency}',
    $q$select cancel_expression_index_facts()$q$, equiv => 'cancel.expression_index');
call pgmb.reg('cancel.expression_index_after_failed_insert_expected', '{consistency}',
    $q$select 'index 20, table 20'::text$q$, equiv => 'cancel.expression_index');
call pgmb.reg('cancel.err_expression_index_function_fails', '{errors}',
    $q$insert into g_cancel_expr values (-13, 13)$q$, expect_error => 'P0090');

call pgmb.reg('cancel.trigger_side_effects_after_error', '{consistency}',
    $q$select cancel_trigger_facts()$q$, equiv => 'cancel.trigger_effects');
call pgmb.reg('cancel.trigger_side_effects_after_error_expected', '{consistency}',
    $q$select 'audit rows 0, audited rows 0, sequence values taken 5'::text$q$, equiv => 'cancel.trigger_effects');

call pgmb.reg('cancel.reuse_after_error', '{consistency}',
    $q$select cancel_reuse_after_error_facts()$q$, equiv => 'cancel.reuse');
call pgmb.reg('cancel.reuse_after_error_expected', '{consistency}',
    $q$select 'prepared statement after the error: 20, function after the error: 25'::text$q$, equiv => 'cancel.reuse');

call pgmb.reg('cancel.err_nested_blocks_100_deep', '{errors}',
    $q$select cancel_nested(100)$q$, expect_error => '22012');

-- 50 cancelled statements that build a large hash table: the memory of the
-- backend after the 50th is not larger than after the 5th by more than 1 MB
select has_table_privilege(current_user, 'pg_catalog.pg_backend_memory_contexts', 'select') as pgmb_cancel_memctx \gset
\if :pgmb_cancel_memctx
call pgmb.reg_ddl('cancel.create_memory_function', 'schema', $q$
create function cancel_memory_growth() returns boolean language plpgsql as
$f$declare
    after5 bigint;
    after50 bigint;
begin
    perform set_config('work_mem', '64MB', true);
    perform set_config('enable_sort', 'off', true);
    for i in 1 .. 50 loop
        begin
            execute 'select count(pgmb_data.cancel_if(k = 25000)) from '
                    '(select n % 50000 as k, count(*) from generate_series(1, 100000) n group by 1) s';
        exception when query_canceled then null;
        end;
        if i = 5 then
            after5 := (select sum(total_bytes) from pg_backend_memory_contexts);
        end if;
    end loop;
    after50 := (select sum(total_bytes) from pg_backend_memory_contexts);
    return after50 - after5 < 1048576;
end$f$$q$);
call pgmb.reg('cancel.memory_not_growing_after_cancels', '{consistency}',
    $q$select cancel_memory_growth()$q$, equiv => 'cancel.memory');
call pgmb.reg('cancel.memory_not_growing_after_cancels_expected', '{consistency}',
    $q$select true$q$, equiv => 'cancel.memory');
\endif

------------------------------------------------------------------------------
-- 9.10 the cost of an error
------------------------------------------------------------------------------
-- rows processed before the error: 1, 100, 10,000, 1,000,000; each with a
-- twin that does the same work and does not fail
select format($f$call pgmb.reg('cancel.cost_cancel_after_%1$s_rows', '{perf}', %2$L)$f$, n,
              format(E'do $do$\nbegin\n    perform count(cancel_if(n = %1$s)) from generate_series(1, %1$s) n;\n'
                     'exception when query_canceled then null;\nend $do$', n)),
       format($f$call pgmb.reg('cancel.cost_no_cancel_%1$s_rows', '{perf}', %2$L)$f$, n,
              format(E'do $do$\nbegin\n    perform count(cancel_if(false)) from generate_series(1, %1$s) n;\nend $do$', n))
from unnest(array[1, 100, 10000, 1000000]) n \gexec

-- rows written and then undone by the error; the largest is opt-in
select format($f$call pgmb.reg('cancel.cost_rollback_after_insert_%1$s_rows', %2$L, %3$L, kind => 'write')$f$, n, tags,
              format(E'do $do$\nbegin\n    insert into pgmb_data.g_cancel_bulk select n from generate_series(1, %1$s) n;\n'
                     '    perform 1 / 0;\nexception when division_by_zero then null;\nend $do$', n))
from (values (1, '{perf}'), (100, '{perf}'), (10000, '{perf}'), (1000000, '{perf,optin_large_rollback}')) v(n, tags) \gexec

-- an error passed up through 1, 10 and 100 exception blocks
select format($f$call pgmb.reg('cancel.cost_error_through_%1$s_blocks', '{perf}', %2$L)$f$, d,
              format(E'do $do$\nbegin\n    perform cancel_nested(%1$s);\nexception when division_by_zero then null;\nend $do$', d))
from unnest(array[1, 10, 100]) d \gexec

-- 1, 10 and 100 locks released by the error, and by a commit
select format($f$call pgmb.reg('cancel.cost_error_releases_%1$s_locks', '{perf}', %2$L)$f$, n,
              format(E'do $do$\nbegin\n    perform cancel_locks_then_error(%1$s, true);\nexception when division_by_zero then null;\nend $do$', n)),
       format($f$call pgmb.reg('cancel.cost_commit_releases_%1$s_locks', '{perf}', %2$L)$f$, n,
              format('select cancel_locks_then_error(%1$s, false)', n))
from unnest(array[1, 10, 100]) n \gexec

-- an error in the middle of a parallel scan with 0, 1, 2, 4 and 8 workers,
-- against the same scan without the error
-- (pgbench turns :variables into parameters under the extended protocol, and
-- a DO block takes none, so the middle row is handed over in a setting)
select format($f$call pgmb.reg('cancel.cost_parallel_error_%1$s_workers', '{perf}', %2$L)$f$, w,
              format(E'begin;\nset local max_parallel_workers_per_gather = %1$s;\nset local min_parallel_table_scan_size = 0;\n'
                     'set local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\n'
                     'select set_config(''pgmb.half'', (:n_g_narrow / 2)::text, true);\n'
                     'do $do$\nbegin\n    perform sum(1 / (id - current_setting(''pgmb.half'')::bigint)) from pgmb_data.g_narrow;\n'
                     'exception when division_by_zero then null;\nend $do$;\ncommit;', w)),
       format($f$call pgmb.reg('cancel.cost_parallel_no_error_%1$s_workers', '{perf}', %2$L)$f$, w,
              format(E'begin;\nset local max_parallel_workers_per_gather = %1$s;\nset local min_parallel_table_scan_size = 0;\n'
                     'set local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\n'
                     'select sum(1 / (id + 1)) from g_narrow;\ncommit;', w))
from unnest(array[0, 1, 2, 4, 8]) w \gexec
