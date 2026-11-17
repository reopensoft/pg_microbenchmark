-- Topic: cancel (part 4) - writes interrupted halfway: INSERT, INSERT ...
-- SELECT, ON CONFLICT, UPDATE, DELETE, MERGE; foreign key actions, deferred
-- constraints, triggers, partitions, indexes; CREATE TABLE AS, CREATE INDEX,
-- ANALYZE, REINDEX, CLUSTER; HOT and non-HOT updates and VACUUM afterwards.
--
-- The cancel comes from inside, as in cancel.sql: cancel_if(cond) in the
-- statement itself, or cancel_at(setting, value) in a trigger or an index
-- expression, which cancels when the value equals the setting. Each check
-- function interrupts several statements, catches the cancel and reports
-- what is left; the error tests run one of the statements on its own.
-- Not possible here: COPY FROM STDIN and COPY TO STDOUT (they need the
-- client), CREATE INDEX CONCURRENTLY and VACUUM (they cannot run inside a
-- function or a transaction), an error raised by COMMIT itself.

------------------------------------------------------------------------------
-- objects
------------------------------------------------------------------------------
call pgmb.reg_ddl('cancel.create_dml_objects', 'schema', $q$
create function cancel_at(setting text, v int) returns int language plpgsql as
$f$begin
    if current_setting(setting, true) = v::text then
        perform pgmb_data.cancel_now();
    end if;
    return v;
end$f$;
-- an index expression that cancels when pgmb.cancel_at equals its argument
create function cdml_key(v int) returns int language plpgsql immutable as
'begin return pgmb_data.cancel_at(''pgmb.cancel_at'', v); end';
create function cdml_before_trigger() returns trigger language plpgsql as
$f$begin
    perform pgmb_data.cancel_at('pgmb.cancel_at', coalesce(new.id, old.id));
    return coalesce(new, old);
end$f$;

-- 100 rows to update, delete and merge into
create table g_cdml (id int primary key, v int not null);
insert into g_cdml select n, 0 from generate_series(1, 100) n;
-- an empty target for inserts, with a trigger that can cancel row by row
create table g_cdml_target (id int primary key, v int not null);
create trigger g_cdml_target_before before insert on g_cdml_target
    for each row execute function cdml_before_trigger();
-- 100 keys for upserts
create table g_cdml_upsert (k int primary key, v int not null);
insert into g_cdml_upsert select n, 0 from generate_series(1, 100) n;
-- the key that every client upserts in the waiting test
create table g_cdml_upsert_wait (k int primary key);

-- foreign keys: 10 parents, 100 children deleted with their parent, 100 set
-- to NULL, and a chain of 10 rows each the parent of the next
create table g_cdml_fkp (id int primary key);
insert into g_cdml_fkp select n from generate_series(1, 10) n;
create table g_cdml_fk_cascade (id int primary key, parent_id int references g_cdml_fkp on delete cascade);
insert into g_cdml_fk_cascade select n, (n - 1) / 10 + 1 from generate_series(1, 100) n;
create table g_cdml_fk_setnull (id int primary key, parent_id int references g_cdml_fkp on delete set null);
insert into g_cdml_fk_setnull select n, (n - 1) / 10 + 1 from generate_series(1, 100) n;
create table g_cdml_fk_chain (id int primary key, parent_id int references g_cdml_fk_chain on delete cascade);
insert into g_cdml_fk_chain select n, nullif(n - 1, 0) from generate_series(1, 10) n;
create trigger g_cdml_fk_cascade_before before delete on g_cdml_fk_cascade
    for each row execute function cdml_before_trigger();
create trigger g_cdml_fk_setnull_before before update on g_cdml_fk_setnull
    for each row execute function cdml_before_trigger();
create trigger g_cdml_fk_chain_before before delete on g_cdml_fk_chain
    for each row execute function cdml_before_trigger();
-- a foreign key checked only when asked to
create table g_cdml_fk_deferred (id int primary key,
    parent_id int references g_cdml_fkp deferrable initially deferred);

-- triggers: a BEFORE row trigger, an AFTER row trigger that writes to a
-- second table (whose own trigger can cancel), and an AFTER statement trigger
-- that reads its transition table
create table g_cdml_trg_a (id int primary key);
create table g_cdml_trg_b (id int primary key);
create function cdml_trg_a_before() returns trigger language plpgsql as
$f$begin perform pgmb_data.cancel_at('pgmb.cancel_a_before', new.id); return new; end$f$;
create function cdml_trg_a_after() returns trigger language plpgsql as
$f$begin insert into pgmb_data.g_cdml_trg_b values (new.id); return null; end$f$;
create function cdml_trg_b_before() returns trigger language plpgsql as
$f$begin perform pgmb_data.cancel_at('pgmb.cancel_b_before', new.id); return new; end$f$;
create function cdml_trg_a_statement() returns trigger language plpgsql as
$f$begin perform pgmb_data.cancel_at('pgmb.cancel_statement', (select count(*) from new_rows)::int); return null; end$f$;
create trigger g_cdml_trg_a_before before insert on g_cdml_trg_a for each row execute function cdml_trg_a_before();
create trigger g_cdml_trg_a_after after insert on g_cdml_trg_a for each row execute function cdml_trg_a_after();
create trigger g_cdml_trg_b_before before insert on g_cdml_trg_b for each row execute function cdml_trg_b_before();
create trigger g_cdml_trg_a_statement after insert on g_cdml_trg_a referencing new table as new_rows
    for each statement execute function cdml_trg_a_statement();

-- a table in two partitions; all 100 rows start in the first
create table g_cdml_part (id int not null, p int not null) partition by range (p);
create table g_cdml_part_0 partition of g_cdml_part for values from (0) to (10);
create table g_cdml_part_1 partition of g_cdml_part for values from (10) to (20);
insert into g_cdml_part select n, n % 10 from generate_series(1, 100) n;

-- a table with btree, GIN, GiST and expression indexes; rows 1 to 100
create table g_cdml_idx (id int primary key, v int not null, a int[] not null, r int4range not null);
insert into g_cdml_idx select n, n, array[n], int4range(n, n + 1) from generate_series(1, 100) n;
create index g_cdml_idx_v on g_cdml_idx (v);
create index g_cdml_idx_a on g_cdml_idx using gin (a);
create index g_cdml_idx_r on g_cdml_idx using gist (r);
create index g_cdml_idx_key on g_cdml_idx (cdml_key(v));
analyze g_cdml_idx$q$);

