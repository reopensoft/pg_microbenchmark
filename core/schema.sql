-- Framework schema: test catalog, configuration, data generators, executors.
-- Rebuilt from scratch on every run; holds no results.
drop schema if exists pgmb cascade;
create schema pgmb;

------------------------------------------------------------------------------
-- Catalog
------------------------------------------------------------------------------
create table pgmb.preset (
    name         text primary key,
    descr        text not null,
    data_scale   double precision not null,
    base_clients int  not null,
    write_ratio  double precision not null,
    duration     int  not null,            -- seconds per pgbench invocation; 0 = one transaction per script
    warmup       int  not null,
    mode         text not null check (mode in ('isolated', 'mixed')),
    tags         text[] not null default '{}'
);

create table pgmb.config (
    one             boolean primary key default true check (one),
    preset          text not null,
    label           text,
    data_scale      double precision not null check (data_scale >= 0),  -- 0 = tables stay empty
    conn_scale      double precision not null check (conn_scale > 0),
    write_ratio     double precision not null check (write_ratio between 0 and 1),
    scope           text not null check (scope in ('rw', 'readonly', 'writeonly', 'createonly')),
    sel_tags        text[] not null,       -- a test must carry at least one of these
    exec_tags       text[] not null,       -- measurements to run; empty = all
    topics          text[] not null,
    mode            text not null check (mode in ('isolated', 'mixed')),
    protocol        text not null check (protocol in ('simple', 'extended', 'prepared')),
    duration        int  not null check (duration >= 0),               -- 0 = one transaction per script
    warmup          int  not null check (warmup >= 0),
    clients         int  not null,
    jobs            int  not null,
    plan_iterations int  not null check (plan_iterations > 0),
    pgbench_bin     text not null,
    outdir          text not null
);

-- Row counts: n = max(min_rows, round(base_rows * data_scale ^ exponent)).
-- Referenced from any DDL or DML text as :n_<name>.
create table pgmb.dataset (
    name      text primary key,
    base_rows bigint not null,
    exponent  double precision not null default 1,
    min_rows  bigint not null default 1
);

create table pgmb.test (
    ord          int generated always as identity,
    id           text primary key,         -- <topic>.<name>
    topic        text not null,
    phase        text not null check (phase in ('ddl', 'dml')),
    kind         text not null check (kind in ('schema', 'load', 'index', 'constraint', 'maintenance', 'read', 'write')),
    tags         text[] not null,
    weight       int  not null default 10 check (weight > 0),
    setup        text,                     -- pgbench "\set name expr" lines
    sql          text not null,
    equiv        text,                     -- consistency group: all members must return the same rows
    expect_error text,                     -- expected SQLSTATE
    target       text,                     -- DDL: relation whose size is reported
    protocol     text check (protocol in ('simple', 'extended', 'prepared'))  -- pgbench -M for this test; NULL = the run's
);

------------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------------
create procedure pgmb.reg(p_id text, p_tags text[], p_sql text,
                          kind text default 'read', setup text default null, weight int default 10,
                          equiv text default null, expect_error text default null,
                          protocol text default null)
language sql
begin atomic
    insert into pgmb.test (id, topic, phase, kind, tags, weight, setup, sql, equiv, expect_error, protocol)
    values (p_id, split_part(p_id, '.', 1), 'dml', kind, p_tags, weight, setup,
            btrim(p_sql, E' \n\r\t'), equiv, expect_error, protocol);
end;

create procedure pgmb.reg_ddl(p_id text, p_kind text, p_sql text, target text default null)
language sql
begin atomic
    insert into pgmb.test (id, topic, phase, kind, tags, sql, target)
    values (p_id, split_part(p_id, '.', 1), 'ddl', p_kind, array['ddl', p_kind],
            btrim(p_sql, E' \n\r\t'), target);
end;

------------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------------
create function pgmb.exec_tags() returns text[] immutable language sql
return array['perf', 'planning', 'errors', 'consistency', 'checksum', 'analyze'];

create procedure pgmb.configure(p_preset text, p_label text, p_data_scale text, p_conn_scale text,
                                p_write_ratio text, p_scope text, p_tags text, p_topics text,
                                p_mode text, p_protocol text, p_duration text, p_warmup text,
                                p_plan_iterations text, p_pgbench text, p_outdir text)
language plpgsql as $$
declare
    p  pgmb.preset;
    w  double precision;
    tg text[];
    cl int;
