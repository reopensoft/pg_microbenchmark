-- Topic: storage - row versions, subtransactions, advisory locks and deadlocks,
-- foreign key actions, triggers, TOAST, bloat and VACUUM, WAL of logged,
-- unlogged and temporary tables, sequences.
--
-- Writes go to small tables of their own. Where clients would block each
-- other without that being the point, every client works on its own rows
-- (:client_id). Facts that can be stated in one value are checked by a
-- function next to the value it must return (consistency groups).

insert into pgmb.dataset (name, base_rows, exponent, min_rows) values
    ('g_bloat', 200000, 1, 1000),   -- rewritten, vacuumed and reindexed in the DDL phase
    ('g_load',  200000, 1, 1000);   -- the same load into a logged and an unlogged table

call pgmb.reg_ddl('storage.create_g_store', 'schema', $q$
create table g_store (id int primary key, v bigint not null, pad text not null) with (fillfactor = 50);
insert into g_store select n, 0, repeat('x', 40) from generate_series(1, 105000) n$q$);

call pgmb.reg('storage.expected_true', '{consistency}', $q$select true$q$, equiv => 'storage.true');

------------------------------------------------------------------------------
-- MVCC: row versions inside one transaction
------------------------------------------------------------------------------
call pgmb.reg_ddl('storage.create_mvcc_functions', 'schema', $q$
create function storage_mvcc_facts() returns text language plpgsql as
$f$declare
    seen boolean; p0 float8; p1 float8; v_after bigint;
begin
    insert into pgmb_data.g_store values (-1, 0, 'x');
    seen := exists (select from pgmb_data.g_store where id = -1);
    p0 := (select (ctid::text::point)[0] from pgmb_data.g_store where id = -1);
    update pgmb_data.g_store set v = 1 where id = -1;
    p1 := (select (ctid::text::point)[0] from pgmb_data.g_store where id = -1);
    begin
        update pgmb_data.g_store set v = 2 where id = -1;
        perform 1 / 0;
    exception when division_by_zero then null;
    end;
    v_after := (select v from pgmb_data.g_store where id = -1);
    return format('own insert visible: %s, update stays on the page: %s, failed block undone: %s, versions visible: %s',
                  seen, p0 = p1, v_after = 1, (select count(*) from pgmb_data.g_store where id = -1));
end$f$$q$);

call pgmb.reg('storage.mvcc_facts', '{consistency}', $q$select storage_mvcc_facts()$q$, equiv => 'storage.mvcc');
call pgmb.reg('storage.mvcc_facts_expected', '{consistency}', $q$
select 'own insert visible: t, update stays on the page: t, failed block undone: t, versions visible: 1'::text$q$,
    equiv => 'storage.mvcc');

-- one row updated 20 times in one transaction: a chain of versions on one page
select 'begin;' || E'\n' || string_agg('update g_store set v = v + 1 where id = :client_id + 1;', E'\n') || E'\ncommit;' as pgmb_upd20
from generate_series(1, 20) \gset
call pgmb.reg('storage.mvcc_update_same_row_20_times', '{perf,oltp}', :'pgmb_upd20', kind => 'write');
call pgmb.reg('storage.mvcc_update_same_row_once', '{perf,oltp}',
    $q$update g_store set v = v + 1 where id = :client_id + 1$q$, kind => 'write');

-- 100 rows updated and read back, then everything is rolled back: the next
-- transaction finds the dead versions in its way
call pgmb.reg('storage.mvcc_scan_after_rolled_back_updates', '{perf}', $q$
begin;
update g_store set v = v + 1 where id between :lo and :lo + 99;
select count(*), sum(v) from g_store where id between :lo and :lo + 99;
rollback;$q$, kind => 'write', setup => '\set lo 2000 + :client_id * 100');
call pgmb.reg('storage.mvcc_scan_after_committed_updates', '{perf}', $q$
begin;
update g_store set v = v + 1 where id between :lo and :lo + 99;
select count(*), sum(v) from g_store where id between :lo and :lo + 99;
commit;$q$, kind => 'write', setup => '\set lo 2000 + :client_id * 100');

