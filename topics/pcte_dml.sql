-- Topic: pcte (part 3) - heavy CTE elements that write: UPDATE, INSERT ...
-- SELECT, DELETE and MERGE in CTEs, with and without RETURNING, next to and
-- feeding heavy read elements; pipelines that end in a write, joined by the
-- leader, under worker limits. Like pcte.sql and pcte_heavy.sql, meant to be
-- run twice under different server settings and compared. A data-modifying
-- CTE always runs to the end, once, and on a stock server makes the whole
-- statement serial.
--
-- Every test runs in a transaction that is rolled back, so the data never
-- change. With several clients each client writes only its own rows: client c
-- owns the rows of g_pd with id % 32 in (2s, 2s + 1), s = c % 16.
--
-- NOT YET INCLUDED IN bench.sql. To enable it, add after topics/pcte_heavy.sql:
--   \ir topics/pcte_dml.sql
-- report/pcte_gain.sql measures these tests too (they are explained inside a
-- transaction that is rolled back).

------------------------------------------------------------------------------
-- objects
------------------------------------------------------------------------------
insert into pgmb.dataset (name, base_rows, exponent, min_rows) values ('g_pd', 1000000, 1, 3200);

call pgmb.reg_ddl('pcte.create_g_pd', 'schema', $q$
-- the table that is updated and deleted from, with indexes, and a copy without
create table g_pd (id bigint not null, k int not null, v bigint not null, pad text not null) with (fillfactor = 70);
create table g_pd_noidx (id bigint not null, k int not null, v bigint not null, pad text not null) with (fillfactor = 70);
-- the table that is inserted into: an archive with no keys
create table g_pd_log (id bigint not null, k int not null, v bigint not null, pad text not null)$q$);
call pgmb.reg_ddl('pcte.load_g_pd', 'load', $q$
insert into g_pd select i, pgmb.hu(i, 1, 100)::int, pgmb.hu(i, 2, 1000000), pgmb.htext(i, 3, 40)
from generate_series(1, :n_g_pd) i$q$, target => 'g_pd');
call pgmb.reg_ddl('pcte.load_g_pd_noidx', 'load', $q$insert into g_pd_noidx select * from g_pd$q$, target => 'g_pd_noidx');
call pgmb.reg_ddl('pcte.pk_g_pd', 'constraint', $q$alter table g_pd add primary key (id)$q$, target => 'g_pd_pkey');
call pgmb.reg_ddl('pcte.ix_g_pd_k', 'index', $q$create index g_pd_k on g_pd (k)$q$, target => 'g_pd_k');
call pgmb.reg_ddl('pcte.ix_g_pd_pad', 'index', $q$create index g_pd_pad on g_pd (pad)$q$, target => 'g_pd_pad');
call pgmb.reg_ddl('pcte.vacuum_g_pd', 'maintenance', $q$vacuum (analyze) g_pd$q$);
call pgmb.reg_ddl('pcte.vacuum_g_pd_noidx', 'maintenance', $q$vacuum (analyze) g_pd_noidx$q$);
call pgmb.reg_ddl('pcte.vacuum_g_pd_log', 'maintenance', $q$vacuum (analyze) g_pd_log$q$);

-- the client's two slices of g_pd (a and b), and a third and fourth for four writers
\set pgmb_pd_setup '\\set s :client_id % 16'
\set pgmb_pd_tags '{perf,planning,olap}'

------------------------------------------------------------------------------
-- 1. heavy writing elements, two independent ones per statement
------------------------------------------------------------------------------
call pgmb.reg('pcte.dml_two_updates_cpu', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + length(md5(md5(pad))) where id % 32 = 2 * :s returning 1),
     b as (update g_pd set v = v + length(md5(md5(pad))) where id % 32 = 2 * :s + 1 returning 1)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

