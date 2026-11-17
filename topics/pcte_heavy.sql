-- Topic: pcte (part 2) - CTEs that are heavy on their own: elements bound by
-- disk reads, elements bound by computation, and the cost of handing their
-- results on to the next element. Written, like pcte.sql, to be run twice
-- under different server settings and compared; on a stock server every test
-- gives the serial baseline. Each element is a MATERIALIZED top-level CTE.
--
-- Sizes follow data_scale. For reads to really come from disk the tables must
-- be larger than shared_buffers (and than the memory of the machine): run with
-- a large data_scale, e.g. -v data_scale=60 gives g_narrow 60M rows and g_wide
-- 12M wide rows. io_method only changes with a server restart, so it is
-- compared between runs, not inside one.
--
-- report/pcte_gain.sql shows, for each test, the time of every CTE, their sum,
-- the longest one, the gain the sum minus the longest one leaves, and how many
-- bytes the CTEs handed on.
--
-- Not possible here: tables on several tablespaces (they need directories on
-- the server's file system), and an operating system cache that is cold.

\set pgmb_ph_tags '{perf,planning,checksum,olap,consistency}'

------------------------------------------------------------------------------
-- 1. elements bound by disk reads
------------------------------------------------------------------------------
-- g_wide: wide rows, almost no work per row. One element reading the whole
-- table sequentially, through an index in random order, and through a bitmap.
call pgmb.reg('pcte.io_one_seq_scan', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) as n, sum(i4) as s from g_wide)
select n, s from a$q$);
call pgmb.reg('pcte.io_one_random_index_reads', '{perf,planning,checksum,olap}', $q$
begin;
set local enable_seqscan = off;
set local enable_bitmapscan = off;
set local enable_indexonlyscan = off;
with a as materialized (select count(*) as n, sum(length(pad)) as s from g_narrow where k_10k < 1000)
select n, s from a;
commit;$q$);
call pgmb.reg('pcte.io_one_bitmap_reads', '{perf,planning,checksum,olap}', $q$
begin;
set local enable_seqscan = off;
set local enable_indexscan = off;
set local enable_indexonlyscan = off;
with a as materialized (select count(*) as n, sum(length(pad)) as s from g_narrow where k_10k < 1000)
select n, s from a;
commit;$q$);

-- 2, 4 and 8 elements, each reading its own contiguous slice of g_wide (an
-- index range on the primary key, so that no two elements read the same
-- pages): with the elements in parallel the disk serves them all at once
select format('call pgmb.reg(%L, %L, %L, equiv => %L)', format('pcte.io_independent_%s', n), :'pgmb_ph_tags',
              E'begin;\nset local enable_seqscan = off;\nwith '
              || string_agg(format('c%1$s as materialized (select count(*) as n, sum(i4) as s from g_wide '
                                   'where id > %1$s * :n_g_wide / %2$s and id <= (%1$s + 1) * :n_g_wide / %2$s)', i, n), ', ' order by i)
              || E'\nselect sum(n), sum(s) from (' || string_agg(format('select n, s from c%s', i), ' union all ' order by i)
              || E') u;\ncommit;',
              'pcte.io_whole_wide')
from (values (2), (4), (8)) v(n), lateral generate_series(0, n - 1) i
group by n \gexec
call pgmb.reg('pcte.io_independent_reference_one_scan', '{perf,planning,checksum,olap,consistency}', $q$
select count(*), sum(i4) from g_wide$q$, equiv => 'pcte.io_whole_wide');