------------------------------------------------------------------------------
-- SAVEPOINT
------------------------------------------------------------------------------
call pgmb.reg('storage.savepoint_none', '{perf,oltp}', $q$
begin;
update g_store set v = v + 1 where id = :client_id + 1;
commit;$q$, kind => 'write');

call pgmb.reg('storage.savepoint_one_released', '{perf,oltp}', $q$
begin;
savepoint s;
update g_store set v = v + 1 where id = :client_id + 1;
release savepoint s;
commit;$q$, kind => 'write');

call pgmb.reg('storage.savepoint_one_rolled_back', '{perf,oltp}', $q$
begin;
savepoint s;
update g_store set v = v + 1 where id = :client_id + 1;
rollback to savepoint s;
update g_store set v = v + 1 where id = :client_id + 1;
commit;$q$, kind => 'write');

-- ten savepoints inside each other, a write in each
select 'begin;' || E'\n'
       || string_agg(format(E'savepoint s%s;\nupdate g_store set v = v + 1 where id = :client_id + 1;', i), E'\n' order by i)
       || E'\ncommit;' as pgmb_sp_nested
from generate_series(1, 10) i \gset
call pgmb.reg('storage.savepoint_10_nested', '{perf}', :'pgmb_sp_nested', kind => 'write');

-- 100 savepoints one after another, a write in each: more subtransactions
-- than a backend keeps in its own cache (64)
select 'begin;' || E'\n'
       || string_agg(E'savepoint s;\nupdate g_store set v = v + 1 where id = :client_id + 1;\nrelease savepoint s;', E'\n')
       || E'\ncommit;' as pgmb_sp_100
from generate_series(1, 100) \gset
call pgmb.reg('storage.savepoint_100_in_sequence', '{perf}', :'pgmb_sp_100', kind => 'write');

-- 100 savepoints without a write: no transaction id is assigned to them
select 'begin;' || E'\n' || string_agg(E'savepoint s;\nrelease savepoint s;', E'\n') || E'\ncommit;' as pgmb_sp_100_ro
from generate_series(1, 100) \gset
call pgmb.reg('storage.savepoint_100_in_sequence_read_only', '{perf}', :'pgmb_sp_100_ro');

-- nested blocks: only the block that failed is undone
call pgmb.reg_ddl('storage.create_savepoint_functions', 'schema', $q$
create function storage_savepoint_facts() returns text language plpgsql as
$f$begin
    insert into pgmb_data.g_store values (-2, 0, 'outer');
    begin
        insert into pgmb_data.g_store values (-3, 0, 'middle');
        begin
            insert into pgmb_data.g_store values (-4, 0, 'inner');
            perform 1 / 0;
        exception when division_by_zero then null;
        end;
    end;
    return (select string_agg(pad, ',' order by id desc) from pgmb_data.g_store where id in (-2, -3, -4));
end$f$$q$);
call pgmb.reg('storage.savepoint_only_failed_block_undone', '{consistency}',
    $q$select storage_savepoint_facts()$q$, equiv => 'storage.savepoint');
call pgmb.reg('storage.savepoint_only_failed_block_undone_expected', '{consistency}',
    $q$select 'outer,middle'::text$q$, equiv => 'storage.savepoint');

------------------------------------------------------------------------------
-- advisory locks
------------------------------------------------------------------------------
call pgmb.reg('storage.advisory_xact_lock_own_key', '{perf,locking,oltp}',
    $q$select pg_advisory_xact_lock(7300000 + :client_id)$q$);
-- every client wants the same key: they queue
call pgmb.reg('storage.advisory_xact_lock_same_key', '{perf,locking,concurrency,oltp}',
    $q$select pg_advisory_xact_lock(7299999)$q$);
call pgmb.reg('storage.advisory_xact_lock_shared_mode', '{perf,locking,concurrency,oltp}',
    $q$select pg_advisory_xact_lock_shared(7299998)$q$);
-- no waiting: whoever does not get the lock gets "false"
call pgmb.reg('storage.advisory_try_lock_same_key', '{perf,locking,concurrency,oltp}',
    $q$select pg_try_advisory_xact_lock(7299997)$q$);
