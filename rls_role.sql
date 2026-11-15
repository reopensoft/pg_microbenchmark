-- Create (or drop) the role used by the row level security tests.
-- Optional: without -v rls_role=... bench.sql does not register RLS tests.
--
--   psql -X -d <db> -f rls_role.sql                                create role pgmb_rls, let the current user SET ROLE to it
--   psql -X -d <db> -f rls_role.sql -v rls_role=name               another role name
--   psql -X -d <db> -f rls_role.sql -v bench_user=name             the user that will run bench.sql, if not the current one
--   psql -X -d <db> -f rls_role.sql -v drop=1                      revoke its privileges in this database and drop the role
--
-- Needs CREATEROLE (or superuser); bench.sql itself needs neither. The role is
-- NOLOGIN, has no attributes and owns nothing: superusers and table owners
-- bypass row level security, so the tests switch to it with SET LOCAL ROLE.
-- A role is global to the cluster: clean.sql does not remove it, drop=1 does.
\set ON_ERROR_STOP on
\set QUIET on
\if :{?rls_role}
\else
    \set rls_role pgmb_rls
\endif
\if :{?bench_user}
\else
    \set bench_user :USER
\endif
\if :{?drop}
\else
    \set drop 0
\endif

select exists (select from pg_roles where rolname = :'rls_role') as pgmb_role_exists \gset
\if :drop
    \if :pgmb_role_exists
        drop owned by :"rls_role";
        drop role :"rls_role";
        \echo dropped role :rls_role
    \else
        \echo role :rls_role does not exist
    \endif
\else
    \if :pgmb_role_exists
        select rolsuper or rolbypassrls as pgmb_role_bypasses from pg_roles where rolname = :'rls_role' \gset
        \if :pgmb_role_bypasses
            \echo role :rls_role is a superuser or has BYPASSRLS: row level security would not apply to it
            \quit
        \endif
        \echo role :rls_role already exists
    \else
        create role :"rls_role" nologin nosuperuser nobypassrls nocreatedb nocreaterole noinherit;
        \echo created role :rls_role
    \endif
    grant :"rls_role" to :"bench_user" with set true, inherit false;
    \echo :bench_user may now SET ROLE :rls_role
    \echo run:  psql -X -d :DBNAME -f bench.sql -v rls_role=:rls_role ...
\endif