-- the same eight slices with the prefetch and read combining settings at
-- their extremes (io_method itself needs a restart)
select format('call pgmb.reg(%L, %L, %L)', format('pcte.io_independent_8_%s', lbl), :'pgmb_ph_tags',
              E'begin;\nset local enable_seqscan = off;\n' || settings || 'with '
              || (select string_agg(format('c%1$s as materialized (select count(*) as n, sum(i4) as s from g_wide '
                                           'where id > %1$s * :n_g_wide / 8 and id <= (%1$s + 1) * :n_g_wide / 8)', i), ', ' order by i)
                  from generate_series(0, 7) i)
              || E'\nselect sum(n), sum(s) from ('
              || (select string_agg(format('select n, s from c%s', i), ' union all ' order by i) from generate_series(0, 7) i)
              || E') u;\ncommit;')
from (values ('io_concurrency_1', E'set local effective_io_concurrency = 1;\n'),
             ('io_concurrency_256', E'set local effective_io_concurrency = 256;\n'),
             ('io_combine_8kb', E'set local io_combine_limit = ''8kB'';\n')) v(lbl, settings) \gexec

-- a cold and a warm shared_buffers: evicting the table's buffers needs
-- pg_buffercache 1.6 (PostgreSQL 18) and a superuser
select exists (select from pg_available_extension_versions where name = 'pg_buffercache' and version >= '1.6')
       and (select rolsuper from pg_roles where rolname = current_user) as pgmb_ph_evict \gset
\if :pgmb_ph_evict
call pgmb.reg_ddl('pcte.create_pg_buffercache', 'schema', $q$create extension if not exists pg_buffercache with schema pgmb_data$q$);
call pgmb.reg('pcte.io_cold_shared_buffers', '{perf}', $q$
select pg_buffercache_evict_relation('pgmb_data.g_wide'::regclass);
with a as materialized (select count(*) as n, sum(i4) as s from g_wide where id % 2 = 0),
     b as materialized (select count(*) as n, sum(i4) as s from g_wide where id % 2 = 1)
select a.n, a.s, b.n, b.s from a, b;$q$);
call pgmb.reg('pcte.io_warm_shared_buffers', '{perf}', $q$
with a as materialized (select count(*) as n, sum(i4) as s from g_wide where id % 2 = 0),
     b as materialized (select count(*) as n, sum(i4) as s from g_wide where id % 2 = 1)
select a.n, a.s, b.n, b.s from a, b;$q$);
\endif

------------------------------------------------------------------------------
-- 2. elements bound by computation
------------------------------------------------------------------------------
-- kinds of work per row, two independent elements each
call pgmb.reg_ddl('pcte.create_heavy_functions', 'schema', $q$
-- a little PL/pgSQL per row
create function pcte_work(t text) returns int language plpgsql immutable parallel safe as
$f$declare
    h int := 0;
begin
    for i in 1 .. 20 loop
        h := (h * 31 + ascii(substr(t, 1 + (i % length(t)), 1))) % 1000003;
    end loop;
    return h;
end$f$;
-- a function that keeps rows on their way to the leader: parallel restricted
create function pcte_pass(t text) returns int language sql parallel restricted as 'select length(t)'$q$);

call pgmb.reg('pcte.cpu_md5_chain', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) as n, sum(length(md5(md5(md5(pad))))) as s from g_narrow where id % 2 = 0),
     b as materialized (select count(*) as n, sum(length(md5(md5(md5(pad))))) as s from g_narrow where id % 2 = 1)
select a.n, a.s, b.n, b.s from a, b$q$);
call pgmb.reg('pcte.cpu_regex', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) filter (where pad ~ '^[0-9a-f]*(ab|cd)[0-9]+e') as n from g_narrow where id % 2 = 0),
     b as materialized (select count(*) filter (where pad ~ '^[0-9a-f]*(ab|cd)[0-9]+e') as n from g_narrow where id % 2 = 1)
