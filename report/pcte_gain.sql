-- Time of each CTE in a test, and what running the CTEs side by side could gain.
--   psql -X -d <db> -f report/pcte_gain.sql [-v test=<regex>] [-v gucs='name=value,...']
-- Needs the catalog of the last bench.sql run (schema pgmb) and its data.
-- Each test is run once with EXPLAIN (ANALYZE, BUFFERS) in a transaction that
-- is rolled back. Only tests that are one query (with SET LOCAL in front) are
-- measured. CTEs are told apart by name, so CTEs nested in other CTEs
-- should not share a name.
--
-- Columns:
--   ctes        number of CTEs that ran
--   sum_ms      own time of all CTEs added up (what one process spends on them);
--               the own time of a CTE leaves out the time of computing the CTEs
--               it reads (taken off the reader with the longest scan of them)
--   path_ms     the longest chain of CTEs that depend on each other (the
--               critical path if every CTE ran on its own as soon as its
--               inputs were ready)
--   gain_ms     sum_ms - path_ms: the most that running CTEs side by side could save
--   total_ms    execution time of the whole statement
--   handed_rows rows read out of CTEs, and rows sent through Gather from workers
--   handed_mb   handed_rows times the width of those rows
--   temp_mb     temporary files written by the statement
\set ON_ERROR_STOP on
\set QUIET on
\pset pager off
\if :{?test}
\else
    \set test '^pcte\\.'
\endif
\if :{?gucs}
\else
    \set gucs ''
\endif
set search_path = pgmb_data, pgmb, public;
set client_min_messages = warning;
select format('set %s = %L', m[1], m[2])
from regexp_split_to_table(nullif(btrim(:'gucs'), ''), '\s*,\s*') as g(item),
     regexp_match(item, '^([A-Za-z_][A-Za-z0-9_.]*)=([^ ]+)$') m \gexec
select setseed(0.42) \gset pgmb_ignore_

create function pg_temp.pcte_gain(p_sql text, out ctes int, out sum_ms numeric, out path_ms numeric, out total_ms numeric,
                                  out handed_rows bigint, out handed_mb numeric, out temp_mb numeric)
language plpgsql as $$
declare
    parts record;
    stmt  text;
    j     json;
    own   jsonb := '{}';   -- CTE name -> own time
    refs  jsonb := '{}';   -- CTE name -> names of the CTEs it reads
    path  jsonb := '{}';   -- CTE name -> longest chain ending in it
    r     record;
    changed boolean;
    v     numeric;
begin
    begin
        parts := pgmb.script_parts(p_sql);
        foreach stmt in array parts.pre loop execute stmt; end loop;
        execute 'explain (analyze, buffers, format json) ' || parts.query into j;

        -- Every plan node with the CTE it belongs to ('' for the main query).
        -- A CTE is computed inside the CTE Scan that pulls its rows first, so
        -- its time is taken off the CTE that holds the longest scan of it; the
        -- rest of that scan's time (projection, filters) stays with the reader.
        for r in
            with recursive n(p, owner) as (
                select (j->0->'Plan')::jsonb, ''
                union all
                select c, case when c->>'Subplan Name' like 'CTE %' then substr(c->>'Subplan Name', 5) else n.owner end
                from n, jsonb_array_elements(n.p->'Plans') c),
            cte as (
                select owner as name, (p->>'Actual Total Time')::numeric as t
                from n where p->>'Subplan Name' like 'CTE %'),
            scans as (
                select owner, p->>'CTE Name' as reads,
                       (p->>'Actual Total Time')::numeric * (p->>'Actual Loops')::numeric as t
                from n where p->>'Node Type' = 'CTE Scan'),
            producer as (
                select distinct on (reads) reads, owner from scans order by reads, t desc)
            select cte.name, cte.t,
                   coalesce((select sum(z.t) from producer pr join cte z on z.name = pr.reads where pr.owner = cte.name), 0) as inner_t,
                   coalesce((select jsonb_agg(distinct s.reads) from scans s where s.owner = cte.name), '[]') as reads
            from cte
        loop
            own := own || jsonb_build_object(r.name, greatest(r.t - r.inner_t, 0));
            refs := refs || jsonb_build_object(r.name, r.reads);
        end loop;

        -- the longest chain ending in each CTE (the graph has no cycles)
        path := own;
        loop
            changed := false;
            for r in select key as name from jsonb_each(own) loop
                select (own->>r.name)::numeric + coalesce(max((path->>x)::numeric), 0) into v
                from jsonb_array_elements_text(refs->r.name) x where path ? x;
                if v > (path->>r.name)::numeric then
                    path := path || jsonb_build_object(r.name, v);
                    changed := true;
                end if;
            end loop;
            exit when not changed;
        end loop;

        select count(*), round(coalesce(sum(value::numeric), 0), 1) into ctes, sum_ms from jsonb_each_text(own);
        select round(coalesce(max(value::numeric), 0), 1) into path_ms from jsonb_each_text(path);

        -- rows handed on: out of CTE Scans, and out of Gather nodes
        with recursive n(p) as (
            select (j->0->'Plan')::jsonb
            union all
            select c from n, jsonb_array_elements(n.p->'Plans') c)
        select coalesce(sum(round((p->>'Actual Rows')::numeric * (p->>'Actual Loops')::numeric)), 0)::bigint,
               round(coalesce(sum((p->>'Actual Rows')::numeric * (p->>'Actual Loops')::numeric * (p->>'Plan Width')::numeric), 0) / 1048576, 1)
        into handed_rows, handed_mb
        from n where p->>'Node Type' in ('CTE Scan', 'Gather', 'Gather Merge');

        total_ms := round((j->0->>'Execution Time')::numeric, 1);
        temp_mb := round(coalesce((j->0->'Plan'->>'Temp Written Blocks')::numeric, 0) * 8 / 1024, 1);
        raise exception using errcode = 'PGMB0';
    exception when sqlstate 'PGMB0' then
        null;
    end;
end $$;

select t.id as test, g.ctes, g.sum_ms, g.path_ms, g.sum_ms - g.path_ms as gain_ms, g.total_ms,
       g.handed_rows, g.handed_mb, g.temp_mb
from pgmb.test t,
     lateral pg_temp.pcte_gain(pgmb.bind(t.sql, t.setup)) g
where t.phase = 'dml' and t.id ~ :'test' and t.expect_error is null
  and (pgmb.script_parts(t.sql)).query is not null
order by t.ord;
