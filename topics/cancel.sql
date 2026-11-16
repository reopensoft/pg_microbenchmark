-- Topic: cancel - a statement interrupted at a chosen point of its life.
--
-- Two ways of interrupting are used.
--
-- 1. The statement cancels itself: a function calls pg_cancel_backend() on its
--    own backend and the cancel is taken at the next interrupt check, inside
--    that function. Where the function is called decides the phase: while the
--    planner folds constants, when the executor starts up, on row N of a scan,
--    while a sort or a hash table is being filled, in RETURNING, in a trigger.
--    These are error tests: the statement must end with 57014 (query_canceled).
--    A statement that survives its own cancel fails the test.
--
-- 2. statement_timeout fires on its own schedule, or the cancel is requested
--    just before the statement starts. Parsing, parse analysis and rewriting
--    run no user code, so nothing can cancel from the inside there; these
--    tests show how long the server takes to notice. pgbench drops a client on any
--    error, so the cancel is caught in a DO block: the measured time is the
--    time until the cancel is noticed plus the cost of unwinding. Each has a
--    twin without the timeout. The protected work is followed by pg_sleep(1)
--    in the same block: a timeout that fires just as the work ends (a lock
--    granted at the last moment) is then still taken inside the block, not
--    after it, where it would end the pgbench client.
--
-- Not covered here, because they need a second session or a client that sees
-- the error at the top level: cancelling an idle session, an incomplete
-- protocol message, rows already sent to the client, a real COMMIT, the race
-- after the statement has finished, the messages of the extended protocol and
-- several statements in one simple-query message.

call pgmb.reg_ddl('cancel.create_functions', 'schema', $q$
-- pg_sleep() checks for interrupts first: the cancel is raised right here.
-- If it is not, the function returns after a second and the test fails.
create function cancel_now() returns int language plpgsql as
'begin perform pg_cancel_backend(pg_backend_pid()); perform pg_sleep(1); return 1; end';
create function cancel_if(cond boolean) returns int language plpgsql as
'begin if cond then perform cancel_now(); end if; return 1; end';
-- declared immutable so that the planner evaluates it while folding constants
create function cancel_immutable(v int) returns int language plpgsql immutable as
'begin perform cancel_now(); return v; end';
-- stable, and harmless until pgmb.cancel_armed is switched on
create function cancel_armed(v int) returns int language plpgsql stable as
$f$begin
    if current_setting('pgmb.cancel_armed', true) = 'on' then perform cancel_now(); end if;
    return v;
end$f$;
-- The query has no parameters, so its plan is built in the first pass and
-- reused in the second. A stable function is called by the planner (for the
-- row estimate) and again when the executor starts up, to prune partitions.
-- Armed only for the second pass, it cancels during executor startup.
create function cancel_at_executor_start() returns bigint language plpgsql as
$f$declare
    n bigint;
begin
    for pass in 1 .. 2 loop
        if pass = 2 then perform set_config('pgmb.cancel_armed', 'on', true); end if;
        select count(*) into n from pgmb_data.g_part where bucket = pgmb_data.cancel_armed(3);
    end loop;
    return n;
end$f$;
create function cancel_trigger() returns trigger language plpgsql as
'begin perform pgmb_data.cancel_now(); return null; end'$q$);

call pgmb.reg_ddl('cancel.create_g_cancel', 'schema', $q$
create table g_cancel (id int not null);
create constraint trigger g_cancel_after_insert after insert on g_cancel
    deferrable initially immediate for each row execute function cancel_trigger()$q$);

------------------------------------------------------------------------------
-- planner
------------------------------------------------------------------------------
-- an immutable function with constant arguments is evaluated by the planner
call pgmb.reg('cancel.err_planner_constant_folding', '{errors}',
    $q$select count(*) from generate_series(1, 10) n where n = cancel_immutable(1)$q$, expect_error => '57014');

call pgmb.reg('cancel.err_planner_constant_folding_in_cte', '{errors}',
    $q$with c as (select cancel_immutable(1) as x) select x from c$q$, expect_error => '57014');

call pgmb.reg('cancel.err_planner_constant_folding_in_subquery', '{errors}',
    $q$select n from generate_series(1, 10) n where exists (select 1 where cancel_immutable(1) = 1)$q$,
    expect_error => '57014');