select a.n, b.n from a, b$q$);
call pgmb.reg('pcte.cpu_numeric_math', '{perf,planning,checksum,olap}', $q$
with a as materialized (select sum(sqrt(k_10k::numeric + 1) * ln(k_100::numeric + 2)) as s from g_narrow where id % 2 = 0),
     b as materialized (select sum(sqrt(k_10k::numeric + 1) * ln(k_100::numeric + 2)) as s from g_narrow where id % 2 = 1)
select round(a.s, 6), round(b.s, 6) from a, b$q$);
call pgmb.reg('pcte.cpu_plpgsql_per_row', '{perf,planning,checksum,olap}', $q$
with a as materialized (select sum(pcte_work(pad)) as s from g_narrow where id % 2 = 0),
     b as materialized (select sum(pcte_work(pad)) as s from g_narrow where id % 2 = 1)
select a.s, b.s from a, b$q$);

-- heavy operators: a window, a hash join, a long recursion
call pgmb.reg('pcte.cpu_window', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) filter (where rn = 1) as n
                        from (select row_number() over (partition by k_10k order by pad) as rn from g_narrow where id % 2 = 0) s),
     b as materialized (select count(*) filter (where rn = 1) as n
                        from (select row_number() over (partition by k_10k order by pad) as rn from g_narrow where id % 2 = 1) s)
select a.n, b.n from a, b$q$);
call pgmb.reg('pcte.cpu_hash_join', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) as n from g_narrow x join g_narrow y on y.k_uniq = x.id where x.id % 2 = 0),
     b as materialized (select count(*) as n from g_child x join g_parent y on y.id = x.parent_id where x.id % 2 = 1)
select a.n, b.n from a, b$q$);
call pgmb.reg('pcte.cpu_long_recursion', '{perf,planning,checksum,olap}', $q$
with a as materialized (with recursive ra(i, h) as (select 1, 7::bigint union all
                                                   select i + 1, (h * 1103515245 + 12345) % 2147483648 from ra where i < 2000000)
                        select count(*) as n, sum(h) as s from ra),
     b as materialized (with recursive rb(i, h) as (select 1, 11::bigint union all
                                                   select i + 1, (h * 1103515245 + 12345) % 2147483648 from rb where i < 2000000)
                        select count(*) as n, sum(h) as s from rb)
select a.n, a.s, b.n, b.s from a, b$q$);

-- 2, 4, 8 and 16 equal elements of computation (more than the cores of most machines)
select format('call pgmb.reg(%L, %L, %L, equiv => %L)', format('pcte.cpu_independent_%s', n), :'pgmb_ph_tags',
              'with ' || string_agg(format('c%1$s as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s '
                                           'from g_narrow where id %% %2$s = %1$s)', i, n), ', ' order by i)
              || E'\nselect sum(n), sum(s) from (' || string_agg(format('select n, s from c%s', i), ' union all ' order by i) || ') u',
              'pcte.cpu_whole_narrow')
from (values (2), (4), (8), (16)) v(n), lateral generate_series(0, n - 1) i
group by n \gexec
call pgmb.reg('pcte.cpu_independent_reference_one_pass', '{perf,planning,checksum,olap,consistency}', $q$
select count(*), sum(length(md5(md5(pad)))) from g_narrow$q$, equiv => 'pcte.cpu_whole_narrow');

-- one long element and three short ones: the long one is the critical path
call pgmb.reg('pcte.cpu_one_long_three_short', '{perf,planning,checksum,olap,consistency}', $q$
with l as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 10 < 7),
     s1 as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 10 = 7),
     s2 as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 10 = 8),
     s3 as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 10 = 9)
select sum(n), sum(s) from (select n, s from l union all select n, s from s1 union all select n, s from s2
                            union all select n, s from s3) u$q$, equiv => 'pcte.cpu_whole_narrow');

------------------------------------------------------------------------------
-- 3. handing a result on
------------------------------------------------------------------------------
-- 1000 rows, and values stored out of line (TOAST): handed on as pointers
-- (the column as stored) or detoasted (an expression over it)
call pgmb.reg('pcte.xfer_1k_rows', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, pad from g_narrow where id <= 1000 and id % 2 = 0),
     b as materialized (select id, pad from g_narrow where id <= 1000 and id % 2 = 1)