------------------------------------------------------------------------------
-- check functions
------------------------------------------------------------------------------
call pgmb.reg_ddl('cancel.create_dml_check_functions', 'schema', $q$
-- four inserts of 100 rows, each cancelled on its 50th row: a multi-row
-- VALUES list, INSERT ... SELECT cancelled in the source, in the select list,
-- and in a BEFORE trigger of the target
create function cdml_insert_facts() returns text language plpgsql as
$f$declare
    vals text;
    caught int := 0;
begin
    select string_agg(format('(%s, %s)', n, case when n = 50 then 'pgmb_data.cancel_now()' else '0' end), ', ' order by n)
    into vals from generate_series(1, 100) n;
    begin
        execute 'insert into pgmb_data.g_cdml_target values ' || vals;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        insert into pgmb_data.g_cdml_target select n, 0 from generate_series(1, 100) n where pgmb_data.cancel_if(n = 50) = 1;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        insert into pgmb_data.g_cdml_target select n, pgmb_data.cancel_if(n = 50) from generate_series(1, 100) n;
    exception when query_canceled then caught := caught + 1;
    end;
    perform set_config('pgmb.cancel_at', '50', true);
    begin
        insert into pgmb_data.g_cdml_target select n, 0 from generate_series(1, 100) n;
    exception when query_canceled then caught := caught + 1;
    end;
    perform set_config('pgmb.cancel_at', '', true);
    return format('%s inserts cancelled, rows left %s', caught, (select count(*) from pgmb_data.g_cdml_target));
end$f$;

-- ON CONFLICT cancelled while new keys are inserted, while existing keys are
-- updated, and in the WHERE clause of DO UPDATE
create function cdml_upsert_facts() returns text language plpgsql as
$f$declare
    caught int := 0;
begin
    begin
        insert into pgmb_data.g_cdml_upsert select n, pgmb_data.cancel_if(n = 150) from generate_series(101, 200) n
        on conflict do nothing;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        insert into pgmb_data.g_cdml_upsert as u select n, 0 from generate_series(1, 100) n
        on conflict (k) do update set v = u.v + 1 + pgmb_data.cancel_if(excluded.k = 50);
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        insert into pgmb_data.g_cdml_upsert as u select n, 0 from generate_series(1, 100) n
        on conflict (k) do update set v = u.v + 1 where pgmb_data.cancel_if(u.k = 50) = 1;
    exception when query_canceled then caught := caught + 1;
    end;
    return format('%s upserts cancelled, rows %s, sum %s', caught,
                  (select count(*) from pgmb_data.g_cdml_upsert), (select sum(v) from pgmb_data.g_cdml_upsert));
end$f$;

-- an UPDATE cancelled on its 50th row: every row keeps its value and its
-- place, because the versions it wrote belong to an aborted subtransaction
create function cdml_update_facts() returns text language plpgsql as
$f$declare
    before_ctids text;
begin
    select string_agg(ctid::text, ',' order by id) into before_ctids from pgmb_data.g_cdml;
    begin
        update pgmb_data.g_cdml set v = v + 1 + pgmb_data.cancel_if(id = 50);
    exception when query_canceled then null;
    end;
    return format('rows keep their place: %s, sum %s',
                  before_ctids = (select string_agg(ctid::text, ',' order by id) from pgmb_data.g_cdml),
                  (select sum(v) from pgmb_data.g_cdml));
end$f$;

-- a DELETE cancelled while it scans, and after it has marked rows (in RETURNING)
create function cdml_delete_facts() returns text language plpgsql as
$f$declare
    caught int := 0;
begin
    begin
        delete from pgmb_data.g_cdml where pgmb_data.cancel_if(id = 50) = 1;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        execute 'delete from pgmb_data.g_cdml returning pgmb_data.cancel_if(id = 50)';
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        execute 'with d as (delete from pgmb_data.g_cdml returning id) select count(pgmb_data.cancel_if(id = 50)) from d';
    exception when query_canceled then caught := caught + 1;
    end;
    return format('%s deletes cancelled, rows left %s', caught, (select count(*) from pgmb_data.g_cdml));
end$f$;

-- MERGE of keys 51 to 150 into rows 1 to 100, cancelled in each action and
-- in a WHEN condition
create function cdml_merge_facts() returns text language plpgsql as
$f$declare
    caught int := 0;
begin
    begin
        merge into pgmb_data.g_cdml t using generate_series(51, 150) s(n) on t.id = s.n
        when matched then update set v = t.v + 1 + pgmb_data.cancel_if(t.id = 75)
        when not matched then insert values (s.n, 0);
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        merge into pgmb_data.g_cdml t using generate_series(51, 150) s(n) on t.id = s.n
        when matched then delete
        when not matched then insert values (s.n, pgmb_data.cancel_if(s.n = 125));
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        merge into pgmb_data.g_cdml t using generate_series(51, 150) s(n) on t.id = s.n
        when matched and pgmb_data.cancel_if(t.id = 75) = 1 then delete;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        merge into pgmb_data.g_cdml t using generate_series(51, 150) s(n) on t.id = s.n
        when not matched by source then update set v = t.v + 1 + pgmb_data.cancel_if(t.id = 25);
    exception when query_canceled then caught := caught + 1;
    end;
    return format('%s merges cancelled, rows %s, sum %s', caught,
                  (select count(*) from pgmb_data.g_cdml), (select sum(v) from pgmb_data.g_cdml));
end$f$;

-- foreign key actions cancelled in the middle: a cascading delete, a SET NULL,
-- and a cascade down a chain of ten rows (cancelled at the seventh)
create function cdml_fk_facts() returns text language plpgsql as
$f$declare
    caught int := 0;
begin
    perform set_config('pgmb.cancel_at', '15', true);
    begin
        delete from pgmb_data.g_cdml_fkp where id <= 5;
    exception when query_canceled then caught := caught + 1;
    end;
    perform set_config('pgmb.cancel_at', '7', true);
    begin
        delete from pgmb_data.g_cdml_fk_chain where id = 1;
    exception when query_canceled then caught := caught + 1;
    end;
    perform set_config('pgmb.cancel_at', '', true);
    return format('%s cancelled, parents %s, cascade children %s, set null children with a parent %s, chain %s', caught,
                  (select count(*) from pgmb_data.g_cdml_fkp), (select count(*) from pgmb_data.g_cdml_fk_cascade),
                  (select count(parent_id) from pgmb_data.g_cdml_fk_setnull), (select count(*) from pgmb_data.g_cdml_fk_chain));
end$f$;

-- a deferred foreign key: the insert is accepted, SET CONSTRAINTS raises
create function cdml_deferred_facts() returns text language plpgsql as
$f$declare
    accepted boolean := false;
    state text;
begin
    begin
        insert into pgmb_data.g_cdml_fk_deferred values (1, 999);
        accepted := true;
        set constraints all immediate;
        state := 'no error';
    exception when others then
        state := sqlstate;
    end;
    return format('insert accepted: %s, SET CONSTRAINTS raised %s, rows %s',
                  accepted, state, (select count(*) from pgmb_data.g_cdml_fk_deferred));
end$f$;

-- ten rows inserted into g_cdml_trg_a, cancelled in its BEFORE trigger, in the
-- BEFORE trigger of the table its AFTER trigger writes to, and in its
-- statement trigger
create function cdml_trigger_facts() returns text language plpgsql as
$f$declare
    caught int := 0;
    s text;
begin
    foreach s in array array['pgmb.cancel_a_before', 'pgmb.cancel_b_before', 'pgmb.cancel_statement'] loop
        perform set_config(s, case s when 'pgmb.cancel_statement' then '10' else '5' end, true);
        begin
            insert into pgmb_data.g_cdml_trg_a select n from generate_series(1, 10) n;
        exception when query_canceled then caught := caught + 1;
        end;
        perform set_config(s, '', true);
    end loop;
    return format('%s cancelled, rows in a %s, rows in b %s', caught,
                  (select count(*) from pgmb_data.g_cdml_trg_a), (select count(*) from pgmb_data.g_cdml_trg_b));
end$f$;

-- an insert routed to both partitions and an update that moves rows from the
-- first partition to the second, both cancelled halfway
create function cdml_partition_facts() returns text language plpgsql as
$f$declare
    caught int := 0;
begin
    begin
        insert into pgmb_data.g_cdml_part select 100 + n, n % 20 + pgmb_data.cancel_if(n = 50) - 1
        from generate_series(1, 100) n;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        update pgmb_data.g_cdml_part set p = p + 10 + pgmb_data.cancel_if(id = 50) - 1;
    exception when query_canceled then caught := caught + 1;
    end;
    return format('%s cancelled, first partition %s, second partition %s', caught,
                  (select count(*) from pgmb_data.g_cdml_part_0), (select count(*) from pgmb_data.g_cdml_part_1));
end$f$;

-- an insert cancelled while the expression index is updated for its 50th
-- row, then one that works: every index finds the same 20 new rows as the table
create function cdml_index_facts() returns text language plpgsql as
$f$declare
    n_btree bigint; n_gin bigint; n_gist bigint; n_expr bigint; n_table bigint;
begin
    perform set_config('pgmb.cancel_at', '1050', true);
    begin
        insert into pgmb_data.g_cdml_idx select n, n, array[n], int4range(n, n + 1) from generate_series(1001, 1100) n;
    exception when query_canceled then null;
    end;
    perform set_config('pgmb.cancel_at', '', true);
    insert into pgmb_data.g_cdml_idx select n, n, array[n], int4range(n, n + 1) from generate_series(1101, 1120) n;
    perform set_config('enable_seqscan', 'off', true);
    execute 'select count(*) from pgmb_data.g_cdml_idx where v > 1000' into n_btree;
    execute 'select count(*) from pgmb_data.g_cdml_idx where a && (select array_agg(g) from generate_series(1001, 2000) g)' into n_gin;
    execute 'select count(*) from pgmb_data.g_cdml_idx where r && int4range(1001, 3000)' into n_gist;
    execute 'select count(*) from pgmb_data.g_cdml_idx where pgmb_data.cdml_key(v) > 1000' into n_expr;
    perform set_config('enable_seqscan', 'on', true);
    perform set_config('enable_indexscan', 'off', true);
    perform set_config('enable_bitmapscan', 'off', true);
    execute 'select count(*) from pgmb_data.g_cdml_idx where v > 1000' into n_table;
    perform set_config('enable_indexscan', 'on', true);
    perform set_config('enable_bitmapscan', 'on', true);
    return format('btree %s, gin %s, gist %s, expression %s, table %s', n_btree, n_gin, n_gist, n_expr, n_table);
end$f$;

-- relations and indexes that are being built when the cancel comes are gone
-- afterwards; ANALYZE, REINDEX and CLUSTER cancelled while they evaluate the
-- index expression leave the table as it was
create function cdml_build_facts() returns text language plpgsql as
$f$declare
    caught int := 0;
begin
    begin
        create table pgmb_data.g_cdml_ctas as select n, pgmb_data.cancel_if(n = 5000) as x from generate_series(1, 10000) n;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        create materialized view pgmb_data.g_cdml_matview as
            select n, pgmb_data.cancel_if(n = 5000) as x from generate_series(1, 10000) n;
    exception when query_canceled then caught := caught + 1;
    end;
    perform set_config('pgmb.cancel_at', '50', true);
    begin
        create index g_cdml_idx_key2 on pgmb_data.g_cdml_idx (pgmb_data.cdml_key(v), id);
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        analyze pgmb_data.g_cdml_idx;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        reindex index pgmb_data.g_cdml_idx_key;
    exception when query_canceled then caught := caught + 1;
    end;
    begin
        cluster pgmb_data.g_cdml_idx using g_cdml_idx_pkey;
    exception when query_canceled then caught := caught + 1;
    end;
    perform set_config('pgmb.cancel_at', '', true);
    return format('%s cancelled, left behind: %s, rows %s', caught,
                  coalesce((select string_agg(c, ',') from unnest(array['pgmb_data.g_cdml_ctas', 'pgmb_data.g_cdml_matview',
                                                                        'pgmb_data.g_cdml_idx_key2']) c
                            where to_regclass(c) is not null), 'nothing'),
                  (select count(*) from pgmb_data.g_cdml_idx));
end$f$$q$);