-- session level: taken and released by hand
call pgmb.reg('storage.advisory_session_lock_and_unlock', '{perf,locking,oltp}', $q$
select pg_advisory_lock(7400000 + :client_id);
select pg_advisory_unlock(7400000 + :client_id);$q$);

------------------------------------------------------------------------------
-- deadlock
------------------------------------------------------------------------------
-- Clients with an even number lock row 1 and then row 2, the others the other
-- way round. With two or more clients they deadlock; the victim is chosen
-- after deadlock_timeout (1 s by default) and pgbench retries it. Opt-in,
-- because the clients spend their time waiting for that timeout.
call pgmb.reg_ddl('storage.create_g_deadlock', 'schema', $q$
create table g_deadlock (id int primary key, v bigint not null);
insert into g_deadlock values (1, 0), (2, 0)$q$);

call pgmb.reg('storage.deadlock_two_rows_opposite_order', '{perf,locking,concurrency,optin_deadlock}', $q$
begin;
update g_deadlock set v = v + 1 where id = :a;
select pg_sleep(0.01);
update g_deadlock set v = v + 1 where id = :b;
commit;$q$, kind => 'write', setup => E'\\set a 1 + :client_id % 2\n\\set b 2 - :client_id % 2');

call pgmb.reg('storage.deadlock_two_rows_same_order', '{perf,locking,concurrency,optin_deadlock}', $q$
begin;
update g_deadlock set v = v + 1 where id = 1;
select pg_sleep(0.01);
update g_deadlock set v = v + 1 where id = 2;
commit;$q$, kind => 'write');

------------------------------------------------------------------------------
-- foreign key actions
------------------------------------------------------------------------------
call pgmb.reg_ddl('storage.create_fk_tables', 'schema', $q$
create table g_fk_parent (id bigint primary key);
create table g_fk_cascade (id bigserial primary key, parent_id bigint references g_fk_parent on delete cascade);
create index g_fk_cascade_parent on g_fk_cascade (parent_id);
create table g_fk_setnull (id bigserial primary key, client int not null,
                           parent_id bigint references g_fk_parent on delete set null);
create index g_fk_setnull_parent on g_fk_setnull (parent_id);
create index g_fk_setnull_client on g_fk_setnull (client);
create table g_fk_plain (id bigserial primary key, parent_id bigint references g_fk_parent);
create index g_fk_plain_parent on g_fk_plain (parent_id);
create table g_fk_tree (id bigint primary key, parent_id bigint references g_fk_tree on delete cascade);
create index g_fk_tree_parent on g_fk_tree (parent_id)$q$);

-- a parent with ten children is created and deleted again
call pgmb.reg('storage.fk_delete_parent_cascade_10', '{perf,oltp}', $q$
begin;
insert into g_fk_parent values (:client_id + 1);
insert into g_fk_cascade (parent_id) select :client_id + 1 from generate_series(1, 10);
delete from g_fk_parent where id = :client_id + 1;
commit;$q$, kind => 'write');

call pgmb.reg('storage.fk_delete_parent_set_null_10', '{perf,oltp}', $q$
begin;
insert into g_fk_parent values (:client_id + 1);
insert into g_fk_setnull (client, parent_id) select :client_id, :client_id + 1 from generate_series(1, 10);
delete from g_fk_parent where id = :client_id + 1;
delete from g_fk_setnull where client = :client_id;
commit;$q$, kind => 'write');

-- no action: the children are deleted by hand first
call pgmb.reg('storage.fk_delete_children_then_parent_10', '{perf,oltp}', $q$
begin;
insert into g_fk_parent values (:client_id + 1);
insert into g_fk_plain (parent_id) select :client_id + 1 from generate_series(1, 10);
delete from g_fk_plain where parent_id = :client_id + 1;
delete from g_fk_parent where id = :client_id + 1;
commit;$q$, kind => 'write');

