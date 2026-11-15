-- Topic: cte (part 11) - data-modifying CTEs in detail.
-- INSERT/UPDATE/DELETE/MERGE inside WITH, with and without RETURNING, how often
-- and how far they run, what readers in the same statement see, constraints,
-- triggers, ON CONFLICT, partitions, chains of writers and what is rejected.
-- Basic cases live elsewhere: cte.dml_* in cte.sql (INSERT/UPDATE/DELETE with
-- RETURNING), cte.prune_unreferenced_writer_runs, cte.mix_dml_* (snapshot).
-- Tables: g_dml (constraints), g_dml_trig (triggers), g_dml_audit, g_part.

------------------------------------------------------------------------------
-- MERGE inside a CTE
-- MERGE has no speculative insertion, so two clients inserting the same key
-- would fail with a unique violation. Keys are i * 1024 + :client_id, which
-- keeps the clients (up to 1024) apart.
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_merge_returning', '{perf,planning,oltp,needs_data}', $q$
with m as (
    merge into g_dml t using (select :id::bigint * 1024 + :client_id as id) s on t.id = s.id
    when matched and t.qty % 10 = 0 then delete
    when matched then update set qty = t.qty + 1, updated_at = now()
    when not matched then insert (id, dim_id, code, qty, val, updated_at)
         values (s.id, 1 + (s.id % :n_g_dim)::int, 'c' || s.id, 1, 0, now())
    returning merge_action() as action, t.id, t.qty)
select action, id, qty from m$q$,
    kind => 'write', setup => '\set id random(:n_g_dml + 1, 2 * :n_g_dml)');

-- one MERGE, all three actions, told apart with merge_action()
call pgmb.reg('cte.dml_merge_actions_counted', '{perf,planning,oltp,needs_data}', $q$
with m as (
    merge into g_dml t using (select i::bigint * 1024 + :client_id as id from generate_series(:id, :id + 49) i) s on t.id = s.id
    when matched and t.qty % 10 = 0 then delete
    when matched then update set qty = t.qty + 1, updated_at = now()
    when not matched then insert (id, dim_id, code, qty, val, updated_at)
         values (s.id, 1 + (s.id % :n_g_dim)::int, 'c' || s.id, 1, 0, now())
    returning merge_action() as action, t.id)
select action, count(*) as n from m group by action order by action$q$,
    kind => 'write', setup => '\set id random(:n_g_dml + 1, 2 * :n_g_dml - 50)');

-- old and new row versions per action (RETURNING old/new, PostgreSQL 18)
call pgmb.reg('cte.dml_merge_returning_old_new', '{perf,planning,oltp,needs_data}', $q$
with m as (
    merge into g_dml t using (select i::bigint * 1024 + :client_id as id from generate_series(:id, :id + 9) i) s on t.id = s.id
    when matched then update set qty = t.qty + 1
    when not matched then insert (id, dim_id, code, qty, val, updated_at)
         values (s.id, 1 + (s.id % :n_g_dim)::int, 'c' || s.id, 1, 0, now())
    returning merge_action() as action, old.qty as old_qty, new.qty as new_qty)
select action, count(*) as n, sum(new_qty - coalesce(old_qty, 0)) as delta from m group by action$q$,
    kind => 'write', setup => '\set id random(:n_g_dml + 1, 2 * :n_g_dml - 10)');

-- MERGE fed by another writer's RETURNING
call pgmb.reg('cte.dml_merge_source_is_writer', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 9 returning id, dim_id, code, qty, val, updated_at),
     m as (
    merge into g_dml_trig t using u on t.id = u.id
    when matched then update set qty = u.qty
    when not matched then insert values (u.id, u.dim_id, u.code, u.qty, u.val, u.updated_at)
    returning merge_action() as action)
select action, count(*) from m group by action$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml - 10)');