------------------------------------------------------------------------------
-- what is left
------------------------------------------------------------------------------
call pgmb.reg('cancel.dml_insert_cancelled', '{consistency}', $q$select cdml_insert_facts()$q$, equiv => 'cancel.dml_insert');
call pgmb.reg('cancel.dml_insert_cancelled_expected', '{consistency}',
    $q$select '4 inserts cancelled, rows left 0'::text$q$, equiv => 'cancel.dml_insert');
call pgmb.reg('cancel.dml_upsert_cancelled', '{consistency}', $q$select cdml_upsert_facts()$q$, equiv => 'cancel.dml_upsert');
call pgmb.reg('cancel.dml_upsert_cancelled_expected', '{consistency}',
    $q$select '3 upserts cancelled, rows 100, sum 0'::text$q$, equiv => 'cancel.dml_upsert');
call pgmb.reg('cancel.dml_update_cancelled', '{consistency}', $q$select cdml_update_facts()$q$, equiv => 'cancel.dml_update');
call pgmb.reg('cancel.dml_update_cancelled_expected', '{consistency}',
    $q$select 'rows keep their place: t, sum 0'::text$q$, equiv => 'cancel.dml_update');
call pgmb.reg('cancel.dml_delete_cancelled', '{consistency}', $q$select cdml_delete_facts()$q$, equiv => 'cancel.dml_delete');
call pgmb.reg('cancel.dml_delete_cancelled_expected', '{consistency}',
    $q$select '3 deletes cancelled, rows left 100'::text$q$, equiv => 'cancel.dml_delete');