-- a chain of five rows, each the parent of the next: deleting the first one
-- cascades through all levels
call pgmb.reg('storage.fk_delete_root_cascade_5_levels', '{perf,oltp}', $q$
begin;
insert into g_fk_tree select :b + k, case when k > 0 then :b + k - 1 end from generate_series(0, 4) k;
delete from g_fk_tree where id = :b;
commit;$q$, kind => 'write', setup => '\set b (:client_id + 1) * 100');

call pgmb.reg_ddl('storage.create_fk_functions', 'schema', $q$
create function storage_fk_facts() returns text language plpgsql as
$f$declare
    r text;
begin
    insert into pgmb_data.g_fk_parent values (-1);
    insert into pgmb_data.g_fk_cascade (parent_id) select -1 from generate_series(1, 10);
    insert into pgmb_data.g_fk_setnull (client, parent_id) select -1, -1 from generate_series(1, 10);
    insert into pgmb_data.g_fk_tree select -10 - k, case when k > 0 then -10 - k + 1 end from generate_series(0, 4) k;
    delete from pgmb_data.g_fk_parent where id = -1;
    delete from pgmb_data.g_fk_tree where id = -10;
    r := format('cascade left %s, set null left %s with %s parents, tree left %s',
                (select count(*) from pgmb_data.g_fk_cascade where parent_id = -1),
                (select count(*) from pgmb_data.g_fk_setnull where client = -1),
                (select count(parent_id) from pgmb_data.g_fk_setnull where client = -1),
                (select count(*) from pgmb_data.g_fk_tree where id < 0));
    return r;
end$f$$q$);
call pgmb.reg('storage.fk_actions', '{consistency}', $q$select storage_fk_facts()$q$, equiv => 'storage.fk');
call pgmb.reg('storage.fk_actions_expected', '{consistency}',
    $q$select 'cascade left 0, set null left 10 with 0 parents, tree left 0'::text$q$, equiv => 'storage.fk');

-- no action: the parent cannot go while a child points at it
call pgmb.reg('storage.err_fk_delete_parent_with_children', '{errors}', $q$
do $do$
begin
    insert into pgmb_data.g_fk_parent values (-2);
    insert into pgmb_data.g_fk_plain (parent_id) values (-2);
    delete from pgmb_data.g_fk_parent where id = -2;
end $do$$q$, expect_error => '23503');
call pgmb.reg('storage.err_fk_child_without_parent', '{errors}',
    $q$insert into g_fk_plain (parent_id) values (-3)$q$, expect_error => '23503');

------------------------------------------------------------------------------
-- triggers: INSTEAD OF, transition tables, firing order, TRUNCATE
------------------------------------------------------------------------------
-- The triggers write to g_trg_log only when pgmb.trg_log is on, so that the
-- log does not grow during the benchmark.
call pgmb.reg_ddl('storage.create_trigger_tables', 'schema', $q$
create table g_trg (id int primary key, v int not null);
create table g_trg_log (src text not null, n bigint not null);
create view v_trg as select id, v from g_trg;
create function storage_trg_log(src text, n bigint) returns void language plpgsql as
$f$begin
    if current_setting('pgmb.trg_log', true) = 'on' then
        insert into pgmb_data.g_trg_log values (src, n);
    end if;
end$f$;
create function storage_trg_instead() returns trigger language plpgsql as
$f$begin
    insert into pgmb_data.g_trg values (new.id, new.v * 2);
    return new;
end$f$;
create function storage_trg_plus_one() returns trigger language plpgsql as
'begin new.v := new.v + 1; return new; end';
create function storage_trg_times_ten() returns trigger language plpgsql as
'begin new.v := new.v * 10; return new; end';
create function storage_trg_transition() returns trigger language plpgsql as
$f$begin
    perform pgmb_data.storage_trg_log('transition', (select count(*) from new_rows));
    return null;
end$f$;
create function storage_trg_truncate() returns trigger language plpgsql as
$f$begin
    perform pgmb_data.storage_trg_log('truncate', 0);
    return null;
end$f$;
create trigger v_trg_instead instead of insert on v_trg for each row execute function storage_trg_instead();
-- triggers of one kind fire in the order of their names
create trigger a_plus_one before insert on g_trg for each row execute function storage_trg_plus_one();
create trigger b_times_ten before insert on g_trg for each row execute function storage_trg_times_ten();
create trigger g_trg_transition after insert on g_trg referencing new table as new_rows
    for each statement execute function storage_trg_transition();
create trigger g_trg_truncate after truncate on g_trg for each statement execute function storage_trg_truncate();
create function storage_trigger_facts() returns text language plpgsql as
$f$declare
    r text;
begin
    perform set_config('pgmb.trg_log', 'on', true);
    insert into pgmb_data.v_trg values (-1, 5);
    insert into pgmb_data.g_trg select -1 - n, 1 from generate_series(1, 3) n;
    r := format('through the view: %s, direct: %s, transition tables: %s',
                (select v from pgmb_data.g_trg where id = -1),
                (select string_agg(distinct v::text, ',') from pgmb_data.g_trg where id < -1),
                (select string_agg(n::text, ',' order by n) from pgmb_data.g_trg_log where src = 'transition'));
    truncate pgmb_data.g_trg;
    return r || format(', truncate fired: %s, rows left: %s',
                       (select count(*) from pgmb_data.g_trg_log where src = 'truncate'),
                       (select count(*) from pgmb_data.g_trg));
end$f$$q$);