select (select count(*) from a), (select sum(length(pad)) from a), (select count(*) from b), (select sum(length(pad)) from b)$q$);
call pgmb.reg('pcte.xfer_toast_pointers', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, c_rand from g_toast where id % 2 = 0),
     b as materialized (select id, c_rand from g_toast where id % 2 = 1)
select (select sum(length(c_rand)) from a), (select sum(length(c_rand)) from b)$q$);
call pgmb.reg('pcte.xfer_toast_detoasted', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, c_rand || '' as c_rand from g_toast where id % 2 = 0),
     b as materialized (select id, c_rand || '' as c_rand from g_toast where id % 2 = 1)
select (select sum(length(c_rand)) from a), (select sum(length(c_rand)) from b)$q$);

-- What the hand-over itself costs: the same million rows (or the whole of
-- g_narrow, if smaller) summed inside the element (one row handed on), stored
-- and read once, stored and read twice, not stored at all (inlined), and sent
-- through Gather from workers to the leader (a real hand-over between processes).
call pgmb.reg('pcte.xfer_cost_aggregate_inside', '{perf,planning,checksum,olap,consistency}', $q$
with a as materialized (select count(*) as n, sum(length(pad)) as s from g_narrow where id <= 1000000)
select n, s from a$q$, equiv => 'pcte.xfer_cost');
call pgmb.reg('pcte.xfer_cost_stored_read_once', '{perf,planning,checksum,olap,consistency}', $q$
with a as materialized (select pad from g_narrow where id <= 1000000)
select count(*), sum(length(pad)) from a$q$, equiv => 'pcte.xfer_cost');
call pgmb.reg('pcte.xfer_cost_stored_read_twice', '{perf,planning,checksum,olap,consistency}', $q$
with a as materialized (select pad from g_narrow where id <= 1000000)
select (select count(*) from a), (select sum(length(pad)) from a)$q$, equiv => 'pcte.xfer_cost');
call pgmb.reg('pcte.xfer_cost_inlined', '{perf,planning,checksum,olap,consistency}', $q$
with a as not materialized (select pad from g_narrow where id <= 1000000)
select count(*), sum(length(pad)) from a$q$, equiv => 'pcte.xfer_cost');
call pgmb.reg('pcte.xfer_cost_through_gather', '{perf,planning,checksum,olap,consistency}', $q$
begin;
set local max_parallel_workers_per_gather = 2;
set local min_parallel_table_scan_size = 0;
set local parallel_setup_cost = 0;
set local parallel_tuple_cost = 0;
set local parallel_leader_participation = off;
select count(*), sum(pcte_pass(pad)) from g_narrow where id <= 1000000;
commit;$q$, equiv => 'pcte.xfer_cost');

-- the stored result larger than work_mem: it goes through temporary files
call pgmb.reg('pcte.xfer_spilled_4mb', '{perf,checksum,olap}', $q$
begin;
set local work_mem = '4MB';
with a as materialized (select id, pad from g_narrow where id <= 1000000 and id % 2 = 0),
     b as materialized (select id, pad from g_narrow where id <= 1000000 and id % 2 = 1)
select (select count(*) from a), (select sum(length(pad)) from a), (select count(*) from b), (select sum(length(pad)) from b);
commit;$q$);
call pgmb.reg('pcte.xfer_in_memory_1gb', '{perf,checksum,olap}', $q$
begin;
set local work_mem = '1GB';
with a as materialized (select id, pad from g_narrow where id <= 1000000 and id % 2 = 0),
     b as materialized (select id, pad from g_narrow where id <= 1000000 and id % 2 = 1)
select (select count(*) from a), (select sum(length(pad)) from a), (select count(*) from b), (select sum(length(pad)) from b);
commit;$q$);