call pgmb.reg('cancel.dml_merge_cancelled', '{consistency}', $q$select cdml_merge_facts()$q$, equiv => 'cancel.dml_merge');
call pgmb.reg('cancel.dml_merge_cancelled_expected', '{consistency}',
    $q$select '4 merges cancelled, rows 100, sum 0'::text$q$, equiv => 'cancel.dml_merge');
call pgmb.reg('cancel.dml_fk_actions_cancelled', '{consistency}', $q$select cdml_fk_facts()$q$, equiv => 'cancel.dml_fk');
call pgmb.reg('cancel.dml_fk_actions_cancelled_expected', '{consistency}', $q$
select '2 cancelled, parents 10, cascade children 100, set null children with a parent 100, chain 10'::text$q$,
    equiv => 'cancel.dml_fk');
call pgmb.reg('cancel.dml_deferred_constraint', '{consistency}', $q$select cdml_deferred_facts()$q$, equiv => 'cancel.dml_deferred');
call pgmb.reg('cancel.dml_deferred_constraint_expected', '{consistency}',
    $q$select 'insert accepted: t, SET CONSTRAINTS raised 23503, rows 0'::text$q$, equiv => 'cancel.dml_deferred');
call pgmb.reg('cancel.dml_triggers_cancelled', '{consistency}', $q$select cdml_trigger_facts()$q$, equiv => 'cancel.dml_triggers');
call pgmb.reg('cancel.dml_triggers_cancelled_expected', '{consistency}',
    $q$select '3 cancelled, rows in a 0, rows in b 0'::text$q$, equiv => 'cancel.dml_triggers');
