-- Persistent result store. Survives runs; never dropped by the benchmark.
create schema if not exists pgmb_results;

create table if not exists pgmb_results.run (
    run_id         bigint generated always as identity primary key,
    label          text,
    started_at     timestamptz not null default clock_timestamp(),
    finished_at    timestamptz,
    preset         text not null,
    config         jsonb not null,
    server_version text not null,
    version_num    int  not null,
    settings       jsonb not null          -- pg_settings changed from built-in defaults
);

create table if not exists pgmb_results.ddl_step (
    run_id     bigint not null references pgmb_results.run on delete cascade,
    test_id    text   not null,
    topic      text   not null,
    kind       text   not null,
    ord        int    not null,
    elapsed_ms double precision not null,
    wal_bytes  bigint,
    rel_bytes  bigint,                     -- size of the step's target relation afterwards
    n_rows     bigint,                     -- generated rows (load steps)
    primary key (run_id, test_id)
);

create table if not exists pgmb_results.pgbench_raw (
    run_id  bigint not null references pgmb_results.run on delete cascade,
    seq     bigint generated always as identity,
    test_id text,                          -- null = mixed workload
    clients int,
    cmd     text not null,
    output  text
);

create table if not exists pgmb_results.perf (
    run_id        bigint not null references pgmb_results.run on delete cascade,
    test_id       text   not null,
    mode          text   not null,         -- isolated | mixed
    clients       int    not null,
    transactions  bigint,
    failed        bigint,
    tps           double precision,
    lat_avg_ms    double precision,
    lat_stddev_ms double precision,
    primary key (run_id, test_id)
);

create table if not exists pgmb_results.planning (
    run_id         bigint not null references pgmb_results.run on delete cascade,
    test_id        text   not null,
    iterations     int    not null,
    plan_ms_min    double precision,
    plan_ms_median double precision,
    plan_ms_max    double precision,
    mem_kb_max     bigint,                 -- planner memory used
    distinct_plans int,                    -- 1 = plan shape stable across parameters
    plan_shape     text,                   -- most frequent shape
    primary key (run_id, test_id)
);

create table if not exists pgmb_results.checks (
    run_id     bigint not null references pgmb_results.run on delete cascade,
    test_id    text   not null,
    check_type text   not null,            -- errors | consistency | checksum | planning | analyze
    ok         boolean not null,
    detail     text,
    primary key (run_id, test_id, check_type)
);

-- one EXPLAIN ANALYZE per test tagged "analyze": how far the planner's row
-- estimates were from reality, and what the plan nodes held in memory or on disk
create table if not exists pgmb_results.explain_stats (
    run_id       bigint not null references pgmb_results.run on delete cascade,
    test_id      text   not null,
    nodes        int    not null,          -- executed plan nodes
    max_qerror   double precision,         -- worst max(est/actual, actual/est) over the nodes
    worst_node   text,                     -- the node with that error
    worst_est    double precision,
    worst_actual double precision,
    root_est     double precision,         -- rows estimated / returned by the top node
    root_actual  double precision,
    mem_kb       bigint,                   -- sorts, hashes and tuple stores kept in memory, summed
    disk_kb      bigint,                   -- the same that went to temporary files
    plan_shape   text,
    primary key (run_id, test_id)
);

-- the full plan of the last EXPLAIN ANALYZE of the analyze check (the top-level
-- query only), as PostgreSQL printed it; json, not jsonb, so that the keys keep
-- EXPLAIN's order. exec_ms: Execution Time of every TIMING OFF execution, in order.
create table if not exists pgmb_results.explain_plan (
    run_id  bigint not null references pgmb_results.run on delete cascade,
    test_id text   not null,
    plan    json   not null,
    exec_ms double precision[],
    primary key (run_id, test_id)
);

-- Figures from one stored plan that can be compared between runs. Counters are
-- totals over the whole query (the top node's buffers and WAL include its
-- children; rows are actual rows times loops); a figure the plan does not
-- carry (an older run, another server version) is NULL.
drop view if exists pgmb_results.explain_metrics;
drop function if exists pgmb_results.plan_metrics(json, double precision[]);
create function pgmb_results.plan_metrics(
    p_plan json, p_exec_ms double precision[],
    out iterations int,
    out exec_ms_min double precision,      -- Execution Time, best and median of the TIMING OFF executions
    out exec_ms_med double precision,
    out plan_ms double precision,          -- Planning Time
    out plan_mem_kb bigint,                -- planner memory
    out plan_blocks bigint,                -- shared buffers the planner touched (catalogs, statistics)
    out rows_processed double precision,   -- rows returned by all nodes: the work the plan did
    out rows_removed double precision,     -- rows read and thrown away by filters, join filters and rechecks
    out blocks_hit bigint,                 -- shared and local buffers found in shared buffers
    out blocks_read bigint,                -- ... and read from the OS
    out blocks_dirtied bigint,
    out blocks_written bigint,
    out temp_blocks bigint,                -- temporary file blocks read and written: spills
    out wal_records bigint,
    out wal_fpi bigint,
    out wal_bytes bigint,
    out heap_fetches bigint,               -- index-only scans that had to visit the heap
    out index_searches bigint,
    out lossy_blocks bigint,               -- bitmap heap scans that ran out of work_mem
    out workers_planned int,
    out workers_launched int,
    out output_kb bigint,                  -- result size after conversion to text (SERIALIZE)
    out node_timing boolean)               -- the plan carries node timings (analyze_timing)