-- one result handed to 1, 2 and 4 readers
select format('call pgmb.reg(%L, %L, %L)', format('pcte.xfer_readers_%s', r), :'pgmb_ph_tags',
              E'with a as materialized (select id, pad from g_narrow where id <= 1000000)\nselect '
              || string_agg(format('(select sum(length(pad)) from a where id %% %s = %s)', r, i), ', ' order by i))
from (values (1), (2), (4)) v(r), lateral generate_series(0, r - 1) i
group by r \gexec

------------------------------------------------------------------------------
-- 4. work against result size
------------------------------------------------------------------------------
-- much work, a small result: the best case for elements in their own workers
call pgmb.reg('pcte.combo_heavy_work_small_result', '{perf,planning,checksum,olap}', $q$
with a as materialized (select k_100, sum(length(md5(md5(pad)))) as s from g_narrow where id % 2 = 0 group by k_100),
     b as materialized (select k_100, sum(length(md5(md5(pad)))) as s from g_narrow where id % 2 = 1 group by k_100)
select count(*), sum(a.s + b.s) from a join b using (k_100)$q$);
-- little work, a large result: the hand-over is most of the cost
call pgmb.reg('pcte.combo_light_work_large_result', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, pad from g_narrow where id % 2 = 0),
     b as materialized (select id, pad from g_narrow where id % 2 = 1)
select (select count(*) from a), (select count(*) from b)$q$);
-- much work and a large result
call pgmb.reg('pcte.combo_heavy_work_large_result', '{perf,planning,checksum,olap}', $q$
with a as materialized (select id, md5(md5(pad)) as h from g_narrow where id % 2 = 0),
     b as materialized (select id, md5(md5(pad)) as h from g_narrow where id % 2 = 1)
select (select count(*) from a), (select max(h) from a), (select count(*) from b), (select max(h) from b)$q$);
-- an element bound by the disk next to one bound by computation
call pgmb.reg('pcte.combo_io_next_to_cpu', '{perf,planning,checksum,olap}', $q$
with io as materialized (select count(*) as n, sum(i4) as s from g_wide),
     cpu as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 2 = 0)
select io.n, io.s, cpu.n, cpu.s from io, cpu$q$);
call pgmb.reg('pcte.combo_io_next_to_io', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) as n, sum(i4) as s from g_wide where id % 2 = 0),
     b as materialized (select count(*) as n, sum(i4) as s from g_wide where id % 2 = 1)
select a.n, a.s, b.n, b.s from a, b$q$);
call pgmb.reg('pcte.combo_cpu_next_to_cpu', '{perf,planning,checksum,olap}', $q$
with a as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 4 = 0),
     b as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 4 = 1)
select a.n, a.s, b.n, b.s from a, b$q$);

------------------------------------------------------------------------------
-- 5. shapes that hand results on
------------------------------------------------------------------------------
-- a chain of three steps, each handing on every row or one row per group
call pgmb.reg('pcte.chain_hands_on_large', '{perf,planning,checksum,olap,consistency}', $q$
with a as materialized (select id, k_100, pad from g_narrow),
     b as materialized (select id, k_100, md5(pad) as h from a),
     c as materialized (select k_100, count(*) as n, max(h) as h from b group by k_100)
select count(*), sum(n), max(h) from c$q$, equiv => 'pcte.chain_hands_on');
call pgmb.reg('pcte.chain_hands_on_small', '{perf,planning,checksum,olap,consistency}', $q$
with a as materialized (select k_100, count(*) as n, max(md5(pad)) as h from g_narrow group by k_100),
     b as materialized (select k_100, n, h from a),
     c as materialized (select k_100, n, h from b)
select count(*), sum(n), max(h) from c$q$, equiv => 'pcte.chain_hands_on');

-- a diamond: the root hands every row to two branches, which hand one row each to the end
call pgmb.reg('pcte.diamond_root_hands_on_large', '{perf,planning,checksum,olap}', $q$
with r as materialized (select id, k_100, k_10k, pad from g_narrow),
     l as materialized (select count(*) as n, sum(length(md5(pad))) as s from r where k_100 < 50),
     h as materialized (select count(*) as n, sum(k_10k) as s from r where k_100 >= 50)
select l.n, l.s, h.n, h.s from l, h$q$);