-- 5 doubled by the INSTEAD OF trigger, then (10 + 1) * 10 by the two BEFORE triggers
call pgmb.reg('storage.trigger_facts', '{consistency}', $q$select storage_trigger_facts()$q$, equiv => 'storage.trigger');
call pgmb.reg('storage.trigger_facts_expected', '{consistency}', $q$
select 'through the view: 110, direct: 20, transition tables: 1,3, truncate fired: 1, rows left: 0'::text$q$,
    equiv => 'storage.trigger');

call pgmb.reg('storage.trigger_instead_of_insert_through_view', '{perf,oltp}', $q$
begin;
insert into v_trg values (:client_id + 1, 1);
delete from g_trg where id = :client_id + 1;
commit;$q$, kind => 'write');

-- 100 rows in one statement: two row triggers each, one statement trigger that
-- counts its transition table
call pgmb.reg('storage.trigger_transition_table_100_rows', '{perf}', $q$
begin;
insert into g_trg select :b + n, 1 from generate_series(1, 100) n;
delete from g_trg where id between :b + 1 and :b + 100;
commit;$q$, kind => 'write', setup => '\set b (:client_id + 1) * 1000');

------------------------------------------------------------------------------
-- TOAST: compressed, uncompressed, incompressible
------------------------------------------------------------------------------
-- 100 rows with three values of 100 kB: a repeating text stored compressed,
-- the same text stored EXTERNAL (out of line, not compressed), and a text
-- that does not compress.
call pgmb.reg_ddl('storage.create_g_toast', 'schema', $q$
create table g_toast (id int primary key, c_comp text not null, c_ext text not null, c_rand text not null);
alter table g_toast alter column c_ext set storage external;
insert into g_toast
select i, repeat('abcdefgh', 12500), repeat('abcdefgh', 12500),
       (select string_agg(md5((i * 4000 + g)::text), '') from generate_series(1, 3125) g)
from generate_series(1, 100) i$q$, target => 'g_toast');

call pgmb.reg('storage.toast_compression_facts', '{consistency}', $q$
select pg_column_compression(c_comp) is not null, pg_column_compression(c_ext) is null,
       pg_column_size(c_comp) < 10000, pg_column_size(c_ext) >= 100000, octet_length(c_comp) = octet_length(c_ext)
from g_toast where id = 1$q$, equiv => 'storage.toast');
call pgmb.reg('storage.toast_compression_facts_expected', '{consistency}',
    $q$select true, true, true, true, true$q$, equiv => 'storage.toast');

-- the whole value is needed: fetch and decompress, fetch only, fetch a value
-- that is stored as it is
call pgmb.reg('storage.toast_read_compressed', '{perf}',
    $q$select sum(length(c_comp)) from g_toast where id between :id and :id + 9$q$, setup => '\set id random(1, 91)');
call pgmb.reg('storage.toast_read_external', '{perf}',
    $q$select sum(length(c_ext)) from g_toast where id between :id and :id + 9$q$, setup => '\set id random(1, 91)');
