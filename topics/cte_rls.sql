-- Topic: cte (part 15) - CTEs over a table with row level security (g_rls).
-- Registered only when the run names a role: -v rls_role=<role> (rls_role.sql
-- creates one). The table owner and superusers bypass the policies, so every
-- test switches to that role for one transaction:
--     begin; set local role <role>; set local pgmb.tenant = N; <query>; commit;
-- Being multi-statement they are perf-only. The *_owner_* tests are the same
-- queries run by the owner with the tenant condition written by hand.
select :'rls_role' <> '' as pgmb_has_rls \gset
\if :pgmb_has_rls
-- fail early, before any data is loaded, when the role cannot do its job
select set_config('pgmb.rls_role', :'rls_role', false) \gset pgmb_ignore_
do $$
declare r name := current_setting('pgmb.rls_role');
begin
    if not exists (select from pg_roles where rolname = r) then
        raise exception 'rls_role "%" does not exist; create it with rls_role.sql', r;
    elsif (select rolsuper or rolbypassrls from pg_roles where rolname = r) then
        raise exception 'rls_role "%" is a superuser or has BYPASSRLS: row level security would not apply', r;
    elsif not pg_has_role(current_user, r, 'SET') then
        raise exception 'user "%" may not SET ROLE "%"; run rls_role.sql -v rls_role=% -v bench_user=%', current_user, r, r, current_user;
    end if;
end $$;
select format('begin;%sset local role %I;%sset local pgmb.tenant = :t;%s', E'\n', :'rls_role', E'\n', E'\n') as pgmb_rls_begin \gset
\set pgmb_rls_end '\ncommit;'
\set pgmb_own_begin 'begin;\nset local pgmb.tenant = :t;\n'