begin
    select * into p from pgmb.preset where name = lower(p_preset);
    if not found then
        raise exception 'unknown preset "%"; available: %', p_preset,
            (select string_agg(name, ', ' order by name) from pgmb.preset);
    end if;
    if p_scope not in ('rw', 'readonly', 'writeonly', 'createonly') then
        raise exception 'unknown scope "%"; available: rw, readonly, writeonly, createonly', p_scope;
    end if;

    w := case p_scope when 'readonly' then 0 when 'writeonly' then 1
                      else coalesce(nullif(p_write_ratio, '')::double precision, p.write_ratio) end;
    tg := case when p_tags = '' then p.tags
               when p_tags = 'all' then '{}'
               else string_to_array(replace(p_tags, ' ', ''), ',') end;
    cl := greatest(1, ceil(p.base_clients * coalesce(nullif(p_conn_scale, '')::double precision, 1)))::int;

    delete from pgmb.config;
    insert into pgmb.config
    values (true, p.name, nullif(p_label, ''),
            coalesce(nullif(p_data_scale, '')::double precision, p.data_scale),
            coalesce(nullif(p_conn_scale, '')::double precision, 1),
            w, p_scope,
            array(select x from unnest(tg) x where x <> all (pgmb.exec_tags())),
            array(select x from unnest(tg) x where x = any (pgmb.exec_tags())),
            case when p_topics = '' then '{}' else string_to_array(replace(p_topics, ' ', ''), ',') end,
            coalesce(nullif(p_mode, ''), p.mode), p_protocol,
            coalesce(nullif(p_duration, '')::int, p.duration),
            coalesce(nullif(p_warmup, '')::int, p.warmup),
            cl, least(cl, 16), p_plan_iterations::int, p_pgbench, p_outdir);
end $$;

create function pgmb.exec_enabled(p_tag text) returns boolean stable language sql
return (select cardinality(c.exec_tags) = 0 or p_tag = any (c.exec_tags) from pgmb.config c);

-- DML tests chosen by topic filter, tag filter and read/write scope.
create view pgmb.selected as
select t.*
from pgmb.test t, pgmb.config c
where t.phase = 'dml'
  and (cardinality(c.topics) = 0 or t.topic = any (c.topics))
  and (cardinality(c.sel_tags) = 0 or t.tags && c.sel_tags)
  and (cardinality(c.exec_tags) = 0 or t.tags && c.exec_tags)
  -- -v only=<regex> narrows the run to matching test ids
  and (coalesce(current_setting('pgmb.only', true), '') = '' or t.id ~ current_setting('pgmb.only', true))
  -- tests that need rows to mean anything are left out when the tables are empty
  and not (c.data_scale = 0 and 'needs_data' = any (t.tags))
  -- a tag named optin_<something> keeps a test out of every run that does not ask for that tag
  and not exists (select from unnest(t.tags) x where x like 'optin\_%' and x <> all (c.sel_tags))
  and (t.kind = 'read' and c.write_ratio < 1 or t.kind = 'write' and c.write_ratio > 0);

------------------------------------------------------------------------------
-- Scaling and deterministic data generators
------------------------------------------------------------------------------
create function pgmb.n(p_name text) returns bigint stable language sql
return (select greatest(d.min_rows, round(d.base_rows * power(c.data_scale, d.exponent))::bigint)
        from pgmb.dataset d, pgmb.config c where d.name = p_name);

-- Replace every :n_<dataset> token with its row count.
create function pgmb.subst_n(p_sql text) returns text stable language plpgsql as $$
declare
    r record;
begin
    for r in select name, pgmb.n(name) as n from pgmb.dataset loop
        p_sql := regexp_replace(p_sql, '(?<!:):n_' || r.name || '\M', r.n::text, 'g');
    end loop;
    return p_sql;
end $$;

-- Hash-based generators: a value depends only on (row number, salt), so data
-- is identical across runs, machines and load order. No random() anywhere.
create function pgmb.hu(i bigint, salt bigint, n bigint) returns bigint      -- uniform in [0, n)
immutable parallel safe language sql
return (hashint8extended(i, salt) & 9223372036854775807) % n;

create function pgmb.hf(i bigint, salt bigint) returns double precision      -- uniform in [0, 1)
immutable parallel safe language sql
return (hashint8extended(i, salt) & 9007199254740991)::double precision / 9007199254740992.0;

create function pgmb.hskew(i bigint, salt bigint, n bigint) returns bigint   -- skewed towards 0 in [0, n)
immutable parallel safe language sql
return floor(n * power((hashint8extended(i, salt) & 9007199254740991)::double precision / 9007199254740992.0, 3))::bigint;

create function pgmb.htext(i bigint, salt bigint, len int) returns text      -- hex text of given length
immutable parallel safe language sql
return left(repeat(md5(hashint8extended(i, salt)::text), (len + 31) / 32), len);

