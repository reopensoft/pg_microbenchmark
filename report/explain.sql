-- EXPLAIN for registered tests, with their parameters bound.
--   psql -X -d <db> -f report/explain.sql -v test=<regex> [-v analyze=1] [-v gucs='name=value,...']
-- Needs the catalog of the last bench.sql run (schema pgmb) and its data.
-- Every test runs in a transaction that is rolled back.
-- Tests made of several statements: the preparing statements (SET LOCAL,
-- SET CONSTRAINTS, CREATE TEMP TABLE) are executed, every query is explained,
-- and a cursor is explained as its query with LIMIT <rows of its first FETCH>.
-- Tests with DO blocks and error tests are skipped.
\set ON_ERROR_STOP on
\set QUIET on
\pset pager off
\if :{?test}
\else
    \set test .
\endif
\if :{?analyze}
\else
    \set analyze 0
\endif
\if :{?gucs}
\else
    \set gucs ''
\endif
\if :{?outdir}
\else
    \set outdir out
\endif
set search_path = pgmb_data, pgmb, public;
set client_min_messages = warning;
select format('set %s = %L', m[1], m[2])
from regexp_split_to_table(nullif(btrim(:'gucs'), ''), '\s*,\s*') as g(item),
     regexp_match(item, '^([A-Za-z_][A-Za-z0-9_.]*)=([^ ]+)$') m \gexec
select setseed(0.42) \gset pgmb_ignore_
select case when :'analyze' = '1' then 'analyze, timing off, buffers off, ' else '' end as pgmb_explain_opts \gset

-- one test -> psql commands
create function pg_temp.pgmb_explain_script(p_id text, p_sql text, p_opts text) returns text language plpgsql as $$
declare
    stmt  text;
    out   text := format(E'\\echo\n\\echo ==== %s\nbegin;\n', p_id);
    m     text[];
    lim   text := coalesce((regexp_match(p_sql, '\mfetch\s+(?:forward\s+)?(\d+)', 'i'))[1], '10');
begin
    foreach stmt in array regexp_split_to_array(p_sql, ';\s*(\n|$)') loop
        stmt := btrim(stmt, E' \n\r\t');
        continue when stmt = '';
        if stmt ~* '^(begin|start transaction|commit|rollback|end|close|fetch|move)\M' then
            continue;
        elsif stmt ~* '^(set|create\s+temp|create\s+temporary)\M' then
            out := out || stmt || E';\n';
        elsif stmt ~* '^declare\M' then
            m := regexp_match(stmt, '^declare\s+\S+\s+.*?\mcursor\M.*?\mfor\s+(.*)$', 'is');
            out := out || format(E'\\echo -- cursor query, limit %s\nexplain (%scosts off) %s limit %s;\n', lim, p_opts, m[1], lim);
        elsif stmt ~* '^(with|select|insert|update|delete|merge|values|table)\M' then
            out := out || format(E'explain (%scosts off) %s;\n', p_opts, stmt);
        else
            out := out || format(E'\\echo -- skipped: %s\n', left(replace(stmt, E'\n', ' '), 60));
        end if;
    end loop;
    return out || 'rollback;';
end $$;

\pset format unaligned
\pset tuples_only on
\set pgmb_explain_file :outdir /_explain.psql
select pg_temp.pgmb_explain_script(t.id, pgmb.bind(t.sql, t.setup), :'pgmb_explain_opts')
from pgmb.test t
where t.phase = 'dml' and t.id ~ :'test' and t.expect_error is null and t.sql !~* '\mdo\s+\$'
order by t.ord \g :pgmb_explain_file
\pset format aligned
\pset tuples_only on
\i :pgmb_explain_file