-- a stable function is evaluated by the planner too, to estimate the row count
call pgmb.reg('cancel.err_planner_estimate_of_stable_function', '{errors}', $q$
begin;
set local pgmb.cancel_armed = 'on';
select count(*) from g_narrow where k_100 = cancel_armed(7);
commit;$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- executor startup
------------------------------------------------------------------------------
-- partitions are pruned with a stable function while the plan state is built
call pgmb.reg('cancel.err_executor_start_partition_pruning', '{errors}',
    $q$select cancel_at_executor_start()$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- first row
------------------------------------------------------------------------------
-- the scalar subquery is evaluated when the first row needs it: nothing has been read
call pgmb.reg('cancel.err_first_row_before_any_row', '{errors}',
    $q$select n from generate_series(1, 100) n where n > (select cancel_now())$q$, expect_error => '57014');

call pgmb.reg('cancel.err_first_row_on_it', '{errors}',
    $q$select cancel_if(n = 1) from generate_series(1, 100) n$q$, expect_error => '57014');

call pgmb.reg('cancel.err_first_row_after_it', '{errors}',
    $q$select cancel_if(n = 2) from generate_series(1, 100) n$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- halfway through a scan
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_scan_seq_halfway', '{errors,needs_data}',
    $q$select count(*) from g_narrow where cancel_if(id = :n_g_narrow / 2) = 1$q$, expect_error => '57014');

call pgmb.reg('cancel.err_scan_index_halfway', '{errors,needs_data}', $q$
begin;
set local enable_seqscan = off;
set local enable_bitmapscan = off;
select count(*) from g_narrow where id between 1 and 1000 and cancel_if(id = 500) = 1;
commit;$q$, expect_error => '57014');

call pgmb.reg('cancel.err_scan_bitmap_heap_halfway', '{errors,needs_data}', $q$
begin;
set local enable_seqscan = off;
set local enable_indexscan = off;
select count(*) from g_narrow where id between 1 and 1000 and cancel_if(id = 500) = 1;
commit;$q$, expect_error => '57014');

-- one partition has been read to the end, the next one is open
call pgmb.reg('cancel.err_scan_append_second_partition', '{errors,needs_data}',
    $q$select count(*) from g_part where cancel_if(bucket = 1) = 1$q$, expect_error => '57014');

-- an expensive filter in front: the cancel arrives between two long evaluations
call pgmb.reg('cancel.err_scan_expensive_filter_halfway', '{errors}', $q$
select count(*) from generate_series(1, 100000) n
where md5(md5(md5(n::text))) <> '' and cancel_if(n = 50000) = 1$q$, expect_error => '57014');

-- the rows are produced by a recursive CTE and by a materialized CTE read twice
call pgmb.reg('cancel.err_scan_recursive_cte_halfway', '{errors}', $q$
with recursive r(n) as (select 1 union all select n + 1 from r where n < 100000)
select count(cancel_if(n = 50000)) from r$q$, expect_error => '57014');

call pgmb.reg('cancel.err_scan_materialized_cte_second_reader', '{errors}', $q$
with c as materialized (select n from generate_series(1, 100000) n)
select (select count(*) from c), (select count(cancel_if(n = 50000)) from c)$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- sort: while the rows are loaded, and while the sorted rows are returned
------------------------------------------------------------------------------
-- c is a sort key, so it is computed below the Sort node, row by row, while
-- the sort collects its input
call pgmb.reg('cancel.err_sort_in_memory_while_loading', '{errors}', $q$
begin;
set local work_mem = '64MB';
select x from (select (n * 7919) % 100003 as x, cancel_if(n = 90000) as c from generate_series(1, 100000) n) s
order by x, c;
commit;$q$, expect_error => '57014');

-- the same with 64 kB: runs are already in temporary files when the cancel arrives
call pgmb.reg('cancel.err_sort_external_while_loading', '{errors}', $q$
begin;
set local work_mem = '64kB';
select x from (select (n * 7919) % 100003 as x, cancel_if(n = 90000) as c from generate_series(1, 100000) n) s
order by x, c;
commit;$q$, expect_error => '57014');

-- the function sits above the sort: the cancel arrives while sorted rows are read
call pgmb.reg('cancel.err_sort_in_memory_while_returning', '{errors}', $q$
begin;
set local work_mem = '64MB';
select cancel_if(rn = 50000)
from (select row_number() over (order by x) as rn
      from (select (n * 7919) % 100003 as x from generate_series(1, 100000) n) s) t;
commit;$q$, expect_error => '57014');

call pgmb.reg('cancel.err_sort_external_while_returning', '{errors}', $q$
begin;
set local work_mem = '64kB';
select cancel_if(rn = 50000)
from (select row_number() over (order by x) as rn
      from (select (n * 7919) % 100003 as x from generate_series(1, 100000) n) s) t;
commit;$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- hash join: while the table is built, and while it is probed
------------------------------------------------------------------------------
-- the smaller input is hashed; the function runs on the side named in the test
call pgmb.reg('cancel.err_hash_join_while_building', '{errors}', $q$
begin;
set local enable_mergejoin = off;
set local enable_nestloop = off;
set local work_mem = '64MB';
select count(i.c)
from generate_series(1, 100000) o(n)
     join (select n, cancel_if(n = 500) as c from generate_series(1, 1000) n offset 0) i on i.n = o.n;
commit;$q$, expect_error => '57014');

call pgmb.reg('cancel.err_hash_join_while_probing', '{errors}', $q$
begin;
set local enable_mergejoin = off;
set local enable_nestloop = off;
set local work_mem = '64MB';
select count(o.c)
from (select n, cancel_if(n = 50000) as c from generate_series(1, 100000) n offset 0) o
     join generate_series(1, 1000) i(n) on i.n = o.n;
commit;$q$, expect_error => '57014');

-- 64 kB: the hash table is split into batches kept in temporary files
call pgmb.reg('cancel.err_hash_join_batches_while_building', '{errors}', $q$
begin;
set local enable_mergejoin = off;
set local enable_nestloop = off;
set local work_mem = '64kB';
select count(i.c)
from generate_series(1, 100000) o(n)
     join (select n, cancel_if(n = 40000) as c from generate_series(1, 50000) n offset 0) i on i.n = o.n;
commit;$q$, expect_error => '57014');

call pgmb.reg('cancel.err_hash_join_batches_while_probing', '{errors}', $q$
begin;
set local enable_mergejoin = off;
set local enable_nestloop = off;
set local work_mem = '64kB';
select count(o.c)
from (select n, cancel_if(n = 90000) as c from generate_series(1, 100000) n offset 0) o
     join generate_series(1, 50000) i(n) on i.n = o.n;
commit;$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- hash aggregate: while the groups are collected, and while they are returned
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_hash_aggregate_while_collecting', '{errors}', $q$
begin;
set local enable_sort = off;
set local work_mem = '64MB';
select x, count(c)
from (select n % 1000 as x, cancel_if(n = 90000) as c from generate_series(1, 100000) n offset 0) s
group by x;
commit;$q$, expect_error => '57014');

-- 50000 groups in 64 kB: groups have been written out when the cancel arrives
call pgmb.reg('cancel.err_hash_aggregate_spilled_while_collecting', '{errors}', $q$
begin;
set local enable_sort = off;
set local work_mem = '64kB';
select x, count(c)
from (select n % 50000 as x, cancel_if(n = 90000) as c from generate_series(1, 100000) n offset 0) s
group by x;
commit;$q$, expect_error => '57014');

call pgmb.reg('cancel.err_hash_aggregate_while_returning', '{errors}', $q$
begin;
set local enable_sort = off;
set local work_mem = '64MB';
select cancel_if(x = 500)
from (select n % 1000 as x, count(*) as cnt from generate_series(1, 100000) n group by 1 offset 0) s;
commit;$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- RETURNING: rows have been written when the cancel arrives
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_returning_update_halfway', '{errors,needs_data}',
    $q$update g_dml set qty = qty + 1 where id between 1 and 100 returning cancel_if(id = 50)$q$,
    expect_error => '57014');

call pgmb.reg('cancel.err_returning_insert_halfway', '{errors}', $q$
insert into g_dml_audit (dml_id, action)
select n, 'cancel' from generate_series(1, 100) n
returning cancel_if(dml_id = 50)$q$, expect_error => '57014');

call pgmb.reg('cancel.err_returning_delete_halfway', '{errors,needs_data}',
    $q$delete from g_dml_trig where id between 1 and 100 returning cancel_if(id = 50)$q$, expect_error => '57014');

-- nothing reads the CTE: the writer still runs to the end, and into the cancel
call pgmb.reg('cancel.err_returning_in_unread_cte', '{errors,needs_data}', $q$
with u as (update g_dml set qty = qty + 1 where id between 1 and 100 returning cancel_if(id = 50))
select 1$q$, expect_error => '57014');

-- the second writer is cancelled after the first one has finished
call pgmb.reg('cancel.err_returning_second_writer', '{errors,needs_data}', $q$
with a as (update g_dml set qty = qty + 1 where id between 1 and 50 returning id),
     b as (update g_dml set qty = qty + 1 where id between 51 and 100 returning cancel_if(id = 75) as c)
select (select count(*) from a), (select count(c) from b)$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- triggers: at the end of the statement, and when deferred triggers are fired
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_trigger_at_statement_end', '{errors}',
    $q$insert into g_cancel select n from generate_series(1, 10) n$q$, expect_error => '57014');

-- the insert succeeds; the queued trigger runs at SET CONSTRAINTS, as it
-- would at COMMIT
call pgmb.reg('cancel.err_trigger_deferred_fired_by_set_constraints', '{errors}', $q$
do $do$
begin
    set constraints pgmb_data.g_cancel_after_insert deferred;
    insert into pgmb_data.g_cancel select n from generate_series(1, 10) n;
    set constraints pgmb_data.g_cancel_after_insert immediate;
end $do$$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- a cancel that is already pending while a statement is parsed, analysed and rewritten
------------------------------------------------------------------------------
-- No user code runs in these phases, so the cancel cannot come from inside,
-- and a timeout short enough to hit them would fire before the DO block has
-- installed its handler. Instead the cancel is requested first and the
-- statement is started in the same select list, by query_to_xml(): nothing
-- checks for interrupts between the two. The time until the cancel is taken,
-- against the twin without it, is what these phases let pass.
-- (Without libxml query_to_xml() runs the statement and then fails; the twin
-- catches that.)
select string_agg((i * 3)::text, ',') as pgmb_cancel_in50k from generate_series(1, 50000) i \gset
select string_agg('select total from v_category_totals_cat01 where false', ' union all ') as pgmb_cancel_views
from generate_series(1, 200) \gset
select string_agg(format('join g_dim d%s on d%s.id = p.dim_id + %s', i, i, i), ' ' order by i) as pgmb_cancel_star
from generate_series(1, 10) i \gset

-- a list of 50,000 constants: parser and parse analysis, almost nothing to execute
call pgmb.reg('cancel.pending_cancel_long_in_list', '{perf}', format($q$
do $do$
begin
    perform pg_cancel_backend(pg_backend_pid()),
            query_to_xml($s$select count(*) from g_dim where id in (%s)$s$, false, false, '');
exception when query_canceled then null;
end $do$;$q$, :'pgmb_cancel_in50k'));

call pgmb.reg('cancel.no_cancel_long_in_list', '{perf}', format($q$
do $do$
begin
    perform query_to_xml($s$select count(*) from g_dim where id in (%s)$s$, false, false, '');
exception when feature_not_supported then null;
end $do$;$q$, :'pgmb_cancel_in50k'));

-- 200 references to a view built on two more views: rewriter, then the planner;
-- every branch is "where false", so nothing is executed
call pgmb.reg('cancel.pending_cancel_view_expansion_200', '{perf}', format($q$
do $do$
begin
    perform pg_cancel_backend(pg_backend_pid()),
            query_to_xml($s$select count(*) from (%s) s$s$, false, false, '');
exception when query_canceled then null;
end $do$;$q$, :'pgmb_cancel_views'));

call pgmb.reg('cancel.no_cancel_view_expansion_200', '{perf}', format($q$
do $do$
begin
    perform query_to_xml($s$select count(*) from (%s) s$s$, false, false, '');
exception when feature_not_supported then null;
end $do$;$q$, :'pgmb_cancel_views'));

------------------------------------------------------------------------------
-- statement_timeout inside the planner
------------------------------------------------------------------------------
-- a star of 11 relations searched exhaustively; the query itself reads one row
call pgmb.reg('cancel.timeout_5ms_planner_star_join_11', '{perf}', format($q$
begin;
set local join_collapse_limit = 20;
set local from_collapse_limit = 20;
set local geqo = off;
set local statement_timeout = '5ms';
do $do$
begin
    execute $s$select count(*) from g_parent p %s where p.id = 1$s$;
    perform pg_sleep(1);
exception when query_canceled then null;
end $do$;
commit;$q$, :'pgmb_cancel_star'));

call pgmb.reg('cancel.timeout_none_planner_star_join_11', '{perf}', format($q$
begin;
set local join_collapse_limit = 20;
set local from_collapse_limit = 20;
set local geqo = off;
do $do$
begin
    execute $s$select count(*) from g_parent p %s where p.id = 1$s$;
end $do$;
commit;$q$, :'pgmb_cancel_star'));

------------------------------------------------------------------------------
-- statement_timeout in the executor: scan, sort, hash
------------------------------------------------------------------------------
-- Bounded inputs, as a safety net in case the timeout does not fire.
call pgmb.reg('cancel.timeout_20ms_scan_expensive_filter', '{perf}', $q$
begin;
set local statement_timeout = '20ms';
do $do$
begin
    perform count(*) from generate_series(1, 2000000) n where md5(md5(md5(n::text))) < '0';
    perform pg_sleep(1);
exception when query_canceled then null;
end $do$;
commit;$q$);

call pgmb.reg('cancel.timeout_20ms_external_sort', '{perf}', $q$
begin;
set local work_mem = '64kB';
set local statement_timeout = '20ms';
do $do$
begin
    perform count(*) from (select md5(n::text) as x from generate_series(1, 1000000) n order by 1 offset 0) s;
    perform pg_sleep(1);
exception when query_canceled then null;
end $do$;
commit;$q$);

call pgmb.reg('cancel.timeout_20ms_hash_aggregate_spilled', '{perf}', $q$
begin;
set local work_mem = '64kB';
set local enable_sort = off;
set local statement_timeout = '20ms';
do $do$
begin
    perform count(*) from (select md5(n::text) as x, count(*) from generate_series(1, 1000000) n group by 1 offset 0) s;
    perform pg_sleep(1);
exception when query_canceled then null;
end $do$;
commit;$q$);

------------------------------------------------------------------------------
-- statement_timeout while the backend waits
------------------------------------------------------------------------------
-- waiting on its latch
call pgmb.reg('cancel.timeout_20ms_waiting_in_sleep', '{perf}', $q$
begin;
set local statement_timeout = '20ms';
do $do$
begin
    perform pg_sleep(1);
exception when query_canceled then null;
end $do$;
commit;$q$);

-- Waiting for a lock. Every client wants the same advisory lock and whoever
-- gets it keeps it for 30 ms, longer than the timeout: with two or more
-- clients the others are cancelled in the lock queue. A single client never
-- waits. An advisory lock is used so that no other test is blocked.
call pgmb.reg('cancel.timeout_20ms_waiting_for_lock', '{perf,locking,concurrency}', $q$
begin;
set local statement_timeout = '20ms';
do $do$
begin
    perform pg_advisory_xact_lock(7291001);
    perform pg_sleep(1);
exception when query_canceled then null;
end $do$;
set local statement_timeout = 0;
select pg_sleep(0.03);
commit;$q$);

------------------------------------------------------------------------------
-- parallel query
------------------------------------------------------------------------------
-- The same idea with worker processes. A parallel safe function cancels the
-- worker that runs it: the worker ends with an error, the leader reports it
-- and stops the other workers. A parallel restricted function runs in the
-- leader, above Gather, while the workers are busy below it. The tests that
-- must fail in a worker switch parallel_leader_participation off, so that
-- the leader does not scan; if no worker can be started (max_worker_processes,
-- max_parallel_workers) the leader runs the plan alone and the tests that
-- name a worker in their expected SQLSTATE fail.
call pgmb.reg_ddl('cancel.create_parallel_functions', 'schema', $q$
create function cancel_in_worker() returns boolean language plpgsql stable parallel safe as
'begin return (select leader_pid is not null from pg_stat_activity where pid = pg_backend_pid()); end';
create function cancel_if_safe(cond boolean) returns int language plpgsql parallel safe as
'begin if cond then perform pgmb_data.cancel_now(); end if; return 1; end';
create function cancel_if_restricted(cond boolean) returns int language plpgsql parallel restricted as
'begin if cond then perform pgmb_data.cancel_now(); end if; return 1; end';
-- the SQLSTATE tells where the function was running: PGW01 in a worker, PGL01 in the leader
create function fail_where_it_runs(cond boolean) returns int language plpgsql parallel safe as
$f$begin
    if cond then
        if pgmb_data.cancel_in_worker() then
            raise exception 'raised in a parallel worker' using errcode = 'PGW01';
        end if;
        raise exception 'raised in the leader' using errcode = 'PGL01';
    end if;
    return 1;
end$f$;
create function fail_where_it_runs_restricted(cond boolean) returns int language plpgsql parallel restricted as
'begin return pgmb_data.fail_where_it_runs(cond); end';
create function fail_where_it_runs_unsafe(cond boolean) returns int language plpgsql parallel unsafe as
'begin return pgmb_data.fail_where_it_runs(cond); end';
-- ends the worker that runs it, never the leader: the worker exits with FATAL
create function terminate_worker_if(cond boolean) returns int language plpgsql parallel safe as
$f$begin
    if cond and pgmb_data.cancel_in_worker() then
        perform pg_terminate_backend(pg_backend_pid());
        perform pg_sleep(1);
    end if;
    return 1;
end$f$$q$);

\set pgmb_cancel_par 'begin;\nset local max_parallel_workers_per_gather = 2;\nset local min_parallel_table_scan_size = 0;\nset local min_parallel_index_scan_size = 0;\nset local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\n'
\set pgmb_cancel_worker 'begin;\nset local max_parallel_workers_per_gather = 2;\nset local min_parallel_table_scan_size = 0;\nset local min_parallel_index_scan_size = 0;\nset local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\nset local parallel_leader_participation = off;\n'
\set pgmb_cancel_end ';\ncommit;'

-- where a function runs, and where its error comes from
call pgmb.reg('cancel.err_parallel_safe_function_fails_in_worker', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select count(fail_where_it_runs(id = :n_g_narrow / 2)) from g_narrow$q$ || :'pgmb_cancel_end', expect_error => 'PGW01');

call pgmb.reg('cancel.err_parallel_restricted_function_fails_in_leader', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select count(fail_where_it_runs_restricted(id = :n_g_narrow / 2)) from g_narrow$q$ || :'pgmb_cancel_end', expect_error => 'PGL01');

call pgmb.reg('cancel.err_parallel_unsafe_function_fails_in_leader', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select count(fail_where_it_runs_unsafe(id = :n_g_narrow / 2)) from g_narrow$q$ || :'pgmb_cancel_end', expect_error => 'PGL01');

-- an error in a worker reaches the leader with its own SQLSTATE
call pgmb.reg('cancel.err_parallel_worker_division_by_zero', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select sum(1 / (id - :n_g_narrow / 2)) from g_narrow$q$ || :'pgmb_cancel_end', expect_error => '22012');

-- Parallel Seq Scan: one worker is cancelled halfway through the table
call pgmb.reg('cancel.err_parallel_seq_scan_worker_cancelled', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select count(*) from g_narrow where cancel_if_safe(id = :n_g_narrow / 2) = 1$q$ || :'pgmb_cancel_end', expect_error => '57014');

-- the worker process goes away (FATAL): the leader must report it, not hang
call pgmb.reg('cancel.err_parallel_worker_terminated', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select count(terminate_worker_if(id = :n_g_narrow / 2)) from g_narrow$q$ || :'pgmb_cancel_end', expect_error => '57P01');

-- the leader is cancelled while it reads from Gather: on the first row, when
-- the workers have only just started, and halfway
call pgmb.reg('cancel.err_parallel_leader_cancelled_on_first_row', '{errors,needs_data}', :'pgmb_cancel_par' || $q$
select cancel_if_restricted(true) from g_narrow$q$ || :'pgmb_cancel_end', expect_error => '57014');

call pgmb.reg('cancel.err_parallel_leader_cancelled_under_gather', '{errors,needs_data}', :'pgmb_cancel_par' || $q$
select cancel_if_restricted(id = :n_g_narrow / 2) from g_narrow$q$ || :'pgmb_cancel_end', expect_error => '57014');

-- the workers sort (on a column without an index), the leader merges and is
-- cancelled in the middle of the merge
call pgmb.reg('cancel.err_parallel_leader_cancelled_under_gather_merge', '{errors,needs_data}', :'pgmb_cancel_par' || $q$
select cancel_if_restricted(id = :n_g_narrow / 2) from (select id from g_narrow order by pad offset 0) s$q$ || :'pgmb_cancel_end',
    expect_error => '57014');

-- partial aggregation: a worker fails with groups half collected
call pgmb.reg('cancel.err_parallel_aggregate_worker_cancelled', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select k_100, count(cancel_if_safe(id = :n_g_narrow / 2)) from g_narrow group by k_100$q$ || :'pgmb_cancel_end',
    expect_error => '57014');

call pgmb.reg('cancel.err_parallel_aggregate_worker_division_by_zero', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select k_100, sum(1 / (id - :n_g_narrow / 2)) from g_narrow group by k_100$q$ || :'pgmb_cancel_end',
    expect_error => '22012');

-- hash join in workers, between two tables (a join of a table with itself on
-- its key would be reduced to one scan): the filtered side looks small to the
-- planner and is hashed; the function sits on the side named in the test
call pgmb.reg('cancel.err_parallel_hash_join_build_side', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
set local enable_mergejoin = off;
set local enable_nestloop = off;
select count(*) from g_narrow a join g_events b on b.id = a.id
where cancel_if_safe(b.id = :n_g_events / 2) = 1$q$ || :'pgmb_cancel_end', expect_error => '57014');

call pgmb.reg('cancel.err_parallel_hash_join_probe_side', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
set local enable_mergejoin = off;
set local enable_nestloop = off;
select count(*) from g_narrow a join g_events b on b.id = a.id
where b.cat = 0 and cancel_if_safe(a.id = :n_g_narrow / 2) > 0$q$ || :'pgmb_cancel_end', expect_error => '57014');

-- 64 kB: the table outgrows its memory while it is built and is split into batches
call pgmb.reg('cancel.err_parallel_hash_join_build_side_work_mem_64kb', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
set local enable_mergejoin = off;
set local enable_nestloop = off;
set local work_mem = '64kB';
select count(*) from g_narrow a join g_events b on b.id = a.id
where cancel_if_safe(b.id = :n_g_events / 2) = 1$q$ || :'pgmb_cancel_end', expect_error => '57014');

-- Parallel Append: one partition fails while the others are being read
call pgmb.reg('cancel.err_parallel_append_partition_cancelled', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select count(cancel_if_safe(bucket = 7)) from g_part$q$ || :'pgmb_cancel_end', expect_error => '57014');

call pgmb.reg('cancel.err_parallel_append_partition_division_by_zero', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
select sum(1 / (bucket - 7)) from g_part$q$ || :'pgmb_cancel_end', expect_error => '22012');

call pgmb.reg('cancel.err_parallel_partitionwise_aggregate_cancelled', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
set local enable_partitionwise_aggregate = on;
select bucket, count(cancel_if_safe(bucket = 7)) from g_part group by bucket$q$ || :'pgmb_cancel_end', expect_error => '57014');

-- every worker sorts its share: cancelled while loading, in memory and with
-- runs in temporary files
call pgmb.reg('cancel.err_parallel_sort_worker_cancelled_in_memory', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
set local work_mem = '64MB';
select id from g_narrow order by k_uniq, cancel_if_safe(id = :n_g_narrow / 2)$q$ || :'pgmb_cancel_end', expect_error => '57014');

call pgmb.reg('cancel.err_parallel_sort_worker_cancelled_external', '{errors,needs_data}', :'pgmb_cancel_worker' || $q$
set local work_mem = '64kB';
select id from g_narrow order by k_uniq, cancel_if_safe(id = :n_g_narrow / 2)$q$ || :'pgmb_cancel_end', expect_error => '57014');

-- the same failing statement with 0, 1, 2 and 4 workers: the same error
select format($f$call pgmb.reg('cancel.err_parallel_same_error_%s_workers', '{errors,needs_data}', %L, expect_error => '22012')$f$, w,
              format(E'begin;\nset local max_parallel_workers_per_gather = %s;\nset local min_parallel_table_scan_size = 0;\n'
                     'set local parallel_setup_cost = 0;\nset local parallel_tuple_cost = 0;\n'
                     'select sum(1 / (id - :n_g_narrow / 2)) from g_narrow;\ncommit;', w))
from unnest(array[0, 1, 2, 4]) w \gexec

-- statement_timeout while eight workers are being started
call pgmb.reg('cancel.timeout_5ms_parallel_8_workers_starting', '{perf}', $q$
begin;
set local max_parallel_workers_per_gather = 8;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
set local statement_timeout = '5ms';
do $do$
begin
    execute 'select count(*) from pgmb_data.g_narrow';
    perform pg_sleep(1);
exception when query_canceled then null;
end $do$;
commit;$q$);

call pgmb.reg('cancel.timeout_none_parallel_8_workers_starting', '{perf}', $q$
begin;
set local max_parallel_workers_per_gather = 8;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
do $do$
begin
    execute 'select count(*) from pgmb_data.g_narrow';
end $do$;
commit;$q$);