call pgmb.reg('storage.toast_read_incompressible', '{perf}',
    $q$select sum(length(c_rand)) from g_toast where id between :id and :id + 9$q$, setup => '\set id random(1, 91)');

-- a slice: of an EXTERNAL value only the chunks that hold it are fetched
call pgmb.reg('storage.toast_substr_compressed', '{perf,oltp}',
    $q$select substr(c_comp, 50000, 100) from g_toast where id = :id$q$, setup => '\set id random(1, 100)');
call pgmb.reg('storage.toast_substr_external', '{perf,oltp}',
    $q$select substr(c_ext, 50000, 100) from g_toast where id = :id$q$, setup => '\set id random(1, 100)');

-- the size is in the TOAST pointer: nothing is fetched
call pgmb.reg('storage.toast_octet_length_not_fetched', '{perf}',
    $q$select sum(octet_length(c_comp)) from g_toast where id between :id and :id + 9$q$, setup => '\set id random(1, 91)');

-- an update that does not touch the large values leaves them where they are
call pgmb.reg('storage.toast_update_values_untouched', '{perf,oltp}', $q$
begin;
update g_toast set id = id where id = :client_id % 100 + 1;
commit;$q$, kind => 'write');
call pgmb.reg('storage.toast_update_rewrites_value', '{perf}', $q$
begin;
update g_toast set c_comp = c_comp || '' where id = :client_id % 100 + 1;
commit;$q$, kind => 'write');

------------------------------------------------------------------------------
-- bloat, VACUUM, REINDEX: timed steps of the DDL phase
------------------------------------------------------------------------------
-- Every step is recorded with its time, its WAL and the size of the table or
-- index afterwards.
call pgmb.reg_ddl('storage.create_g_bloat', 'schema', $q$
create table g_bloat (id bigint not null, k int not null, pad text not null);
create table g_bloat_dirty (id bigint not null, k int not null, pad text not null)$q$);
call pgmb.reg_ddl('storage.load_g_bloat', 'load', $q$
insert into g_bloat select i, pgmb.hu(i, 1, 1000)::int, pgmb.htext(i, 2, 60) from generate_series(1, :n_g_bloat) i$q$,
    target => 'g_bloat');
call pgmb.reg_ddl('storage.load_g_bloat_dirty', 'load', $q$
insert into g_bloat_dirty select i, pgmb.hu(i, 1, 1000)::int, pgmb.htext(i, 2, 60) from generate_series(1, :n_g_bloat) i$q$,
    target => 'g_bloat_dirty');
call pgmb.reg_ddl('storage.pk_g_bloat', 'constraint', $q$alter table g_bloat add primary key (id)$q$, target => 'g_bloat_pkey');
call pgmb.reg_ddl('storage.ix_g_bloat_k', 'index', $q$create index g_bloat_k on g_bloat (k)$q$, target => 'g_bloat_k');
call pgmb.reg_ddl('storage.pk_g_bloat_dirty', 'constraint', $q$alter table g_bloat_dirty add primary key (id)$q$,
    target => 'g_bloat_dirty_pkey');

call pgmb.reg_ddl('storage.bloat_1_vacuum_fresh', 'maintenance', $q$vacuum (analyze) g_bloat$q$, target => 'g_bloat');
-- every row gets a new version, and both indexes a new entry for it
call pgmb.reg_ddl('storage.bloat_2_update_all_rows', 'maintenance', $q$update g_bloat set k = k + 1$q$, target => 'g_bloat');
call pgmb.reg_ddl('storage.bloat_3_vacuum_after_update', 'maintenance', $q$vacuum g_bloat$q$, target => 'g_bloat');
call pgmb.reg_ddl('storage.bloat_4_update_all_rows_again', 'maintenance', $q$update g_bloat set k = k + 1$q$, target => 'g_bloat');
call pgmb.reg_ddl('storage.bloat_5_reindex_index', 'maintenance', $q$reindex index g_bloat_k$q$, target => 'g_bloat_k');
call pgmb.reg_ddl('storage.bloat_6_reindex_table', 'maintenance', $q$reindex table g_bloat$q$, target => 'g_bloat_pkey');
call pgmb.reg_ddl('storage.bloat_7_vacuum_full', 'maintenance', $q$vacuum full g_bloat$q$, target => 'g_bloat');
call pgmb.reg_ddl('storage.bloat_8_vacuum_analyze', 'maintenance', $q$vacuum (analyze) g_bloat$q$, target => 'g_bloat');
-- the twin is left with every row rewritten and never vacuumed by the benchmark
call pgmb.reg_ddl('storage.bloat_dirty_update_all_rows', 'maintenance', $q$update g_bloat_dirty set k = k + 1$q$,
    target => 'g_bloat_dirty');