-- Server-side stand-in for pgbench's random_zipfian(), used only when the
-- in-database checks need parameter values. Approximate by design.
create function pgmb.random_zipfian(lo bigint, hi bigint, s double precision) returns bigint
volatile language sql
return least(hi, lo + floor((hi - lo + 1) * power(random(), 1 + 4 * s))::bigint);

------------------------------------------------------------------------------
-- DDL phase: every step is timed individually
------------------------------------------------------------------------------
create view pgmb.ddl_plan as
select t.ord, t.id,
       array_position(array['schema', 'load', 'index', 'constraint', 'maintenance'], t.kind) as stage,
       -- data_scale = 0: load steps generate no rows. Row counts used elsewhere
       -- (:n_<table> in tests) keep their minimum, so parameter expressions stay valid.
       case when t.kind = 'load' and (select data_scale from pgmb.config) = 0
            then regexp_replace(t.sql, '(?<!:):n_\w+', '0', 'g')
            else pgmb.subst_n(t.sql) end as sql
from pgmb.test t
where t.phase = 'ddl';

create procedure pgmb.step_begin(p_id text) language plpgsql as $$
begin
    perform set_config('pgmb.step_lsn', pg_current_wal_insert_lsn()::text, false);
    perform set_config('pgmb.step_t0', clock_timestamp()::text, false);
end $$;

create procedure pgmb.step_end(p_id text) language plpgsql as $$
declare
    t   pgmb.test;
    ms  double precision;
    wal bigint;
    rel regclass;
begin
    ms  := extract(epoch from clock_timestamp() - current_setting('pgmb.step_t0')::timestamptz) * 1000;
    wal := pg_current_wal_insert_lsn() - current_setting('pgmb.step_lsn')::pg_lsn;
    select * into strict t from pgmb.test where id = p_id;
    rel := to_regclass('pgmb_data.' || t.target);

    insert into pgmb_results.ddl_step (run_id, test_id, topic, kind, ord, elapsed_ms, wal_bytes, rel_bytes, n_rows)
    values (current_setting('pgmb.run_id')::bigint, t.id, t.topic, t.kind, t.ord, ms, wal,
            case when rel is null then null
                 when t.kind in ('index', 'constraint') then pg_relation_size(rel)
                 else pg_total_relation_size(rel) end,
            case when t.kind = 'load' then pgmb.n(t.target) end);
    raise info '%', format('ddl  %-44s %10s ms', t.id, to_char(ms, 'FM999999990.0'));
end $$;

------------------------------------------------------------------------------
-- In-database checks: planning, errors, consistency
------------------------------------------------------------------------------
-- Evaluate the test's "\set" lines server-side and substitute the values.
create function pgmb.bind(p_sql text, p_setup text) returns text volatile language plpgsql as $$
declare
    line  text;
    m     text[];
    v     text;
    expr  text;
    names text[] := '{client_id}';  -- pgbench's built-in variable
    vals  text[] := '{0}';
    s     text := pgmb.subst_n(p_sql);
begin
    foreach line in array string_to_array(coalesce(p_setup, ''), E'\n') loop
        m := regexp_match(line, '^\s*\\set\s+(\w+)\s+(.+?)\s*$');
        continue when m is null;
        expr := pgmb.subst_n(m[2]);
        for i in 1 .. cardinality(names) loop
            expr := regexp_replace(expr, '(?<!:):' || names[i] || '\M', vals[i], 'g');
        end loop;
        execute 'select (' || expr || ')::text' into v;
        names := names || m[1];
        vals  := vals || v;
    end loop;
    for i in 1 .. cardinality(names) loop
        s := regexp_replace(s, '(?<!:):' || names[i] || '\M', vals[i], 'g');
    end loop;
    return s;
end $$;

-- Plan shape without costs or constants: node types, relations, indexes.
create function pgmb.plan_shape(p jsonb) returns text immutable language plpgsql as $$
begin
    return concat_ws(' ', p->>'Node Type', p->>'Strategy', p->>'Partial Mode', p->>'Join Type',
                          p->>'Relation Name', p->>'Index Name')
        || coalesce(' (' || (select string_agg(pgmb.plan_shape(c), ', ' order by o)
                             from jsonb_array_elements(p->'Plans') with ordinality x(c, o)) || ')', '');
end $$;

-- A test is one query, or a transaction script of the simple form
--     begin; set local ...; [create temp table ...; analyze ...;] <one query>; commit;
-- Returns the preparing statements and the query; query is NULL for any other
-- script (several queries, cursors, DO blocks).
create function pgmb.script_parts(p_sql text, out pre text[], out query text) immutable language plpgsql as $$
declare
    stmt text;
    n    int := 0;