call pgmb.reg('cancel.dml_partitions_cancelled', '{consistency}', $q$select cdml_partition_facts()$q$, equiv => 'cancel.dml_partitions');
call pgmb.reg('cancel.dml_partitions_cancelled_expected', '{consistency}',
    $q$select '2 cancelled, first partition 100, second partition 0'::text$q$, equiv => 'cancel.dml_partitions');
call pgmb.reg('cancel.dml_indexes_after_cancel', '{consistency}', $q$select cdml_index_facts()$q$, equiv => 'cancel.dml_indexes');
call pgmb.reg('cancel.dml_indexes_after_cancel_expected', '{consistency}',
    $q$select 'btree 20, gin 20, gist 20, expression 20, table 20'::text$q$, equiv => 'cancel.dml_indexes');
call pgmb.reg('cancel.dml_builds_cancelled', '{consistency}', $q$select cdml_build_facts()$q$, equiv => 'cancel.dml_builds');
call pgmb.reg('cancel.dml_builds_cancelled_expected', '{consistency}',
    $q$select '6 cancelled, left behind: nothing, rows 100'::text$q$, equiv => 'cancel.dml_builds');

------------------------------------------------------------------------------
-- each interruption on its own: the statement must end with 57014 (commands
-- that the checks cannot run after a SET LOCAL are wrapped in a DO block)
------------------------------------------------------------------------------
call pgmb.reg('cancel.err_dml_insert_select_source', '{errors}',
    $q$insert into g_cdml_target select n, 0 from generate_series(1, 100) n where cancel_if(n = 50) = 1$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_insert_select_transform', '{errors}',
    $q$insert into g_cdml_target select n, cancel_if(n = 50) from generate_series(1, 100) n$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_insert_before_trigger', '{errors}', $q$
begin;
set local pgmb.cancel_at = '50';
insert into g_cdml_target select n, 0 from generate_series(1, 100) n;
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_upsert_new_keys', '{errors}', $q$
insert into g_cdml_upsert select n, cancel_if(n = 150) from generate_series(101, 200) n on conflict do nothing$q$,
    expect_error => '57014');
