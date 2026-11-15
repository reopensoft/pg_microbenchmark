-- Topic: row locks. SELECT ... FOR UPDATE / NO KEY UPDATE / SHARE / KEY SHARE
-- and the statements that take the same locks implicitly (UPDATE, FK checks).
-- Rows are picked with a Zipfian distribution so that connections collide.
-- Everything here takes row locks, so every test is a write.

call pgmb.reg('locking.for_update', '{perf,locking,concurrency,oltp}', $q$
begin;
select val from g_parent where id = :id for update;
update g_parent set val = val + 1 where id = :id;
commit;$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('locking.for_no_key_update', '{perf,locking,concurrency,oltp}', $q$
begin;
select val from g_parent where id = :id for no key update;
update g_parent set val = val + 1 where id = :id;
commit;$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('locking.for_share', '{perf,planning,locking,concurrency,oltp}', $q$
select val from g_parent where id = :id for share$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('locking.for_key_share', '{perf,planning,locking,concurrency,oltp}', $q$
select val from g_parent where id = :id for key share$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

-- implicit locks
call pgmb.reg('locking.update_non_key', '{perf,planning,locking,concurrency,oltp}', $q$
update g_parent set val = val + 1 where id = :id$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('locking.fk_insert_child', '{perf,planning,locking,concurrency,oltp,needs_data}', $q$
insert into g_child (parent_id, seq, kind, amount, ts, note) values (:id, 0, 0, 1.00, now(), 'lock')$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

-- FK insert against a parent row that another session holds FOR NO KEY UPDATE: must not block
call pgmb.reg('locking.fk_insert_under_no_key_update', '{perf,locking,concurrency,oltp,needs_data}', $q$
begin;
select val from g_parent where id = :id for no key update;
insert into g_child (parent_id, seq, kind, amount, ts, note) values (:id, 0, 0, 1.00, now(), 'lock');
commit;$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

-- several rows, always locked in id order
call pgmb.reg('locking.multi_row_ordered', '{perf,planning,locking,concurrency,oltp}', $q$
select id from g_parent where id between :id and :id + 4 order by id for no key update$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('locking.skip_locked_queue', '{perf,planning,locking,concurrency,oltp}', $q$
select id from g_parent where grp = :g order by id limit 5 for update skip locked$q$,
    kind => 'write', setup => '\set g random(0, 99)');

call pgmb.reg('locking.for_update_of_join', '{perf,planning,locking,concurrency,oltp}', $q$
select p.id, d.code from g_parent p join g_dim d on d.id = p.dim_id where p.id = :id for update of p$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('locking.for_share_join_both', '{perf,planning,locking,concurrency,oltp}', $q$
select p.id, d.code from g_parent p join g_dim d on d.id = p.dim_id where p.id = :id for key share$q$,
    kind => 'write', setup => '\set id random_zipfian(1, :n_g_parent, 1.1)');

call pgmb.reg('locking.err_for_update_aggregate', '{errors}',
    $q$select count(*) from g_parent for update$q$, expect_error => '0A000');
call pgmb.reg('locking.err_for_update_distinct', '{errors}',
    $q$select distinct grp from g_parent for no key update$q$, expect_error => '0A000');
call pgmb.reg('locking.err_for_update_of_unknown', '{errors}',
    $q$select * from g_parent p for update of q$q$, expect_error => '42P01');