------------------------------------------------------------------------------
-- without RETURNING, unreferenced, LIMIT 0, several readers
------------------------------------------------------------------------------
-- the writer has no result relation; the main statement is another writer
call pgmb.reg('cte.dml_no_returning_beside_main_update', '{perf,planning,oltp}', $q$
with log as (insert into g_dml_audit (dml_id, action, qty) values (:id, 'manual', 0))
update g_dml set qty = qty + 1 where id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_unreferenced_batch_runs_to_completion', '{perf,planning}', $q$
with touch as (update g_dml set updated_at = now() where id between :id and :id + 99 returning id)
select 1$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_outer_limit_0_still_writes', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 9 returning id)
select id from u limit 0$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_outer_where_false_still_writes', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 9 returning id)
select id from u where false$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- three readers, one execution
call pgmb.reg('cte.dml_three_readers_one_execution', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 9 returning id, qty)
select (select count(*) from u) as n, (select max(qty) from u) as mx, (select min(id) from u) as first_id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_self_join_of_returning', '{perf,planning}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 99 returning id, qty)
select count(*) from u a join u b on b.id = a.id + 1 where b.qty >= a.qty$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- RETURNING shows new values, a scan of the table shows the snapshot
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_returning_joined_to_old_rows', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 49 returning id, qty)
select count(*) as n, count(*) filter (where u.qty = t.qty + 1) as old_rows_seen
from u join g_dml t using (id)$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- the same comparison without a second scan (PostgreSQL 18)
call pgmb.reg('cte.dml_returning_old_new', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 49 returning old.qty as old_qty, new.qty as new_qty)
select count(*) as n, count(*) filter (where new_qty = old_qty + 1) as changed from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_delete_still_visible_to_main_scan', '{perf,oltp}', $q$
begin;
with d as (delete from g_dml where id between :id and :id + 9 returning id)
select (select count(*) from d) as deleted, (select count(*) from g_dml where id between :id and :id + 9) as still_visible;
rollback;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- several writers in one statement
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_three_tables', '{perf,planning,oltp}', $q$
with a as (update g_dml set qty = qty + 1 where id = :id returning id),
     b as (insert into g_dml_audit (dml_id, action, qty) values (:id, 'three', 0) returning id),
     c as (update g_parent set val = val + 1 where id = :p returning id)
select (select count(*) from a) + (select count(*) from b) + (select count(*) from c)$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_dml)\n\\set p random(1, :n_g_parent)');