call pgmb.reg('cancel.err_dml_upsert_do_update', '{errors}', $q$
insert into g_cdml_upsert as u select n, 0 from generate_series(1, 100) n
on conflict (k) do update set v = u.v + 1 + cancel_if(excluded.k = 50)$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_upsert_do_update_where', '{errors}', $q$
insert into g_cdml_upsert as u select n, 0 from generate_series(1, 100) n
on conflict (k) do update set v = u.v + 1 where cancel_if(u.k = 50) = 1$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_update_halfway', '{errors}',
    $q$update g_cdml set v = v + 1 + cancel_if(id = 50)$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_delete_while_scanning', '{errors}',
    $q$delete from g_cdml where cancel_if(id = 50) = 1$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_merge_update_action', '{errors}', $q$
merge into g_cdml t using generate_series(51, 150) s(n) on t.id = s.n
when matched then update set v = t.v + 1 + cancel_if(t.id = 75)
when not matched then insert values (s.n, 0)$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_merge_insert_action', '{errors}', $q$
merge into g_cdml t using generate_series(51, 150) s(n) on t.id = s.n
when not matched then insert values (s.n, cancel_if(s.n = 125))$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_merge_when_condition', '{errors}', $q$
merge into g_cdml t using generate_series(51, 150) s(n) on t.id = s.n
when matched and cancel_if(t.id = 75) = 1 then delete$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_fk_cascade', '{errors}', $q$
begin;
set local pgmb.cancel_at = '15';
delete from g_cdml_fkp where id <= 5;
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_fk_cascade_chain', '{errors}', $q$
begin;
set local pgmb.cancel_at = '7';
delete from g_cdml_fk_chain where id = 1;
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_deferred_fk_at_set_constraints', '{errors}', $q$
do $do$
begin
    insert into pgmb_data.g_cdml_fk_deferred values (1, 999);
    set constraints all immediate;
end $do$$q$, expect_error => '23503');
call pgmb.reg('cancel.err_dml_trigger_chain', '{errors}', $q$
begin;
set local pgmb.cancel_b_before = '5';
insert into g_cdml_trg_a select n from generate_series(1, 10) n;
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_trigger_transition_table', '{errors}', $q$
begin;
set local pgmb.cancel_statement = '10';
insert into g_cdml_trg_a select n from generate_series(1, 10) n;
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_partition_row_movement', '{errors}',
    $q$update g_cdml_part set p = p + 10 + cancel_if(id = 50) - 1$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_index_expression_insert', '{errors}', $q$
begin;
set local pgmb.cancel_at = '1050';
insert into g_cdml_idx select n, n, array[n], int4range(n, n + 1) from generate_series(1001, 1100) n;
commit;$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_create_table_as', '{errors}',
    $q$create table g_cdml_ctas_e as select n, cancel_if(n = 5000) as x from generate_series(1, 10000) n$q$,
    expect_error => '57014');