stable language sql as $$
    with recursive n(p) as (
        select p_plan::jsonb->'Plan'
        union all
        select c from n, jsonb_array_elements(n.p->'Plans') c),
    x as (
        select sum((p->>'Actual Rows')::float8 * (p->>'Actual Loops')::float8) as rows_processed,
               sum((coalesce((p->>'Rows Removed by Filter')::float8, 0)
                    + coalesce((p->>'Rows Removed by Join Filter')::float8, 0)
                    + coalesce((p->>'Rows Removed by Index Recheck')::float8, 0)) * (p->>'Actual Loops')::float8) as rows_removed,
               sum((p->>'Heap Fetches')::bigint) as heap_fetches,
               sum((p->>'Index Searches')::bigint) as index_searches,
               sum((p->>'Lossy Heap Blocks')::bigint) as lossy_blocks,
               coalesce(sum((p->>'Workers Planned')::int), 0) as workers_planned,
               coalesce(sum((p->>'Workers Launched')::int), 0) as workers_launched,
               bool_or(p ? 'Actual Total Time') as node_timing
        from n)
    select cardinality(p_exec_ms),
           (select min(e) from unnest(p_exec_ms) e),
           (select percentile_cont(0.5) within group (order by e) from unnest(p_exec_ms) e),
           (j->>'Planning Time')::float8,
           (j->'Planning'->>'Memory Used')::bigint,
           (j->'Planning'->>'Shared Hit Blocks')::bigint + (j->'Planning'->>'Shared Read Blocks')::bigint,
           x.rows_processed, x.rows_removed,
           (r->>'Shared Hit Blocks')::bigint + (r->>'Local Hit Blocks')::bigint,
           (r->>'Shared Read Blocks')::bigint + (r->>'Local Read Blocks')::bigint,
           (r->>'Shared Dirtied Blocks')::bigint + (r->>'Local Dirtied Blocks')::bigint,
           (r->>'Shared Written Blocks')::bigint + (r->>'Local Written Blocks')::bigint,
           (r->>'Temp Read Blocks')::bigint + (r->>'Temp Written Blocks')::bigint,
           (r->>'WAL Records')::bigint, (r->>'WAL FPI')::bigint, (r->>'WAL Bytes')::bigint,
           x.heap_fetches, x.index_searches, x.lossy_blocks, x.workers_planned, x.workers_launched,
           (j->'Serialization'->>'Output Volume')::bigint,
           x.node_timing
    from x, lateral (select p_plan::jsonb as j) jj, lateral (select jj.j->'Plan' as r) rr
$$;

create view pgmb_results.explain_metrics as
select e.run_id, e.test_id, m.*
from pgmb_results.explain_plan e, pgmb_results.plan_metrics(e.plan, e.exec_ms) m;

-- Two figures differ by more than the tolerance (default 10 %); values below
-- the floor count as the floor, so that 0 against 1 block is no difference.
-- NULL on either side (a run that did not collect the figure) is no difference.
create or replace function pgmb_results.differs(a double precision, b double precision,
                                                tol double precision default 0.1,
                                                floor double precision default 1) returns boolean
immutable language sql
return a is not null and b is not null
       and greatest(a, floor) / greatest(b, floor) not between 1 / (1 + tol) and 1 + tol;

-- what one test's pgbench run cost outside the query results (isolated mode)
create table if not exists pgmb_results.resource (
    run_id     bigint not null references pgmb_results.run on delete cascade,
    test_id    text   not null,
    temp_files bigint,                     -- temporary files created in the database during the run
    temp_bytes bigint,
    wal_bytes  bigint,
    primary key (run_id, test_id)
);

create or replace view pgmb_results.run_overview as
select r.run_id, r.label, r.preset, r.started_at::timestamptz(0) as started,
       (r.finished_at - r.started_at)::interval(0) as took,
       r.config->>'data_scale' as data_scale, r.config->>'clients' as clients,
       r.config->>'write_ratio' as write_ratio, r.config->>'scope' as scope,
       r.server_version,
       (select round(sum(elapsed_ms)::numeric / 1000, 2) from pgmb_results.ddl_step d where d.run_id = r.run_id) as ddl_s,
       (select count(*) from pgmb_results.perf p where p.run_id = r.run_id) as perf_tests,
       (select count(*) from pgmb_results.checks c where c.run_id = r.run_id and not c.ok) as failed_checks
from pgmb_results.run r;

-- Latency distribution from pgbench's per-transaction log.
create table if not exists pgmb_results.latency (
    run_id  bigint not null references pgmb_results.run on delete cascade,
    test_id text   not null,
    p50_ms  double precision,
    p95_ms  double precision,
    p99_ms  double precision,
    max_ms  double precision,
    primary key (run_id, test_id)
);

-- Log-scale histogram, four buckets per decade:
-- bucket b holds latencies in [10^(b/4), 10^((b+1)/4)) microseconds.
create table if not exists pgmb_results.latency_hist (
    run_id  bigint not null references pgmb_results.run on delete cascade,
    test_id text   not null,
    bucket  int    not null,
    n       bigint not null,
    primary key (run_id, test_id, bucket)
);

create or replace function pgmb_results.bucket_ms(b int) returns double precision
immutable language sql
return power(10::double precision, b / 4.0) / 1000;

-- One-line histogram: 24 characters covering 0.01 ms .. 10 s, four per decade.
-- Bar height is linear in the transaction count; any non-empty bucket shows at least the lowest bar.
create or replace function pgmb_results.sparkline(p_run bigint, p_test text) returns text
stable language sql
return (
    select '|' || string_agg(case when h.n is null then ' '
                                  else substr('▁▂▃▄▅▆▇█', 1 + (7 * h.n / h.mx)::int, 1) end, '' order by b) || '|'
    from generate_series(4, 27) b
    left join (select least(27, greatest(4, bucket)) as cb, sum(n) as n, max(sum(n)) over () as mx
               from pgmb_results.latency_hist
               where run_id = p_run and test_id = p_test
               group by 1) h on h.cb = b);