------------------------------------------------------------------------------
-- one row by primary key
------------------------------------------------------------------------------
call pgmb.reg('cte.rls_owner_pk', '{perf,oltp}', :'pgmb_own_begin' || $q$
with c as (select id, tenant, val from g_rls)
select id, val from c where id = :id and tenant = :t;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t :id % 100');

call pgmb.reg('cte.rls_policy_pk', '{perf,oltp}', :'pgmb_rls_begin' || $q$
with c as (select id, val from g_rls)
select id, val from c where id = :id;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t :id % 100');

-- the row exists but belongs to another tenant: nothing comes back
call pgmb.reg('cte.rls_policy_pk_other_tenant', '{perf,oltp}', :'pgmb_rls_begin' || $q$
with c as (select id, val from g_rls)
select id, val from c where id = :id;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t (:id + 1) % 100');

call pgmb.reg('cte.rls_policy_pk_materialized', '{perf,oltp}', :'pgmb_rls_begin' || $q$
with c as materialized (select id, val from g_rls where id between :id and :id + 99)
select id, val from c where id = :id;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t :id % 100');

------------------------------------------------------------------------------
-- all rows of the tenant
------------------------------------------------------------------------------
call pgmb.reg('cte.rls_owner_tenant_aggregate', '{perf,olap}', :'pgmb_own_begin' || $q$
with c as (select grp, val from g_rls where tenant = :t)
select grp, count(*), sum(val) from c group by grp;$q$ || :'pgmb_rls_end',
    setup => '\set t random(0, 99)');

call pgmb.reg('cte.rls_policy_tenant_aggregate', '{perf,olap}', :'pgmb_rls_begin' || $q$
with c as (select grp, val from g_rls)
select grp, count(*), sum(val) from c group by grp;$q$ || :'pgmb_rls_end',
    setup => '\set t random(0, 99)');

call pgmb.reg('cte.rls_policy_tenant_two_readers', '{perf,olap}', :'pgmb_rls_begin' || $q$
with c as (select grp, val from g_rls)
select (select count(*) from c where grp < 50) as low, (select sum(val) from c where grp >= 50) as high;$q$ || :'pgmb_rls_end',
    setup => '\set t random(0, 99)');

------------------------------------------------------------------------------
-- a user function in the reader: not leakproof, so it runs after the policy
------------------------------------------------------------------------------
call pgmb.reg('cte.rls_owner_function_filter', '{perf}', :'pgmb_own_begin' || $q$
with c as (select id, tenant, grp, val from g_rls)
select count(*) from c where tenant = :t and noop_plpgsql(grp) = :g;$q$ || :'pgmb_rls_end',
    setup => E'\\set t random(0, 99)\n\\set g random(0, 99)');

call pgmb.reg('cte.rls_policy_function_filter', '{perf}', :'pgmb_rls_begin' || $q$
with c as (select id, grp, val from g_rls)
select count(*) from c where noop_plpgsql(grp) = :g;$q$ || :'pgmb_rls_end',
    setup => E'\\set t random(0, 99)\n\\set g random(0, 99)');

-- a leakproof operator on an indexed column may go below the policy
call pgmb.reg('cte.rls_policy_leakproof_range', '{perf,oltp}', :'pgmb_rls_begin' || $q$
with c as (select id, val from g_rls)
select count(*), sum(val) from c where id between :id and :id + 999;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t random(0, 99)');

------------------------------------------------------------------------------
-- joins, recursion
------------------------------------------------------------------------------
call pgmb.reg('cte.rls_policy_join_unprotected_table', '{perf}', :'pgmb_rls_begin' || $q$
with c as (select id, grp, val from g_rls where id between :id and :id + 999)
select d.category, count(*), sum(c.val) from c join g_dim d on d.id = c.grp % :n_g_dim + 1 group by d.category;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t random(0, 99)');

call pgmb.reg('cte.rls_policy_self_join', '{perf}', :'pgmb_rls_begin' || $q$
with c as (select id, val from g_rls where id between :id and :id + 1999)
select count(*) from c a join c b on b.id = a.id + 100;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t random(0, 99)');

-- walking the tenant's rows by id + 100: the policy is applied in every step
call pgmb.reg('cte.rls_policy_recursive_walk', '{perf}', :'pgmb_rls_begin' || $q$
with recursive w(id, val, n) as (
    select id, val, 1 from g_rls where id = :id
    union all
    select r.id, r.val, w.n + 1 from w join g_rls r on r.id = w.id + 100 where w.n < 20)
select count(*), sum(val) from w;$q$ || :'pgmb_rls_end',
    setup => E'\\set id random(1, :n_g_rls)\n\\set t :id % 100');

------------------------------------------------------------------------------
-- writers
------------------------------------------------------------------------------
call pgmb.reg('cte.rls_owner_update', '{perf,oltp}', :'pgmb_own_begin' || $q$
with u as (update g_rls set val = val + 1 where id = :id and tenant = :t returning id)
select count(*) from u;$q$ || :'pgmb_rls_end',
    kind => 'write', setup => E'\\set id random(1, :n_g_rls)\n\\set t :id % 100');

call pgmb.reg('cte.rls_policy_update', '{perf,oltp}', :'pgmb_rls_begin' || $q$
with u as (update g_rls set val = val + 1 where id = :id returning id)
select count(*) from u;$q$ || :'pgmb_rls_end',
    kind => 'write', setup => E'\\set id random(1, :n_g_rls)\n\\set t :id % 100');

-- another tenant's row is invisible to the update: zero rows, no error
call pgmb.reg('cte.rls_policy_update_other_tenant', '{perf,oltp}', :'pgmb_rls_begin' || $q$
with u as (update g_rls set val = val + 1 where id = :id returning id)
select count(*) from u;$q$ || :'pgmb_rls_end',
    kind => 'write', setup => E'\\set id random(1, :n_g_rls)\n\\set t (:id + 1) % 100');

call pgmb.reg('cte.rls_policy_update_batch', '{perf}', :'pgmb_rls_begin' || $q$
with u as (update g_rls set val = val + 1 where id between :id and :id + 999 returning id)
select count(*) from u;$q$ || :'pgmb_rls_end',
    kind => 'write', setup => E'\\set id random(1, :n_g_rls)\n\\set t random(0, 99)');

-- WITH CHECK rejects the new row (moved to another tenant). pgbench drops a
-- client on an error, so the violation is caught in a DO block.
call pgmb.reg('cte.rls_policy_with_check_violation_caught', '{perf}', :'pgmb_rls_begin' || $q$
do $do$
declare n bigint;
begin
    with u as (update g_rls set tenant = tenant + 1
               where id = (select min(id) from g_rls) returning id)
    select count(*) into n from u;
exception when insufficient_privilege then null;
end $do$;$q$ || :'pgmb_rls_end',
    kind => 'write', setup => '\set t random(0, 99)');
\endif