call pgmb.reg('cancel.err_dml_create_index', '{errors}', $q$
do $do$
begin
    perform set_config('pgmb.cancel_at', '50', true);
    create index g_cdml_idx_key_e on pgmb_data.g_cdml_idx (pgmb_data.cdml_key(v), id);
end $do$$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_create_unique_index_duplicates', '{errors}',
    $q$create unique index g_cdml_part_0_p_u on g_cdml_part_0 (p)$q$, expect_error => '23505');
call pgmb.reg('cancel.err_dml_analyze', '{errors}', $q$
do $do$
begin
    perform set_config('pgmb.cancel_at', '50', true);
    analyze pgmb_data.g_cdml_idx;
end $do$$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_reindex', '{errors}', $q$
do $do$
begin
    perform set_config('pgmb.cancel_at', '50', true);
    reindex index pgmb_data.g_cdml_idx_key;
end $do$$q$, expect_error => '57014');
call pgmb.reg('cancel.err_dml_cluster', '{errors}', $q$
do $do$
begin
    perform set_config('pgmb.cancel_at', '50', true);
    cluster pgmb_data.g_cdml_idx using g_cdml_idx_pkey;
end $do$$q$, expect_error => '57014');

------------------------------------------------------------------------------
-- HOT and non-HOT updates cancelled halfway, then VACUUM (DDL phase)
------------------------------------------------------------------------------
-- 10,000 rows with room on every page. An update of the unindexed column can
-- stay on the page (HOT), one of the indexed column cannot. Each is cancelled
-- halfway; the versions it wrote stay on disk until VACUUM. Every step is
-- recorded with its time, WAL and the size of the table afterwards.
call pgmb.reg_ddl('cancel.create_g_cdml_hot', 'schema', $q$
create table g_cdml_hot (id int primary key, v int not null, w int not null) with (fillfactor = 50);
insert into g_cdml_hot select n, 0, n from generate_series(1, 10000) n;
create index g_cdml_hot_w on g_cdml_hot (w)$q$, target => 'g_cdml_hot');
call pgmb.reg_ddl('cancel.hot_1_update_cancelled', 'maintenance', $q$
do $do$
begin
    update pgmb_data.g_cdml_hot set v = v + 1 + pgmb_data.cancel_if(id = 5000);
exception when query_canceled then null;
end $do$$q$, target => 'g_cdml_hot');
call pgmb.reg_ddl('cancel.hot_2_non_hot_update_cancelled', 'maintenance', $q$
do $do$
begin
    update pgmb_data.g_cdml_hot set w = w + 100000 + pgmb_data.cancel_if(id = 5000);
exception when query_canceled then null;
end $do$$q$, target => 'g_cdml_hot');
call pgmb.reg_ddl('cancel.hot_3_vacuum', 'maintenance', $q$vacuum (analyze) g_cdml_hot$q$, target => 'g_cdml_hot');