call pgmb.reg_ddl('storage.bloat_dirty_analyze', 'maintenance', $q$analyze g_bloat_dirty$q$);

-- an index-only scan over pages that are all visible, and over pages that are
-- not (the heap is visited for every row, unless autovacuum got there first)
call pgmb.reg('storage.index_only_scan_all_visible', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_bloat where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_bloat)', equiv => 'storage.index_only');
call pgmb.reg('storage.index_only_scan_not_all_visible', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_bloat_dirty where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_bloat)', equiv => 'storage.index_only');

-- a sequential scan of a compact table and of one twice its size
call pgmb.reg('storage.seq_scan_compact_table', '{perf,consistency,needs_data}',
    $q$select count(*), sum(k) from g_bloat$q$, equiv => 'storage.bloat_scan');
call pgmb.reg('storage.seq_scan_bloated_table', '{perf,consistency,needs_data}',
    $q$select count(*), sum(k) + count(*) from g_bloat_dirty$q$, equiv => 'storage.bloat_scan');

------------------------------------------------------------------------------
-- WAL: logged, unlogged and temporary tables
------------------------------------------------------------------------------
-- The WAL written by each test is recorded with its result (isolated mode).
call pgmb.reg_ddl('storage.create_wal_tables', 'schema', $q$
create table g_wal_logged (id bigserial primary key, client int not null, pad text not null);
create index g_wal_logged_client on g_wal_logged (client);
create unlogged table g_wal_unlogged (id bigserial primary key, client int not null, pad text not null);
create index g_wal_unlogged_client on g_wal_unlogged (client);
create table g_load_logged (id bigint not null, k int not null, pad text not null);
create unlogged table g_load_unlogged (id bigint not null, k int not null, pad text not null)$q$);

-- the same load, timed, with its WAL
call pgmb.reg_ddl('storage.load_logged_table', 'load', $q$
insert into g_load_logged select i, pgmb.hu(i, 1, 1000)::int, pgmb.htext(i, 2, 60) from generate_series(1, :n_g_load) i$q$,
    target => 'g_load_logged');
call pgmb.reg_ddl('storage.load_unlogged_table', 'load', $q$
insert into g_load_unlogged select i, pgmb.hu(i, 1, 1000)::int, pgmb.htext(i, 2, 60) from generate_series(1, :n_g_load) i$q$,
    target => 'g_load_unlogged');
call pgmb.reg_ddl('storage.index_logged_table', 'index', $q$create index g_load_logged_k on g_load_logged (k)$q$,
    target => 'g_load_logged_k');
call pgmb.reg_ddl('storage.index_unlogged_table', 'index', $q$create index g_load_unlogged_k on g_load_unlogged (k)$q$,
    target => 'g_load_unlogged_k');

call pgmb.reg('storage.wal_insert_delete_100_logged', '{perf}', $q$
begin;
insert into g_wal_logged (client, pad) select :client_id, repeat('x', 100) from generate_series(1, 100);
delete from g_wal_logged where client = :client_id;
commit;$q$, kind => 'write');
call pgmb.reg('storage.wal_insert_delete_100_unlogged', '{perf}', $q$
begin;
insert into g_wal_unlogged (client, pad) select :client_id, repeat('x', 100) from generate_series(1, 100);
delete from g_wal_unlogged where client = :client_id;
commit;$q$, kind => 'write');