-- the outcome is unspecified: only one of the two updates takes effect
call pgmb.reg('cte.dml_same_row_two_updates', '{perf,planning,oltp}', $q$
with a as (update g_dml set qty = qty + 1 where id = :id returning id),
     b as (update g_dml set val = val + 1 where id = :id returning id)
select (select count(*) from a) as first, (select count(*) from b) as second$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_same_rows_two_updates_batch', '{perf,planning}', $q$
with a as (update g_dml set qty = qty + 1 where id between :id and :id + 99 returning id),
     b as (update g_dml set val = val + 1 where id between :id + 50 and :id + 149 returning id)
select (select count(*) from a) as first, (select count(*) from b) as second$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- updated in the CTE, then deleted by the main statement: the delete is skipped
call pgmb.reg('cte.dml_update_then_main_delete_same_row', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id = :id returning id)
delete from g_dml where id in (select id from u)$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- the other order: the delete wins and the update finds nothing
call pgmb.reg('cte.dml_delete_then_main_update_same_row', '{perf,oltp}', $q$
begin;
with d as (delete from g_dml where id = :id returning id)
update g_dml set qty = qty + 1 where id in (select id from d);
rollback;$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- constraints: FOREIGN KEY, UNIQUE, CHECK
------------------------------------------------------------------------------
-- all constraints are verified again for the re-inserted row
call pgmb.reg('cte.dml_constraints_delete_reinsert', '{perf,planning,oltp}', $q$
with d as (delete from g_dml where id = :id returning *)
insert into g_dml select * from d$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_constraints_update_fk_column', '{perf,planning,oltp}', $q$
with u as (update g_dml set dim_id = 1 + (dim_id % :n_g_dim) where id between :id and :id + 9 returning dim_id)
select count(distinct dim_id) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- same statement on the table without constraints other than the primary key
call pgmb.reg('cte.dml_constraints_none_update', '{perf,planning,oltp}', $q$
with u as (update g_dml_audit set qty = coalesce(qty, 0) + 1
           where id in (select id from g_dml_audit where dml_id between :id and :id + 9 limit 10) returning dml_id)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.err_dml_check_violation', '{errors,needs_data}',
    $q$with u as (update g_dml set qty = -1 where id = 1 returning id) select * from u$q$, expect_error => '23514');
call pgmb.reg('cte.err_dml_unique_violation', '{errors,needs_data}',
    $q$with u as (update g_dml set code = 'c2' where id = 1 returning id) select * from u$q$, expect_error => '23505');
call pgmb.reg('cte.err_dml_foreign_key_violation', '{errors,needs_data}',
    $q$with u as (update g_dml set dim_id = 0 where id = 1 returning id) select * from u$q$, expect_error => '23503');
-- the violation is raised although nothing reads the CTE
call pgmb.reg('cte.err_dml_check_violation_unreferenced', '{errors,needs_data}',
    $q$with u as (update g_dml set qty = -1 where id = 1) select 1$q$, expect_error => '23514');

------------------------------------------------------------------------------
-- triggers: BEFORE and AFTER row triggers fired by a writer in a CTE
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_trigger_none_update', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id = :id returning id, updated_at)
select * from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_trigger_before_after_update', '{perf,planning,oltp}', $q$
with u as (update g_dml_trig set qty = qty + 1 where id = :id returning id, updated_at)
select * from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_trigger_none_update_100', '{perf,planning}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 99 returning id)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_trigger_before_after_update_100', '{perf,planning}', $q$
with u as (update g_dml_trig set qty = qty + 1 where id between :id and :id + 99 returning id)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- rows written by the AFTER trigger are not visible to the same statement
call pgmb.reg('cte.dml_trigger_output_not_visible', '{perf,planning,oltp}', $q$
with u as (update g_dml_trig set qty = qty + 1 where id = :id returning id),
     before as (select count(*) as n from g_dml_audit where dml_id = :id)
select (select count(*) from u) as updated, (select n from before) as audit_rows_seen$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- rows handed from writer to writer through RETURNING
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_chain_update_insert_update', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id between :id and :id + 9 returning id, qty),
     a as (insert into g_dml_audit (dml_id, action, qty) select id, 'chain', qty from u returning dml_id, qty)
update g_dml_trig t set qty = a.qty from a where t.id = a.dml_id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_chain_delete_archive', '{perf,planning,oltp}', $q$
with d as (delete from g_dml_audit
           where id in (select id from g_dml_audit where dml_id between :id and :id + 20 limit 10)
           returning dml_id, action, qty),
     a as (insert into g_dml_audit (dml_id, action, qty) select dml_id, 'archived', qty from d returning id)
select count(*) from a$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_chain_four_writers', '{perf,planning}', $q$
with w1 as (update g_dml set qty = qty + 1 where id between :id and :id + 9 returning id, qty),
     w2 as (update g_dml_trig t set qty = w1.qty from w1 where t.id = w1.id returning t.id, t.qty),
     w3 as (insert into g_dml_audit (dml_id, action, qty) select id, 'w3', qty from w2 returning dml_id),
     w4 as (update g_parent p set val = p.val + 1 from w3 where p.id = w3.dml_id returning p.id)
select count(*) from w4$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- main statement is INSERT ... SELECT reading a writer
call pgmb.reg('cte.dml_writer_feeds_main_insert', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id = :id returning id, qty)
insert into g_dml_audit (dml_id, action, qty) select id, 'main', qty from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- recursive SELECT CTE as the source of UPDATE / DELETE
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_recursive_source_update_subtree', '{perf,planning,oltp}', $q$
with recursive sub(id, lvl) as (
    select id, 0 from g_tree where id = :id
    union all
    select c.id, s.lvl + 1 from sub s join g_tree c on c.parent_id = s.id where s.lvl < 2)
update g_tree t set val = t.val + 1 from sub where t.id = sub.id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.dml_recursive_source_update_ancestors', '{perf,planning,oltp}', $q$
with recursive up(id, parent_id) as (
    select id, parent_id from g_tree where id = :id
    union all
    select p.id, p.parent_id from up join g_tree p on p.id = up.parent_id),
u as (update g_tree t set val = t.val + 1 from up where t.id = up.id returning t.id)
select count(*) from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_tree)');

call pgmb.reg('cte.dml_recursive_source_delete_reinsert', '{perf,planning}', $q$
with recursive ids(id, n) as (
    select :id::bigint, 1
    union all
    select id + 7, n + 1 from ids where n < 10),
d as (delete from g_dml t using ids where t.id = ids.id returning t.*)
insert into g_dml select * from d$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- ON CONFLICT
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_on_conflict_do_nothing', '{perf,planning,oltp,needs_data}', $q$
with ins as (insert into g_dml (id, dim_id, code, qty, val, updated_at)
             values (:id, 1 + (:id % :n_g_dim), 'c' || :id, 1, 0, now())
             on conflict do nothing returning id)
select count(*) as inserted from ins$q$,
    kind => 'write', setup => '\set id random(1, 2 * :n_g_dml)');

call pgmb.reg('cte.dml_on_conflict_do_update', '{perf,planning,oltp,needs_data}', $q$
with ups as (insert into g_dml (id, dim_id, code, qty, val, updated_at)
             values (:id, 1 + (:id % :n_g_dim), 'c' || :id, 1, 0, now())
             on conflict (id) do update set qty = g_dml.qty + excluded.qty, updated_at = excluded.updated_at
             returning id, qty, (xmax = 0) as inserted)
select id, qty, inserted from ups$q$,
    kind => 'write', setup => '\set id random(1, 2 * :n_g_dml)');

call pgmb.reg('cte.dml_on_conflict_do_update_batch', '{perf,planning,needs_data}', $q$
with ups as (insert into g_dml (id, dim_id, code, qty, val, updated_at)
             select i, 1 + (i % :n_g_dim), 'c' || i, 1, 0, now() from generate_series(:id, :id + 99) i
             on conflict (id) do update set qty = g_dml.qty + 1
             returning (xmax = 0) as inserted)
select count(*) filter (where inserted) as inserted, count(*) filter (where not inserted) as updated from ups$q$,
    kind => 'write', setup => '\set id random(1, 2 * :n_g_dml - 100)');

-- DO UPDATE with a WHERE that rejects the row: nothing is returned for it
call pgmb.reg('cte.dml_on_conflict_do_update_where', '{perf,planning,oltp,needs_data}', $q$
with ups as (insert into g_dml (id, dim_id, code, qty, val, updated_at)
             select i, 1 + (i % :n_g_dim), 'c' || i, 1, 0, now() from generate_series(:id, :id + 9) i
             on conflict (id) do update set qty = g_dml.qty + 1 where g_dml.qty % 2 = 0
             returning id)
select count(*) from ups$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- conflict on the UNIQUE constraint instead of the primary key
call pgmb.reg('cte.dml_on_conflict_on_unique_constraint', '{perf,planning,oltp,needs_data}', $q$
with ups as (insert into g_dml (id, dim_id, code, qty, val, updated_at)
             values (:k, 1 + (:id % :n_g_dim), 'c' || :k, 1, 0, now())
             on conflict on constraint g_dml_code_uq do update set val = g_dml.val + 1
             returning id, val)
select * from ups$q$,
    kind => 'write', setup => E'\\set id random(1, 2 * :n_g_dml)\n\\set k :id * 1024 + :client_id');

------------------------------------------------------------------------------
-- partitioned table: routing and moving rows between partitions
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_partition_row_movement', '{perf,planning,oltp}', $q$
with mv as (update g_part set bucket = (bucket + 1) % 16 where id = :id returning id, bucket, tableoid::regclass::text as part)
select * from mv$q$,
    kind => 'write', setup => '\set id random(1, :n_g_part)');

-- the same update that stays inside the partition
call pgmb.reg('cte.dml_partition_update_in_place', '{perf,planning,oltp}', $q$
with u as (update g_part set val = val + 1 where id = :id returning id, bucket, tableoid::regclass::text as part)
select * from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_part)');

-- the move written by hand: DELETE ... RETURNING feeding an INSERT
call pgmb.reg('cte.dml_partition_move_delete_insert', '{perf,planning,oltp}', $q$
with d as (delete from g_part where id = :id returning *)
insert into g_part select id, (bucket + 1) % 16, ts, val, pad from d$q$,
    kind => 'write', setup => '\set id random(1, :n_g_part)');

call pgmb.reg('cte.dml_partition_row_movement_batch', '{perf,planning}', $q$
with mv as (update g_part set bucket = (bucket + 1) % 16 where bucket = :b and id between :id and :id + 1000 returning bucket)
select bucket, count(*) from mv group by bucket$q$,
    kind => 'write', setup => E'\\set b random(0, 15)\n\\set id random(1, :n_g_part)');

call pgmb.reg('cte.dml_partition_insert_routed', '{perf,planning,oltp}', $q$
with ins as (insert into g_part
             select i, i % 16, now(), 0, 'routed' from generate_series(:id, :id + 15) i
             on conflict do nothing returning tableoid)
select count(*) as inserted, count(distinct tableoid) as partitions from ins$q$,
    kind => 'write', setup => '\set id random(:n_g_part + 1, 2 * :n_g_part)');

------------------------------------------------------------------------------
-- empty RETURNING
------------------------------------------------------------------------------
call pgmb.reg('cte.dml_empty_returning_update', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id = -:id returning id, qty)
select count(*) as n, max(qty) as mx from u$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

-- downstream writers have nothing to do
call pgmb.reg('cte.dml_empty_returning_chain', '{perf,planning,oltp}', $q$
with d as (delete from g_dml where id = -:id returning id, qty),
     a as (insert into g_dml_audit (dml_id, action, qty) select id, 'never', qty from d returning dml_id)
update g_dml_trig t set qty = 0 from a where t.id = a.dml_id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

call pgmb.reg('cte.dml_empty_returning_outer_join', '{perf,planning,oltp}', $q$
with u as (update g_dml set qty = qty + 1 where id = -:id returning id, qty)
select t.id, u.qty is null as untouched from g_dml t left join u on u.id = t.id where t.id = :id$q$,
    kind => 'write', setup => '\set id random(1, :n_g_dml)');

------------------------------------------------------------------------------
-- what is rejected
------------------------------------------------------------------------------
-- a writer without RETURNING cannot be read
call pgmb.reg('cte.err_dml_without_returning_referenced', '{errors}',
    $q$with w as (update g_dml set qty = qty where id = 1) select * from w$q$, expect_error => '0A000');
-- data-modifying WITH is allowed only on the top-level statement
call pgmb.reg('cte.err_dml_in_subquery_with', '{errors}',
    $q$select * from (with d as (delete from g_dml where id = 1 returning id) select id from d) s$q$, expect_error => '0A000');
call pgmb.reg('cte.err_dml_in_nested_with', '{errors}',
    $q$with outer_cte as (with d as (delete from g_dml where id = 1 returning id) select id from d) select * from outer_cte$q$, expect_error => '0A000');
-- a recursive CTE cannot itself be a writer
call pgmb.reg('cte.err_dml_recursive_update', '{errors}',
    $q$with recursive t as (update g_dml set qty = g_dml.qty from t where g_dml.id = t.id returning g_dml.id) select * from t$q$, expect_error => '42P19');
call pgmb.reg('cte.err_dml_recursive_delete', '{errors}',
    $q$with recursive t as (delete from g_dml using t where g_dml.id = t.id returning g_dml.id) select * from t$q$, expect_error => '42P19');