begin
    pre := '{}';
    if position(';' in p_sql) = 0 then
        query := p_sql;
        return;
    end if;
    if p_sql ~* '\mdo\s+\$' then
        return;
    end if;
    foreach stmt in array regexp_split_to_array(p_sql, ';\s*(\n|$)') loop
        stmt := btrim(stmt, E' \n\r\t');
        continue when stmt = '' or stmt ~* '^(begin|start transaction|commit|rollback|end)\M';
        if stmt ~* '^(set\s+local|create\s+temp|create\s+temporary|analyze)\M' then
            pre := pre || stmt;
        elsif stmt ~* '^(with|select|insert|update|delete|merge|values|table)\M' then
            n := n + 1;
            query := stmt;
        else
            query := null;
            return;
        end if;
    end loop;
    if n <> 1 then
        query := null;
    end if;
end $$;

-- Row estimates against reality and node memory, from EXPLAIN (ANALYZE, FORMAT JSON).
create function pgmb.plan_stats(p jsonb, out nodes int, out max_qerror double precision, out worst_node text,
                                out worst_est double precision, out worst_actual double precision,
                                out mem_kb bigint, out disk_kb bigint) stable language sql as $$
    with recursive n(p) as (
        select p
        union all
        select c from n, jsonb_array_elements(n.p->'Plans') c),
    x as (
        select p->>'Node Type' || coalesce(' on ' || coalesce(p->>'Relation Name', p->>'CTE Name', p->>'Alias'), '') as node,
               (p->>'Plan Rows')::double precision as est, (p->>'Actual Rows')::double precision as act,
               greatest(greatest((p->>'Plan Rows')::double precision, 1) / greatest((p->>'Actual Rows')::double precision, 1),
                        greatest((p->>'Actual Rows')::double precision, 1) / greatest((p->>'Plan Rows')::double precision, 1)) as q,
               coalesce(case when p->>'Sort Space Type' = 'Memory' then (p->>'Sort Space Used')::bigint end, 0)
                 + coalesce((p->>'Peak Memory Usage')::bigint, 0)
                 + coalesce(case when p->>'Storage' = 'Memory' then (p->>'Maximum Storage')::bigint end, 0) as mem,
               coalesce(case when p->>'Sort Space Type' = 'Disk' then (p->>'Sort Space Used')::bigint end, 0)
                 + coalesce((p->>'Disk Usage')::bigint, 0)
                 + coalesce(case when p->>'Storage' = 'Disk' then (p->>'Maximum Storage')::bigint end, 0) as disk
        from n where (p->>'Actual Loops')::double precision > 0)
    select count(*)::int, max(q), (array_agg(node order by q desc))[1], (array_agg(est order by q desc))[1],
           (array_agg(act order by q desc))[1], sum(mem)::bigint, sum(disk)::bigint
    from x
$$;

create function pgmb.client_checks() returns boolean stable language sql
return coalesce(current_setting('pgmb.client_checks', true), '1') = '1';

-- Members of a consistency group whose hashes differ are marked as failed.
create procedure pgmb.finish_consistency(p_run bigint) language sql
begin atomic
    update pgmb_results.checks c
    set ok = false, detail = c.detail || ' (differs within group ' || g.equiv || ')'
    from pgmb.test tt,
         (select t2.equiv
          from pgmb_results.checks c2 join pgmb.test t2 on t2.id = c2.test_id
          where c2.run_id = p_run and c2.check_type = 'consistency'
          group by t2.equiv having count(distinct c2.detail) > 1) g
    where c.run_id = p_run and c.check_type = 'consistency' and c.ok and tt.id = c.test_id and tt.equiv = g.equiv;
end;

-- psql commands that compute the consistency and checksum hashes on the client
-- side. Each statement is sent exactly as written (simple protocol, top level,
-- no wrapper), its rows are written to a file, read back as lines of text and
-- hashed in sorted order. SET LOCAL and temporary tables of the test are
-- executed first; everything is rolled back afterwards.
create function pgmb.check_commands() returns setof text volatile language plpgsql as $$
declare
    t     pgmb.test;
    parts record;
    stmt  text;
    typ   text;
    f     text := (select outdir from pgmb.config) || '/_check_rows.txt';