-- a temporary table lives in the session: created, filled and dropped with
-- the transaction, which is also what it costs in the catalogs
call pgmb.reg('storage.temp_table_create_insert_100_drop', '{perf}', $q$
begin;
create temp table g_wal_temp (id int, pad text) on commit drop;
insert into g_wal_temp select n, repeat('x', 100) from generate_series(1, 100) n;
commit;$q$, kind => 'write');
call pgmb.reg('storage.temp_table_create_drop_empty', '{perf}', $q$
begin;
create temp table g_wal_temp (id int, pad text) on commit drop;
commit;$q$, kind => 'write');

-- one row and its commit: the commit record has to reach the disk only for the logged table
call pgmb.reg('storage.wal_single_insert_logged', '{perf,oltp}', $q$
begin;
insert into g_wal_logged (client, pad) values (:client_id, 'x');
delete from g_wal_logged where client = :client_id;
commit;$q$, kind => 'write');
call pgmb.reg('storage.wal_single_insert_unlogged', '{perf,oltp}', $q$
begin;
insert into g_wal_unlogged (client, pad) values (:client_id, 'x');
delete from g_wal_unlogged where client = :client_id;
commit;$q$, kind => 'write');

------------------------------------------------------------------------------
-- sequences
------------------------------------------------------------------------------
call pgmb.reg_ddl('storage.create_sequences', 'schema', $q$
create sequence g_seq_plain;
create sequence g_seq_cache_100 cache 100;
create sequence g_seq_never_used;
-- on a sequence of its own: what a failed block, currval() and setval() do
create function storage_sequence_facts() returns text language plpgsql as
$f$declare
    a bigint; b bigint; cur bigint; after_set bigint; after_set_false bigint;
begin
    create temp sequence g_seq_facts;
    a := nextval('g_seq_facts');
    begin
        perform nextval('g_seq_facts');
        perform 1 / 0;
    exception when division_by_zero then null;
    end;
    b := nextval('g_seq_facts');
    cur := currval('g_seq_facts');
    perform setval('g_seq_facts', 100);
    after_set := nextval('g_seq_facts');
    perform setval('g_seq_facts', 200, false);
    after_set_false := nextval('g_seq_facts');
    drop sequence g_seq_facts;
    return format('value taken in the failed block is lost: %s, currval is the last value: %s, after setval(100): %s, after setval(200, false): %s',
                  b - a = 2, cur = b, after_set, after_set_false);
end$f$$q$);

call pgmb.reg('storage.sequence_facts', '{consistency}', $q$select storage_sequence_facts()$q$, equiv => 'storage.sequence');
call pgmb.reg('storage.sequence_facts_expected', '{consistency}', $q$
select 'value taken in the failed block is lost: t, currval is the last value: t, after setval(100): 101, after setval(200, false): 200'::text$q$,
    equiv => 'storage.sequence');

-- currval() before nextval() in the session
call pgmb.reg('storage.err_sequence_currval_before_nextval', '{errors}',
    $q$select currval('g_seq_never_used')$q$, expect_error => '55000');

-- every client takes values from the same sequence
call pgmb.reg('storage.sequence_nextval', '{perf,concurrency,oltp}', $q$select nextval('g_seq_plain')$q$);
-- each backend reserves 100 values at a time
call pgmb.reg('storage.sequence_nextval_cache_100', '{perf,concurrency,oltp}', $q$select nextval('g_seq_cache_100')$q$);
call pgmb.reg('storage.sequence_nextval_100_per_statement', '{perf,concurrency}',
    $q$select count(nextval('g_seq_plain')) from generate_series(1, 100)$q$);
call pgmb.reg('storage.sequence_nextval_100_per_statement_cache_100', '{perf,concurrency}',
    $q$select count(nextval('g_seq_cache_100')) from generate_series(1, 100)$q$);
call pgmb.reg('storage.sequence_nextval_rolled_back', '{perf,oltp}', $q$
begin;
select nextval('g_seq_plain');
rollback;$q$);
call pgmb.reg('storage.sequence_setval', '{perf,concurrency,oltp}',
    $q$select setval('g_seq_cache_100', nextval('g_seq_cache_100') + 1000)$q$);