-- three large results joined by the main query
call pgmb.reg('pcte.fan_in_three_large', '{perf,planning,checksum,olap,consistency}', $q$
with a as materialized (select id, k_100 from g_narrow),
     b as materialized (select id, length(md5(pad)) as l from g_narrow),
     c as materialized (select id, k_10k from g_narrow)
select count(*), sum(a.k_100), sum(b.l), sum(c.k_10k) from a join b using (id) join c using (id)$q$, equiv => 'pcte.fan_in');
call pgmb.reg('pcte.fan_in_three_large_reference', '{perf,planning,checksum,olap,consistency}', $q$
select count(*), sum(k_100), sum(length(md5(pad))), sum(k_10k) from g_narrow$q$, equiv => 'pcte.fan_in');

------------------------------------------------------------------------------
-- 6. two and three pipelines joined by the leader, under worker limits
------------------------------------------------------------------------------
-- Pipeline i: a slice of g_narrow -> md5 of every row -> one row per k_100.
-- The main query (the leader) joins the pipelines on k_100. Each shape runs
-- with max_parallel_workers (and max_parallel_workers_per_gather) at 0, 1,
-- 2, 3, 4, 6 (and 9 for three pipelines): with as many workers as pipelines
-- they can all run at once, with fewer one waits. A setting of the patch
-- itself (such as max_parallel_cte_workers) is given per run with -v gucs.
-- All variants of one shape return the same rows.
create function pg_temp.pcte_pipelines(p int, p_cond text[], p_m int, p_steps int[], p_kind text, p_final text, p_pre text)
returns text language plpgsql as $f$
declare
    ctes text[] := '{}';
    sel text := '';
    frm text := '';
    src text;
    prev text;
begin
    for i in 1 .. p loop
        -- step 1: a slice of a table; the join key is k_100, or the row's
        -- number within its slice when every row is handed on
        src := case when p_kind = 'io' or (p_kind = 'mixed' and i % 2 = 0)
                    then format('select id, i3 as k_100, id / %s as k_row, t3 as pad from g_wide where %s', p_m, p_cond[i])
                    else format('select id, k_100, id / %s as k_row, pad from g_narrow where %s', p_m, p_cond[i]) end;
        ctes := ctes || format('p%s_1 as materialized (%s)', i, src);
        prev := format('p%s_1', i);
        -- the steps between: work on every row
        for s in 2 .. p_steps[i] - 1 loop
            ctes := ctes || format('p%1$s_%2$s as materialized (select id, k_100, k_row, md5(pad) as pad from %3$s)', i, s, prev);
            prev := format('p%s_%s', i, s);
        end loop;
        -- the last step: one row per k_100, or every row
        if p_final = 'small' then
            ctes := ctes || format('p%1$s_%2$s as materialized (select k_100 as k, count(*) as n, max(pad) as h from %3$s group by k_100)',
                                   i, p_steps[i], prev);
        else
            ctes := ctes || format('p%1$s_%2$s as materialized (select k_row as k, 1 as n, pad as h from %3$s)', i, p_steps[i], prev);
        end if;
        sel := sel || format(', sum(p%1$s.n), max(p%1$s.h)', i);
        frm := frm || case when i = 1 then format('p%1$s_%2$s p%1$s', i, p_steps[i])
                           else format(' join p%1$s_%2$s p%1$s using (k)', i, p_steps[i]) end;
    end loop;
    return p_pre || 'with ' || array_to_string(ctes, ', ') || E'\nselect count(*)' || sel || ' from ' || frm
           || case when p_pre <> '' then E';\ncommit;' else '' end;
end $f$;