-- nothing of the cancelled updates is visible, through the table or the index
call pgmb.reg('cancel.hot_after_cancel_and_vacuum_table', '{consistency}', $q$
select count(*), sum(v), sum(w) from g_cdml_hot$q$, equiv => 'cancel.hot');
call pgmb.reg('cancel.hot_after_cancel_and_vacuum_index', '{consistency}', $q$
begin;
set local enable_seqscan = off;
set local enable_bitmapscan = off;
select count(*), sum(v), sum(w) from g_cdml_hot where w > 0;
commit;$q$, equiv => 'cancel.hot');
call pgmb.reg('cancel.hot_after_cancel_and_vacuum_expected', '{consistency}',
    $q$select 10000::bigint, 0::bigint, 50005000::bigint$q$, equiv => 'cancel.hot');

------------------------------------------------------------------------------
-- ON CONFLICT waiting for another backend's insert (several clients)
------------------------------------------------------------------------------
-- Every client upserts key 1. The first one inserts it and keeps it
-- uncommitted for 150 ms; the others wait for its transaction and are
-- cancelled by a 100 ms statement_timeout. The insert and the wait for the
-- timeout are in separate blocks, so that the client that inserted keeps its
-- row; the second block sleeps only until the timeout has surely fired.
call pgmb.reg('cancel.timeout_100ms_upsert_waiting_for_other_insert', '{perf,locking,concurrency}', $q$
begin;
set local statement_timeout = '100ms';
do $do$
begin
    begin
        insert into pgmb_data.g_cdml_upsert_wait values (1) on conflict do nothing;
    exception when query_canceled then null;
    end;
    begin
        perform pg_sleep(greatest(0, 0.2 - extract(epoch from clock_timestamp() - statement_timestamp())));
    exception when query_canceled then null;
    end;
    perform set_config('statement_timeout', '0', true);
end $do$;
select pg_sleep(0.15);
delete from g_cdml_upsert_wait where k = 1;
commit;$q$, kind => 'write');