call pgmb.reg('pcte.dml_two_inserts_select_cpu', '{perf,planning,olap}', $q$
begin;
with a as (insert into g_pd_log select id, k_100, k_10k, md5(md5(pad)) from g_narrow where id % 2 = 0 returning 1),
     b as (insert into g_pd_log select id, k_100, k_10k, md5(md5(pad)) from g_narrow where id % 2 = 1 returning 1)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write');

call pgmb.reg('pcte.dml_two_deletes', '{perf,planning,olap}', $q$
begin;
with a as (delete from g_pd where id % 32 = 2 * :s returning 1),
     b as (delete from g_pd where id % 32 = 2 * :s + 1 returning 1)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

call pgmb.reg('pcte.dml_two_merges', '{perf,planning,olap}', $q$
begin;
with a as (merge into g_pd t using (select id, length(md5(pad)) as l from g_narrow where id % 32 = 2 * :s) s on t.id = s.id
           when matched then update set v = t.v + s.l returning 1),
     b as (merge into g_pd t using (select id, length(md5(pad)) as l from g_narrow where id % 32 = 2 * :s + 1) s on t.id = s.id
           when matched then update set v = t.v + s.l returning 1)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

------------------------------------------------------------------------------
-- 2. how much RETURNING hands on
------------------------------------------------------------------------------
-- nothing (the writer cannot be read), one column, whole rows, whole rows read twice
call pgmb.reg('pcte.dml_returning_none', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s),
     b as (update g_pd set v = v + 1 where id % 32 = 2 * :s + 1)
select 1;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_returning_one_column', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning id),
     b as (update g_pd set v = v + 1 where id % 32 = 2 * :s + 1 returning id)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_returning_whole_rows', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning *),
     b as (update g_pd set v = v + 1 where id % 32 = 2 * :s + 1 returning *)
select (select count(*) from a), (select max(pad) from a), (select count(*) from b), (select max(pad) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_returning_whole_rows_aggregated_inside', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning *),
     b as (update g_pd set v = v + 1 where id % 32 = 2 * :s + 1 returning *),
     sa as materialized (select count(*) as n, max(pad) as m from a),
     sb as materialized (select count(*) as n, max(pad) as m from b)
select sa.n, sa.m, sb.n, sb.m from sa, sb;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

------------------------------------------------------------------------------
-- 3. a write feeding a read, and a read feeding a write
------------------------------------------------------------------------------
-- the rows an UPDATE returns are the source of a heavy aggregate
call pgmb.reg('pcte.dml_write_feeds_heavy_read', '{perf,planning,olap}', $q$
begin;
with u as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning id, k, pad),
     r as materialized (select k, count(*) as n, max(md5(md5(pad))) as h from u group by k)
select count(*), sum(n), max(h) from r;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
-- a heavy read is the source of an UPDATE ... FROM
call pgmb.reg('pcte.dml_heavy_read_feeds_write', '{perf,planning,olap}', $q$
begin;
with r as materialized (select id, md5(md5(pad)) as h from g_narrow where id % 32 = 2 * :s),
     u as (update g_pd t set pad = r.h from r where t.id = r.id returning t.id)
select count(*) from u;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
-- both at once: a heavy read next to a writer whose rows feed another heavy read
call pgmb.reg('pcte.dml_read_next_to_write_feeding_read', '{perf,planning,olap}', $q$
begin;
with x as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 2 = 0),
     u as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning k, pad),
     y as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from u)
select x.n, x.s, y.n, y.s from x, y;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

------------------------------------------------------------------------------
-- 4. chains of writes
------------------------------------------------------------------------------
call pgmb.reg('pcte.dml_chain_update_then_archive', '{perf,planning,olap}', $q$
begin;
with u as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning id, k, v, pad),
     i as (insert into g_pd_log select id, k, v, md5(pad) from u returning k)
select count(*), count(distinct k) from i;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_chain_delete_then_archive', '{perf,planning,olap}', $q$
begin;
with d as (delete from g_pd where id % 32 = 2 * :s returning *),
     i as (insert into g_pd_log select * from d returning k)
select count(*), count(distinct k) from i;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
-- three steps: update, archive, and an update of the other slice for every archived row
call pgmb.reg('pcte.dml_chain_three_steps', '{perf,planning,olap}', $q$
begin;
with u as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning id, k, v, pad),
     i as (insert into g_pd_log select id, k, v, pad from u returning id),
     w as (update g_pd t set v = t.v + 1 from i where t.id = i.id + 1 and t.id % 32 = 2 * :s + 1 returning t.id)
select (select count(*) from i), (select count(*) from w);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

------------------------------------------------------------------------------
-- 5. independent writers
------------------------------------------------------------------------------
-- two and four writers on different tables, and on different slices of one table
call pgmb.reg('pcte.dml_two_writers_two_tables', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning 1),
     b as (update g_pd_noidx set v = v + 1 where id % 32 = 2 * :s returning 1)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_two_writers_one_table', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning 1),
     b as (update g_pd set v = v + 1 where id % 32 = 2 * :s + 1 returning 1)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_four_writers_three_tables', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning 1),
     b as (update g_pd set v = v + 1 where id % 32 = 2 * :s + 1 returning 1),
     c as (update g_pd_noidx set v = v + 1 where id % 32 = 2 * :s returning 1),
     d as (insert into g_pd_log select id, k_100, k_10k, pad from g_narrow where id % 16 = :s returning 1)
select (select count(*) from a), (select count(*) from b), (select count(*) from c), (select count(*) from d);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

------------------------------------------------------------------------------
-- 6. pipelines that end in a write, joined by the leader, under worker limits
------------------------------------------------------------------------------
-- Pipeline i: a slice of g_narrow -> md5 of every row -> INSERT into the
-- archive RETURNING the rows -> (the main query) one row per k. The writer is
-- in every pipeline, or only in the first (the others end in a read). Each
-- shape runs with max_parallel_workers at 0, 1, 2, 3, 4, 6 (and 9 for three).
create function pg_temp.pcte_dml_pipelines(p int, p_writers text, p_final text, p_pre text)
returns text language plpgsql as $f$
declare
    ctes text[] := '{}';
    sel text := '';
    frm text := '';
begin
    for i in 1 .. p loop
        ctes := ctes || format('p%1$s_1 as materialized (select id, k_100, id / %2$s as k_row, pad from g_narrow where id %% %2$s = %3$s)',
                               i, p, i - 1);
        ctes := ctes || format('p%1$s_2 as materialized (select id, k_100, k_row, md5(md5(pad)) as pad from p%1$s_1)', i);
        if p_writers = 'all' or i = 1 then
            ctes := ctes || format('p%1$s_3 as (insert into g_pd_log select id, k_100, k_row, pad from p%1$s_2 returning k as k_100, v as k_row, pad)', i);
        else
            ctes := ctes || format('p%1$s_3 as materialized (select k_100, k_row, pad from p%1$s_2)', i);
        end if;
        if p_final = 'small' then
            ctes := ctes || format('p%1$s_4 as materialized (select k_100 as k, count(*) as n, max(pad) as h from p%1$s_3 group by k_100)', i);
        else
            ctes := ctes || format('p%1$s_4 as materialized (select k_row as k, 1 as n, pad as h from p%1$s_3)', i);
        end if;
        sel := sel || format(', sum(p%1$s.n), max(p%1$s.h)', i);
        frm := frm || case when i = 1 then format('p%1$s_4 p%1$s', i) else format(' join p%1$s_4 p%1$s using (k)', i) end;
    end loop;
    return E'begin;\n' || p_pre || 'with ' || array_to_string(ctes, ', ') || E'\nselect count(*)' || sel || ' from ' || frm
           || E';\nrollback;';
end $f$;

select format('call pgmb.reg(%L, %L, %L, kind => %L)',
              format('pcte.dml_pipelines_%s_%s_workers_%s', p, wr, w), :'pgmb_pd_tags',
              pg_temp.pcte_dml_pipelines(p, wr, 'small',
                                         format(E'set local max_parallel_workers = %1$s;\nset local max_parallel_workers_per_gather = %1$s;\n', w)),
              'write')
from (values (2), (3)) pp(p), (values ('all'), ('first')) ww(wr),
     lateral unnest(case p when 2 then array[0, 1, 2, 3, 4, 6] else array[0, 1, 2, 3, 4, 6, 9] end) w \gexec

-- every row handed to the leader instead of one row per group
select format('call pgmb.reg(%L, %L, %L, kind => %L)', format('pcte.dml_pipelines_%s_all_large_result', p), :'pgmb_pd_tags',
              pg_temp.pcte_dml_pipelines(p, 'all', 'large', ''), 'write')
from (values (2), (3)) pp(p) \gexec

------------------------------------------------------------------------------
-- 7. a writer next to a heavy read
------------------------------------------------------------------------------
call pgmb.reg('pcte.dml_writer_next_to_disk_read', '{perf,planning,olap}', $q$
begin;
with io as materialized (select count(*) as n, sum(i4) as s from g_wide),
     u as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning 1)
select io.n, io.s, (select count(*) from u) from io;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_writer_next_to_computation', '{perf,planning,olap}', $q$
begin;
with cpu as materialized (select count(*) as n, sum(length(md5(md5(pad)))) as s from g_narrow where id % 2 = 0),
     u as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning 1)
select cpu.n, cpu.s, (select count(*) from u) from cpu;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');

------------------------------------------------------------------------------
-- 8. what a write costs
------------------------------------------------------------------------------
-- the same update on a table with three indexes and on one without any
call pgmb.reg('pcte.dml_cost_update_with_indexes', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning 1) select count(*) from a;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_cost_update_without_indexes', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd_noidx set v = v + 1 where id % 32 = 2 * :s returning 1) select count(*) from a;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
-- an unindexed column (the new version can stay on the page, HOT) against an indexed one
call pgmb.reg('pcte.dml_cost_update_unindexed_column', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v + 1 where id % 32 = 2 * :s returning 1) select count(*) from a;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_cost_update_indexed_column', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set k = k + 1 where id % 32 = 2 * :s returning 1) select count(*) from a;
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
-- the same work committed and rolled back (the committed update writes the
-- same values back, so the data do not change)
call pgmb.reg('pcte.dml_cost_committed', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v where id % 32 = 2 * :s returning 1),
     b as (update g_pd set v = v where id % 32 = 2 * :s + 1 returning 1)
select (select count(*) from a), (select count(*) from b);
commit;$q$, kind => 'write', setup => :'pgmb_pd_setup');
call pgmb.reg('pcte.dml_cost_rolled_back', '{perf,planning,olap}', $q$
begin;
with a as (update g_pd set v = v where id % 32 = 2 * :s returning 1),
     b as (update g_pd set v = v where id % 32 = 2 * :s + 1 returning 1)
select (select count(*) from a), (select count(*) from b);
rollback;$q$, kind => 'write', setup => :'pgmb_pd_setup');