-- the worker limits, for two and for three pipelines
select format('call pgmb.reg(%L, %L, %L, equiv => %L)',
              format('pcte.pipelines_%s_workers_%s', p, w), :'pgmb_ph_tags',
              pg_temp.pcte_pipelines(p, case p when 2 then '{id % 2 = 0, id % 2 = 1}'::text[] else '{id % 3 = 0, id % 3 = 1, id % 3 = 2}'::text[] end,
                                     p, case p when 2 then '{3,3}'::int[] else '{3,3,3}'::int[] end, 'cpu', 'small',
                                     format(E'begin;\nset local max_parallel_workers = %1$s;\nset local max_parallel_workers_per_gather = %1$s;\n', w)),
              format('pcte.pipelines_%s', p))
from (values (2, 0), (2, 1), (2, 2), (2, 3), (2, 4), (2, 6),
             (3, 0), (3, 1), (3, 2), (3, 3), (3, 4), (3, 6), (3, 9)) v(p, w) \gexec

-- variants of the pipelines, each at the server's own worker limits
select format('call pgmb.reg(%L, %L, %L)', 'pcte.pipelines_' || lbl, :'pgmb_ph_tags',
              pg_temp.pcte_pipelines(p, cond, m, steps, kind, final, pre))
from (values
    -- unequal length: 2 against 5 steps
    ('2_unequal_length', 2, '{id % 2 = 0, id % 2 = 1}'::text[], 2, '{2,5}'::int[], 'cpu', 'small', ''),
    ('3_unequal_length', 3, '{id % 3 = 0, id % 3 = 1, id % 3 = 2}'::text[], 3, '{2,3,5}'::int[], 'cpu', 'small', ''),
    -- unequal cost: one pipeline reads three times as many rows as the other
    ('2_unequal_cost', 2, '{id % 4 = 0, id % 4 <> 0}'::text[], 4, '{3,3}'::int[], 'cpu', 'small', ''),
    -- pipelines bound by the disk, and pipelines of both kinds
    ('2_io', 2, '{id % 2 = 0, id % 2 = 1}'::text[], 2, '{3,3}'::int[], 'io', 'small', ''),
    ('3_io', 3, '{id % 3 = 0, id % 3 = 1, id % 3 = 2}'::text[], 3, '{3,3,3}'::int[], 'io', 'small', ''),
    ('2_mixed', 2, '{id % 2 = 0, id % 2 = 1}'::text[], 2, '{3,3}'::int[], 'mixed', 'small', ''),
    ('3_mixed', 3, '{id % 3 = 0, id % 3 = 1, id % 3 = 2}'::text[], 3, '{3,3,3}'::int[], 'mixed', 'small', ''),
    -- every row handed to the leader, joined on its number within the slice
    ('2_large_result', 2, '{id % 2 = 0, id % 2 = 1}'::text[], 2, '{3,3}'::int[], 'cpu', 'large', ''),
    ('3_large_result', 3, '{id % 3 = 0, id % 3 = 1, id % 3 = 2}'::text[], 3, '{3,3,3}'::int[], 'cpu', 'large', ''),
    -- the leader's join done by hash, merge or nested loop
    ('2_leader_hash_join', 2, '{id % 2 = 0, id % 2 = 1}'::text[], 2, '{3,3}'::int[], 'cpu', 'large',
     E'begin;\nset local enable_mergejoin = off;\nset local enable_nestloop = off;\n'),
    ('2_leader_merge_join', 2, '{id % 2 = 0, id % 2 = 1}'::text[], 2, '{3,3}'::int[], 'cpu', 'large',
     E'begin;\nset local enable_hashjoin = off;\nset local enable_nestloop = off;\n'),
    ('2_leader_nested_loop', 2, '{id % 2 = 0, id % 2 = 1}'::text[], 2, '{3,3}'::int[], 'cpu', 'small',
     E'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\n')
    ) v(lbl, p, cond, m, steps, kind, final, pre) \gexec