begin
    if not pgmb.client_checks() then
        return;
    end if;
    for t in select * from pgmb.selected
             where kind = 'read' and expect_error is null and (pgmb.script_parts(sql)).query is not null
               and (('consistency' = any (tags) and equiv is not null and pgmb.exec_enabled('consistency'))
                    or ('checksum' = any (tags) and pgmb.exec_enabled('checksum')))
             order by ord loop
        typ := case when 'consistency' = any (t.tags) and t.equiv is not null and pgmb.exec_enabled('consistency')
                    then 'consistency' else 'checksum' end;
        begin
            perform setseed(0.42);       -- same parameter values for every member of a group, and in every run
            parts := pgmb.script_parts(pgmb.bind(t.sql, t.setup));
        exception when others then
            return next format('insert into pgmb_results.checks values (:run_id, %L, %L, false, %L);',
                               t.id, typ, sqlstate || ': ' || sqlerrm);
            continue;
        end;
        return next 'begin;';
        foreach stmt in array parts.pre loop
            return next stmt || ';';
        end loop;
        return next parts.query;
        return next format('\g (format=unaligned tuples_only=on null=~NULL~) %s', f);
        return next '\set pgmb_err :ERROR';
        return next 'rollback;';
        return next '\if :pgmb_err';
        return next format('insert into pgmb_results.checks values (:run_id, %L, %L, false, '
                           ':''LAST_ERROR_SQLSTATE'' || '': '' || :''LAST_ERROR_MESSAGE'');', t.id, typ);
        return next '\else';
        return next 'truncate pgmb_rows;';
        return next format('\copy pgmb_rows from ''%s'' with (format csv, delimiter E''\x02'', quote E''\x01'')', f);
        return next format('insert into pgmb_results.checks select :run_id, %L, %L, true, '
                           'md5(coalesce(string_agg(line, chr(10) order by line), '''')) || '' rows='' || count(*) from pgmb_rows;',
                           t.id, typ);
        return next '\endif';
    end loop;
end $$;

create procedure pgmb.run_checks(p_run bigint) language plpgsql as $$
declare
    t      pgmb.test;
    iters  int := (select plan_iterations from pgmb.config);
    j      json;
    times  double precision[];
    shapes text[];
    mem    bigint;
    h      text;
    parts  record;
    st     record;
    stmt   text;
begin
    -- planning: time, memory and stability of the plan shape across parameter values
    if pgmb.exec_enabled('planning') then
        for t in select * from pgmb.selected
                 where 'planning' = any (tags) and expect_error is null
                   and (pgmb.script_parts(sql)).query is not null
                 order by ord loop
            -- the block is always left through an exception, so that SET LOCAL
            -- and temporary tables of the test are rolled back
            begin
                parts := pgmb.script_parts(pgmb.bind(t.sql, t.setup));
                foreach stmt in array parts.pre loop execute stmt; end loop;
                times := '{}'; shapes := '{}'; mem := 0;
                for i in 1 .. iters loop
                    execute 'explain (format json, costs off, summary on, memory on) '
                            || (pgmb.script_parts(pgmb.bind(t.sql, t.setup))).query into j;
                    times  := times || (j->0->>'Planning Time')::double precision;
                    shapes := shapes || pgmb.plan_shape((j->0->'Plan')::jsonb);
                    mem    := greatest(mem, (j->0->'Planning'->>'Memory Used')::bigint);
                end loop;
                raise exception using errcode = 'PGMB0';
            exception
                when sqlstate 'PGMB0' then
                    insert into pgmb_results.planning
                    select p_run, t.id, iters, min(tm), percentile_cont(0.5) within group (order by tm), max(tm),
                           mem, count(distinct sh), mode() within group (order by sh)
                    from unnest(times, shapes) u(tm, sh);
                when others then
                    insert into pgmb_results.checks values (p_run, t.id, 'planning', false, sqlstate || ': ' || sqlerrm);
            end;
        end loop;
    end if;

    -- analyze: one EXPLAIN ANALYZE per test, for row estimates and node memory.
    -- Writers are executed too; like everything else here they are rolled back.
    if pgmb.exec_enabled('analyze') then
        for t in select * from pgmb.selected
                 where 'analyze' = any (tags) and expect_error is null
                   and (pgmb.script_parts(sql)).query is not null
                 order by ord loop
            begin
                perform setseed(0.42);
                parts := pgmb.script_parts(pgmb.bind(t.sql, t.setup));
                foreach stmt in array parts.pre loop execute stmt; end loop;
                execute 'explain (analyze, format json, timing off, buffers off, summary off) ' || parts.query into j;
                raise exception using errcode = 'PGMB0';
            exception
                when sqlstate 'PGMB0' then
                    select * into st from pgmb.plan_stats((j->0->'Plan')::jsonb);
                    insert into pgmb_results.explain_stats
                    values (p_run, t.id, st.nodes, st.max_qerror, st.worst_node, st.worst_est, st.worst_actual,
                            (j->0->'Plan'->>'Plan Rows')::double precision, (j->0->'Plan'->>'Actual Rows')::double precision,
                            st.mem_kb, st.disk_kb, pgmb.plan_shape((j->0->'Plan')::jsonb));
                when others then
                    insert into pgmb_results.checks values (p_run, t.id, 'analyze', false, sqlstate || ': ' || sqlerrm);
            end;
        end loop;
    end if;

    -- errors: the statement must fail with the expected SQLSTATE
    if pgmb.exec_enabled('errors') then
        for t in select * from pgmb.selected
                 where 'errors' = any (tags) and expect_error is not null order by ord loop
            begin
                -- SET LOCAL in front of the statement is honoured, as in the other checks
                parts := pgmb.script_parts(pgmb.bind(t.sql, t.setup));
                if parts.query is not null then
                    foreach stmt in array parts.pre loop execute stmt; end loop;
                    execute parts.query;
                else
                    execute pgmb.bind(t.sql, t.setup);
                end if;
                -- no error: leave through an exception anyway, so that whatever
                -- the statement did (an index, a row) is rolled back
                raise exception using errcode = 'PGMB0';
            exception
                when sqlstate 'PGMB0' then
                    insert into pgmb_results.checks
                    values (p_run, t.id, 'errors', false, 'expected ' || t.expect_error || ', got no error');
                -- OTHERS does not include query_canceled, which the cancel tests expect
                when query_canceled or others then
                    insert into pgmb_results.checks
                    values (p_run, t.id, 'errors', sqlstate = t.expect_error,
                            case when sqlstate = t.expect_error then sqlstate
                                 else 'expected ' || t.expect_error || ', got ' || sqlstate || ': ' || sqlerrm end);
            end;
        end loop;
    end if;

    -- consistency and checksum hash the rows a statement returns. By default that is
    -- done on the client side (pgmb.check_commands): the statement is sent
    -- unchanged, as an application would send it. The loops below are the
    -- in-database variant (-v client_checks=0), which has to wrap the statement
    -- in a subquery and therefore plans a slightly different query.

    -- consistency: all members of an equivalence group must return the same set of rows
    if pgmb.exec_enabled('consistency') and not pgmb.client_checks() then
        for t in select * from pgmb.selected
                 where 'consistency' = any (tags) and equiv is not null and kind = 'read'
                   and (pgmb.script_parts(sql)).query is not null
                 order by ord loop
            begin
                perform setseed(0.42);       -- same parameter values for every member of the group
                parts := pgmb.script_parts(pgmb.bind(t.sql, t.setup));
                foreach stmt in array parts.pre loop execute stmt; end loop;
                execute format('select md5(coalesce(string_agg(x::text, chr(10) order by x::text), '''')) '
                               '|| '' rows='' || count(*) from (%s) x', parts.query) into h;
                raise exception using errcode = 'PGMB0';
            exception
                when sqlstate 'PGMB0' then
                    insert into pgmb_results.checks values (p_run, t.id, 'consistency', true, h);
                when others then
                    insert into pgmb_results.checks values (p_run, t.id, 'consistency', false, sqlstate || ': ' || sqlerrm);
            end;
        end loop;

        call pgmb.finish_consistency(p_run);
    end if;

    -- checksum: hash of the whole result, independent of row order, to compare
    -- the same test between two runs (report/compare.sql). Tests that are in a
    -- consistency group already have one.
    if pgmb.exec_enabled('checksum') and not pgmb.client_checks() then
        for t in select * from pgmb.selected
                 where 'checksum' = any (tags) and kind = 'read' and expect_error is null
                   and (pgmb.script_parts(sql)).query is not null
                   and not ('consistency' = any (tags) and equiv is not null and pgmb.exec_enabled('consistency'))
                 order by ord loop
            begin
                perform setseed(0.42);
                parts := pgmb.script_parts(pgmb.bind(t.sql, t.setup));
                foreach stmt in array parts.pre loop execute stmt; end loop;
                execute format('select md5(coalesce(string_agg(x::text, chr(10) order by x::text), '''')) '
                               '|| '' rows='' || count(*) from (%s) x', parts.query) into h;
                raise exception using errcode = 'PGMB0';
            exception
                when sqlstate 'PGMB0' then
                    insert into pgmb_results.checks values (p_run, t.id, 'checksum', true, h);
                when others then
                    insert into pgmb_results.checks values (p_run, t.id, 'checksum', false, sqlstate || ': ' || sqlerrm);
            end;
        end loop;
    end if;
end $$;

------------------------------------------------------------------------------
-- pgbench: script generation and result parsing
------------------------------------------------------------------------------
create view pgmb.perf_tests as
select s.*, c.outdir || '/' || s.id || '.sql' as path
from pgmb.selected s, pgmb.config c
where 'perf' = any (s.tags) and s.expect_error is null and pgmb.exec_enabled('perf');

-- Self-contained pgbench script for one test.
create function pgmb.script(p_id text) returns text stable language sql
return (
    select '-- pgmb test ' || t.id || E'\n'
        || coalesce((select string_agg(format(E'\\set n_%s %s\n', d.name, pgmb.n(d.name)), '' order by d.name)
                     from pgmb.dataset d
                     where b.body ~ ('(?<!:):n_' || d.name || '\M')), '')
        || b.body || case when b.body ~ ';\s*$' then '' else ';' end || E'\n'
    from pgmb.test t, lateral (select coalesce(t.setup || E'\n', '') || t.sql as body) b
    where t.id = p_id);

-- psql commands that write one script file per selected test.
create function pgmb.emit_commands() returns setof text stable language sql
begin atomic
    select format('select pgmb.script(%L) \g %s', id, path) from pgmb.perf_tests order by ord;
end;

-- psql commands that load pgbench's per-transaction log (one line per
-- transaction, files <prefix>.<pid>[.<thread>]) and turn it into a histogram.
-- A failed load must not abort the run, hence ON_ERROR_STOP off.
create function pgmb.latency_commands(p_prefix text, p_test text) returns setof text stable language sql
begin atomic
    select x.cmd
    from (values (1, '\set ON_ERROR_STOP off'),
                 (2, 'truncate pgmb_log;'),
                 (3, format('\copy pgmb_log from program %L with (delimiter %L)',
                            current_setting('pgmb.cat') || ' ' || p_prefix || '.*', ' ')),
                 (4, format('call pgmb.store_latency(:run_id, %L);', p_test)),
                 (5, '\set ON_ERROR_STOP on')) x(i, cmd)
    order by x.i;
end;

-- Aggregate the loaded log: percentiles plus a log-scale histogram with four
-- buckets per decade (bucket = floor(4 * log10(microseconds))).
-- p_test null = mixed workload, tests are told apart by script number.
create procedure pgmb.store_latency(p_run bigint, p_test text) language plpgsql as $$
begin
    create temp table pgmb_lat on commit drop as
    select coalesce(p_test, m.id) as test_id, g.us::bigint as us
    from pgmb_log g
    left join (select id, row_number() over (order by ord) - 1 as script from pgmb.perf_tests) m
           on m.script = g.script
    where g.us ~ '^\d+$';                    -- failed transactions carry no time

    insert into pgmb_results.latency_hist
    select p_run, test_id, floor(4 * log(greatest(us, 1)::double precision))::int, count(*)
    from pgmb_lat where test_id is not null group by 1, 2, 3;

    insert into pgmb_results.latency
    select p_run, test_id,
           percentile_cont(0.50) within group (order by us) / 1000,
           percentile_cont(0.95) within group (order by us) / 1000,
           percentile_cont(0.99) within group (order by us) / 1000,
           max(us) / 1000.0
    from pgmb_lat where test_id is not null group by test_id;
    drop table pgmb_lat;
end $$;

-- psql commands that run pgbench and store its output.
create function pgmb.run_commands() returns setof text stable language plpgsql as $$
declare
    c     pgmb.config;
    base  text;
    logp  text;
    files text;
    r     record;
    n     int;
begin
    select * into strict c from pgmb.config;
    select count(*) into n from pgmb.perf_tests;

    if c.mode = 'isolated' or n = 1 then
        -- a test may fix its own query protocol (isolated mode only)
        for r in select id, path, protocol from pgmb.perf_tests order by ord loop
            base := format('%s -n -M %s -c %s -j %s --max-tries=10', c.pgbench_bin,
                           coalesce(r.protocol, c.protocol), c.clients, c.jobs);
            return next format('\echo perf %s', r.id);
            if c.warmup > 0 then
                return next format('\set pgmb_out `%s -T %s -f %s 2>&1`', base, c.warmup, r.path);
            end if;
            logp := format('%s/log_r%s_%s', c.outdir, current_setting('pgmb.run_id'), r.id);
            -- temporary files and WAL written while the test runs
            return next 'select temp_files as pgmb_tf0, temp_bytes as pgmb_tb0, pg_current_wal_insert_lsn() as pgmb_lsn0 '
                        'from pg_stat_database where datname = current_database() \gset';
            return next format('\set pgmb_out `%s %s --log --log-prefix=%s -f %s 2>&1`',
                               base, case when c.duration = 0 then '-t 1' else format('-T %s -P %s', c.duration, c.duration) end,
                               logp, r.path);
            -- the pgbench backends report their statistics when they exit
            return next format('select pg_sleep(0.02) \gset pgmb_ignore_');
            return next format('insert into pgmb_results.resource select :run_id, %L, temp_files - :pgmb_tf0, temp_bytes - :pgmb_tb0, '
                               'pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :''pgmb_lsn0'') '
                               'from pg_stat_database where datname = current_database();', r.id);
            return next format('insert into pgmb_results.pgbench_raw (run_id, test_id, clients, cmd, output) '
                               'values (:run_id, %L, %s, %L, :''pgmb_out'');',
                               r.id, c.clients, format('%s -T %s -f %s', base, c.duration, r.path));
            return query select pgmb.latency_commands(logp, r.id);
        end loop;
    elsif n > 1 then
        base := format('%s -n -M %s -c %s -j %s --max-tries=10', c.pgbench_bin, c.protocol, c.clients, c.jobs);
        -- Weights: reads share (1 - write_ratio) of transactions, writes share write_ratio.
        select string_agg(format('-f %s@%s', path, greatest(1, round(10000 * share)::int)), ' ' order by ord)
        into files
        from (select p.ord, p.path,
                     case when every(p.kind = 'read') over () or every(p.kind = 'write') over () then 1
                          when p.kind = 'read' then 1 - c.write_ratio else c.write_ratio end
                     * p.weight / sum(p.weight) over (partition by p.kind) as share
              from pgmb.perf_tests p) s;
        return next format('\echo perf mixed workload, %s tests, %s clients, %s s', n, c.clients, c.duration);
        if c.warmup > 0 then
            return next format('\set pgmb_out `%s -T %s %s 2>&1`', base, c.warmup, files);
        end if;
        logp := format('%s/log_r%s_mixed', c.outdir, current_setting('pgmb.run_id'));
        return next format('\set pgmb_out `%s -T %s -P %s --log --log-prefix=%s %s`',
                           base, greatest(c.duration, 1), least(greatest(c.duration, 1), 5), logp, files);
        return next format('insert into pgmb_results.pgbench_raw (run_id, test_id, clients, cmd, output) '
                           'values (:run_id, null, %s, %L, :''pgmb_out'');',
                           c.clients, format('%s -T %s %s', base, c.duration, files));
        return query select pgmb.latency_commands(logp, null);
    end if;
end $$;

create procedure pgmb.parse_pgbench(p_run bigint) language plpgsql as $$
declare
    r   record;
    sec text;
    m   text[];
begin
    for r in select * from pgmb_results.pgbench_raw where run_id = p_run order by seq loop
        if r.test_id is not null then
            insert into pgmb_results.perf
            values (p_run, r.test_id, 'isolated', r.clients,
                    (regexp_match(r.output, 'number of transactions actually processed: (\d+)'))[1]::bigint,
                    (regexp_match(r.output, 'number of failed transactions: (\d+)'))[1]::bigint,
                    (regexp_match(r.output, 'tps = ([0-9.]+) \(without'))[1]::double precision,
                    (regexp_match(r.output, 'latency average = ([0-9.]+) ms'))[1]::double precision,
                    (regexp_match(r.output, 'latency stddev = ([0-9.]+) ms'))[1]::double precision);
        else
            for sec in select x.s from regexp_split_to_table(r.output, E'\nSQL script \\d+: ') with ordinality x(s, i)
                       where x.i > 1 loop
                m := regexp_match(sec, 'number of transactions actually processed: (\d+) \(tps = ([0-9.]+)\)');
                insert into pgmb_results.perf
                values (p_run, regexp_replace(split_part(sec, E'\n', 1), '^.*/|\.sql\s*$', '', 'g'), 'mixed', r.clients,
                        m[1]::bigint,
                        (regexp_match(sec, 'number of failed transactions: (\d+)'))[1]::bigint,
                        m[2]::double precision,
                        (regexp_match(sec, 'latency average = ([0-9.]+) ms'))[1]::double precision,
                        (regexp_match(sec, 'latency stddev = ([0-9.]+) ms'))[1]::double precision);
            end loop;
        end if;
    end loop;
end $$;

------------------------------------------------------------------------------
-- Run bookkeeping
------------------------------------------------------------------------------
create function pgmb.start_run() returns bigint volatile language sql
begin atomic
    insert into pgmb_results.run (label, preset, config, server_version, version_num, settings)
    select c.label, c.preset, to_jsonb(c) - 'one', current_setting('server_version'),
           current_setting('server_version_num')::int,
           coalesce((select jsonb_object_agg(s.name, s.setting) from pg_settings s
                     where s.source not in ('default', 'override')), '{}')
    from pgmb.config c
    returning run_id;
end;
