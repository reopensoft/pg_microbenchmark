-- Topic: cte (part 28) - what the other CTE files leave out: LATERAL inside a
-- CTE body, row-valued subqueries over a CTE, IMMUTABLE functions and how
-- often a CTE body calls them, JIT, extended statistics and equivalence
-- classes across the CTE boundary, Memoize and parameterized paths into a CTE.

------------------------------------------------------------------------------
-- objects
------------------------------------------------------------------------------
-- g_cte_stats: three columns that move together (b = a, c = a / 10) and one
-- that does not. g_cte_stats_ext is the same table with extended statistics
-- on (a, b, c): functional dependencies, number of distinct combinations, and
-- the most common combinations.
insert into pgmb.dataset (name, base_rows, exponent, min_rows) values ('g_cte_stats', 100000, 1, 1000);

call pgmb.reg_ddl('cte.create_g_cte_stats', 'schema', $q$
create table g_cte_stats (id bigint not null, a int not null, b int not null, c int not null, d int not null);
create table g_cte_stats_ext (id bigint not null, a int not null, b int not null, c int not null, d int not null);
create statistics g_cte_stats_ext_abc (dependencies, ndistinct, mcv) on a, b, c from g_cte_stats_ext$q$);
call pgmb.reg_ddl('cte.load_g_cte_stats', 'load', $q$
insert into g_cte_stats
select i, x.a, x.a, x.a / 10, pgmb.hu(i, 2, 1000)::int
from generate_series(1, :n_g_cte_stats) i, lateral (select pgmb.hu(i, 1, 100)::int as a) x$q$, target => 'g_cte_stats');
call pgmb.reg_ddl('cte.load_g_cte_stats_ext', 'load',
    $q$insert into g_cte_stats_ext select * from g_cte_stats$q$, target => 'g_cte_stats_ext');
call pgmb.reg_ddl('cte.vacuum_g_cte_stats', 'maintenance', $q$vacuum (analyze) g_cte_stats$q$);
call pgmb.reg_ddl('cte.vacuum_g_cte_stats_ext', 'maintenance', $q$vacuum (analyze) g_cte_stats_ext$q$);

-- Call counting: each function takes a value from a sequence, cte_calls()
-- runs a statement and returns how many values were taken. Planning happens
-- inside cte_calls() too, so a call made by the planner is counted.
call pgmb.reg_ddl('cte.create_call_counting', 'schema', $q$
create sequence g_cte_calls_seq;
create function cte_imm(v int) returns int language plpgsql immutable as
'begin perform nextval(''pgmb_data.g_cte_calls_seq''); return v; end';
create function cte_stable(v int) returns int language plpgsql stable as
'begin perform nextval(''pgmb_data.g_cte_calls_seq''); return v; end';
create function cte_volatile(v int) returns int language plpgsql volatile as
'begin perform nextval(''pgmb_data.g_cte_calls_seq''); return v; end';
create function cte_calls(p_sql text) returns bigint language plpgsql as
$f$declare
    v0 bigint;
begin
    v0 := nextval('pgmb_data.g_cte_calls_seq');
    execute p_sql;
    return nextval('pgmb_data.g_cte_calls_seq') - v0 - 1;
end$f$$q$);

call pgmb.reg('cte.calls_expected_0',   '{consistency}', $q$select 0::bigint$q$,   equiv => 'cte.calls_0');
call pgmb.reg('cte.calls_expected_100', '{consistency}', $q$select 100::bigint$q$, equiv => 'cte.calls_100');
call pgmb.reg('cte.calls_expected_200', '{consistency}', $q$select 200::bigint$q$, equiv => 'cte.calls_200');
call pgmb.reg('cte.calls_expected_true', '{consistency}', $q$select true$q$,       equiv => 'cte.calls_true');

------------------------------------------------------------------------------
-- LATERAL inside the body of a CTE
------------------------------------------------------------------------------
-- the largest child of each of 100 parents
call pgmb.reg('cte.lateral_in_body_top1_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select p.id, t.amount
           from g_parent p,
                lateral (select amount from g_child ch where ch.parent_id = p.id order by amount desc limit 1) t
           where p.id between :id and :id + 99)
select count(*), sum(amount) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_top1');
call pgmb.reg('cte.lateral_in_body_top1_materialized', '{perf,planning,analyze,consistency,oltp}', $q$
with c as materialized (select p.id, t.amount
                        from g_parent p,
                             lateral (select amount from g_child ch where ch.parent_id = p.id order by amount desc limit 1) t
                        where p.id between :id and :id + 99)
select count(*), sum(amount) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_top1');
call pgmb.reg('cte.lateral_in_body_top1_without_cte', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(t.amount)
from g_parent p,
     lateral (select amount from g_child ch where ch.parent_id = p.id order by amount desc limit 1) t
where p.id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_top1');

-- LEFT JOIN LATERAL keeps parents without children; the outer filter is
-- pushed into the inlined CTE, not into the materialized one
call pgmb.reg('cte.lateral_in_body_left_join_filter_outside_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select p.id, s.n, s.total
           from g_parent p
                left join lateral (select count(*) as n, sum(amount) as total
                                   from g_child ch where ch.parent_id = p.id) s on true)
select count(*), sum(n), sum(total) from c where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_left_join');
call pgmb.reg('cte.lateral_in_body_left_join_filter_outside_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select p.id, s.n, s.total
                        from g_parent p
                             left join lateral (select count(*) as n, sum(amount) as total
                                                from g_child ch where ch.parent_id = p.id) s on true)
select count(*), sum(n), sum(total) from c where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_left_join');

-- a set-returning function inside the CTE, its length taken from the row
call pgmb.reg('cte.lateral_in_body_srf', '{perf,planning,consistency}', $q$
with c as (select p.id, s from g_parent p, lateral generate_series(1, p.grp % 5) s
           where p.id between :id and :id + 99)
select count(*), sum(s) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_srf');
call pgmb.reg('cte.lateral_in_body_srf_select_list', '{perf,planning,consistency}', $q$
with c as (select id, generate_series(1, grp % 5) as s from g_parent where id between :id and :id + 99)
select count(*), sum(s) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_srf');

-- the LATERAL side reads another CTE
call pgmb.reg('cte.lateral_in_body_over_other_cte', '{perf,planning,consistency}', $q$
with p as (select id from g_parent where id between :id and :id + 99),
     ch as (select parent_id, amount from g_child where parent_id between :id and :id + 99),
     c as (select p.id, x.n from p, lateral (select count(*) as n from ch where ch.parent_id = p.id) x)
select count(*), sum(n) from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_other_cte');
call pgmb.reg('cte.lateral_in_body_over_other_cte_as_group_by', '{perf,planning,consistency}', $q$
with p as (select id from g_parent where id between :id and :id + 99),
     ch as (select parent_id, count(*) as n from g_child where parent_id between :id and :id + 99 group by parent_id)
select count(*), sum(coalesce(ch.n, 0)) from p left join ch on ch.parent_id = p.id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.lateral_in_body_other_cte');

------------------------------------------------------------------------------
-- row-valued subqueries over a CTE
------------------------------------------------------------------------------
-- rows whose pair (k_100, k_10k) occurs among 1000 other rows: four forms (the
-- last compares whole records with an array of them; ROW() = ANY (subquery)
-- would compare column by column)
call pgmb.reg('cte.row_subquery_in', '{perf,planning,analyze,consistency}', $q$
with c as (select k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from g_narrow n where n.id <= 20000 and (n.k_100, n.k_10k) in (select k_100, k_10k from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_in');
call pgmb.reg('cte.row_subquery_in_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from g_narrow n where n.id <= 20000 and (n.k_100, n.k_10k) in (select k_100, k_10k from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_in');
call pgmb.reg('cte.row_subquery_in_as_exists', '{perf,planning,analyze,consistency}', $q$
with c as (select k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from g_narrow n
where n.id <= 20000 and exists (select from c where c.k_100 = n.k_100 and c.k_10k = n.k_10k)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_in');
call pgmb.reg('cte.row_subquery_in_as_record_array', '{perf,planning,analyze,consistency}', $q$
with c as (select k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from g_narrow n
where n.id <= 20000 and row(n.k_100, n.k_10k) = any (array(select row(k_100, k_10k) from c))$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_in');

-- NOT IN with rows: without NULLs it is the same as NOT EXISTS
call pgmb.reg('cte.row_subquery_not_in', '{perf,planning,analyze,consistency}', $q$
with c as (select k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from g_narrow n where n.id <= 20000 and (n.k_100, n.k_10k) not in (select k_100, k_10k from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_not_in');
call pgmb.reg('cte.row_subquery_not_in_as_not_exists', '{perf,planning,analyze,consistency}', $q$
with c as (select k_100, k_10k from g_narrow where id between :id and :id + 999)
select count(*) from g_narrow n
where n.id <= 20000 and not exists (select from c where c.k_100 = n.k_100 and c.k_10k = n.k_10k)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_not_in');

-- one row from the CTE compared with the row of each table row
call pgmb.reg('cte.row_subquery_scalar_row_comparison', '{perf,planning,consistency}', $q$
with c as (select k_100, k_10k from g_narrow where id = :id)
select count(*) from g_narrow n where n.id <= 20000 and (n.k_100, n.k_10k) >= (select k_100, k_10k from c)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_scalar');
call pgmb.reg('cte.row_subquery_scalar_row_comparison_spelled_out', '{perf,planning,consistency}', $q$
with c as (select k_100, k_10k from g_narrow where id = :id)
select count(*) from g_narrow n, c
where n.id <= 20000 and (n.k_100 > c.k_100 or (n.k_100 = c.k_100 and n.k_10k >= c.k_10k))$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.row_subquery_scalar');

-- NULL inside a row: = gives NULL as soon as one pair is unknown and no pair differs
call pgmb.reg('cte.row_subquery_null_semantics', '{consistency}', $q$
with c(a, b) as (values (1, null::int), (3, 4))
select (1, 2) in (select a, b from c), (2, 2) not in (select a, b from c), (1, 2) not in (select a, b from c),
       (3, 4) in (select a, b from c), (1, null::int) = (select a, b from c where a = 1)$q$,
    equiv => 'cte.row_subquery_null');
call pgmb.reg('cte.row_subquery_null_semantics_expected', '{consistency}',
    $q$select null::boolean, true, null::boolean, true, null::boolean$q$, equiv => 'cte.row_subquery_null');

call pgmb.reg('cte.err_row_subquery_returns_two_rows', '{errors}', $q$
with c(a, b) as (values (1, 2), (3, 4))
select (1, 2) = (select a, b from c)$q$, expect_error => '21000');
call pgmb.reg('cte.err_row_subquery_column_count', '{errors}', $q$
with c(a, b, x) as (values (1, 2, 3))
select (1, 2) in (select a, b, x from c)$q$, expect_error => '42601');

------------------------------------------------------------------------------
-- IMMUTABLE, STABLE, VOLATILE: how often the body of a CTE calls them
------------------------------------------------------------------------------
-- 100 rows, one call per row wherever the value is computed
call pgmb.reg('cte.immutable_column_arg_one_reader', '{consistency}', $q$
select cte_calls($s$with c as (select n, cte_imm(n) as v from generate_series(1, 100) n)
                    select sum(v) from c$s$)$q$, equiv => 'cte.calls_100');

-- two readers: the default materializes once, NOT MATERIALIZED computes it twice
call pgmb.reg('cte.immutable_column_arg_two_readers_default', '{consistency}', $q$
select cte_calls($s$with c as (select n, cte_imm(n) as v from generate_series(1, 100) n)
                    select (select sum(v) from c), (select max(v) from c)$s$)$q$, equiv => 'cte.calls_100');
call pgmb.reg('cte.immutable_column_arg_two_readers_not_materialized', '{consistency}', $q$
select cte_calls($s$with c as not materialized (select n, cte_imm(n) as v from generate_series(1, 100) n)
                    select (select sum(v) from c), (select max(v) from c)$s$)$q$, equiv => 'cte.calls_200');
call pgmb.reg('cte.stable_column_arg_two_readers_not_materialized', '{consistency}', $q$
select cte_calls($s$with c as not materialized (select n, cte_stable(n) as v from generate_series(1, 100) n)
                    select (select sum(v) from c), (select max(v) from c)$s$)$q$, equiv => 'cte.calls_200');
-- a volatile function keeps the CTE materialized whatever it is asked
call pgmb.reg('cte.volatile_column_arg_two_readers_not_materialized', '{consistency}', $q$
select cte_calls($s$with c as not materialized (select n, cte_volatile(n) as v from generate_series(1, 100) n)
                    select (select sum(v) from c), (select max(v) from c)$s$)$q$, equiv => 'cte.calls_100');

-- the column is not read: an inlined CTE never computes it, a materialized one does
call pgmb.reg('cte.immutable_unread_column_inlined', '{consistency}', $q$
select cte_calls($s$with c as (select n, cte_imm(n) as v from generate_series(1, 100) n)
                    select count(*) from c$s$)$q$, equiv => 'cte.calls_0');
call pgmb.reg('cte.immutable_unread_column_materialized', '{consistency}', $q$
select cte_calls($s$with c as materialized (select n, cte_imm(n) as v from generate_series(1, 100) n)
                    select count(*) from c$s$)$q$, equiv => 'cte.calls_100');
call pgmb.reg('cte.volatile_unread_column_inlined', '{consistency}', $q$
select cte_calls($s$with c as (select n, cte_volatile(n) as v from generate_series(1, 100) n)
                    select count(*) from c$s$)$q$, equiv => 'cte.calls_100');

-- constant arguments: an immutable call is folded by the planner, so the
-- 100 rows cost fewer calls than rows; a stable call is made for every row
call pgmb.reg('cte.immutable_constant_arg_folded', '{consistency}', $q$
select cte_calls($s$with c as (select n, cte_imm(7) as v from generate_series(1, 100) n)
                    select sum(v) from c$s$) < 100$q$, equiv => 'cte.calls_true');
call pgmb.reg('cte.stable_constant_arg_per_row', '{consistency}', $q$
select cte_calls($s$with c as materialized (select n, cte_stable(7) as v from generate_series(1, 100) n)
                    select sum(v) from c$s$) >= 100$q$, equiv => 'cte.calls_true');

-- the cost: 100,000 calls of a function that does nothing, folded or not
call pgmb.reg_ddl('cte.create_noop_volatility', 'schema', $q$
create function cte_noop_imm(v int) returns int language plpgsql immutable as 'begin return v; end';
create function cte_noop_stable(v int) returns int language plpgsql stable as 'begin return v; end'$q$);
call pgmb.reg('cte.immutable_cost_constant_arg_100k', '{perf,planning,consistency}', $q$
with c as (select n, cte_noop_imm(7) as v from generate_series(1, 100000) n) select sum(v) from c$q$,
    equiv => 'cte.volatility_cost');
call pgmb.reg('cte.stable_cost_constant_arg_100k', '{perf,planning,consistency}', $q$
with c as (select n, cte_noop_stable(7) as v from generate_series(1, 100000) n) select sum(v) from c$q$,
    equiv => 'cte.volatility_cost');
call pgmb.reg('cte.no_function_constant_100k', '{perf,planning,consistency}', $q$
with c as (select n, 7 as v from generate_series(1, 100000) n) select sum(v) from c$q$,
    equiv => 'cte.volatility_cost');

------------------------------------------------------------------------------
-- JIT over a CTE
------------------------------------------------------------------------------
-- An aggregate with several expressions over a million rows, inlined and
-- materialized, compiled and not. A server without LLVM compiles nothing.
call pgmb.reg('cte.jit_off_inlined', '{perf,consistency,olap}', $q$
begin;
set local jit = off;
with c as (select kind, amount * 2 + seq % 7 as x, case when amount > 100 then 1 else 0 end as big from g_child)
select kind, sum(x), sum(big) from c group by kind;
commit;$q$, equiv => 'cte.jit');
call pgmb.reg('cte.jit_on_inlined', '{perf,consistency,olap}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
set local jit_optimize_above_cost = 0;
set local jit_inline_above_cost = 0;
with c as (select kind, amount * 2 + seq % 7 as x, case when amount > 100 then 1 else 0 end as big from g_child)
select kind, sum(x), sum(big) from c group by kind;
commit;$q$, equiv => 'cte.jit');
call pgmb.reg('cte.jit_off_materialized', '{perf,consistency,olap}', $q$
begin;
set local jit = off;
with c as materialized (select kind, amount * 2 + seq % 7 as x, case when amount > 100 then 1 else 0 end as big from g_child)
select kind, sum(x), sum(big) from c group by kind;
commit;$q$, equiv => 'cte.jit');
call pgmb.reg('cte.jit_on_materialized', '{perf,consistency,olap}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
set local jit_optimize_above_cost = 0;
set local jit_inline_above_cost = 0;
with c as materialized (select kind, amount * 2 + seq % 7 as x, case when amount > 100 then 1 else 0 end as big from g_child)
select kind, sum(x), sum(big) from c group by kind;
commit;$q$, equiv => 'cte.jit');
-- a short CTE query, where compiling is all cost
call pgmb.reg('cte.jit_forced_point_lookup', '{perf,oltp,consistency}', $q$
begin;
set local jit = on;
set local jit_above_cost = 0;
with c as (select id, val * 2 + grp as x from g_parent where id = :id) select x from c;
commit;$q$, setup => '\set id random(1, :n_g_parent)', equiv => 'cte.jit_point');
call pgmb.reg('cte.jit_off_point_lookup', '{perf,oltp,consistency}', $q$
begin;
set local jit = off;
with c as (select id, val * 2 + grp as x from g_parent where id = :id) select x from c;
commit;$q$, setup => '\set id random(1, :n_g_parent)', equiv => 'cte.jit_point');

------------------------------------------------------------------------------
-- extended statistics through a CTE
------------------------------------------------------------------------------
-- Two conditions on columns that are the same thing: without extended
-- statistics the planner multiplies their selectivities (1/100 * 1/100), with
-- them it knows that one implies the other. The analyze check shows the
-- estimate; the rows are the same.
call pgmb.reg('cte.extstats_dependent_filter_plain', '{perf,planning,analyze,consistency}', $q$
with c as (select id, d from g_cte_stats where a = :v and b = :v) select count(*), sum(d) from c$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.extstats_filter');
call pgmb.reg('cte.extstats_dependent_filter_ext', '{perf,planning,analyze,consistency}', $q$
with c as (select id, d from g_cte_stats_ext where a = :v and b = :v) select count(*), sum(d) from c$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.extstats_filter');
call pgmb.reg('cte.extstats_dependent_filter_ext_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, d from g_cte_stats_ext where a = :v and b = :v) select count(*), sum(d) from c$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.extstats_filter');
-- the filter written outside the CTE: it reaches the table only when inlined
call pgmb.reg('cte.extstats_dependent_filter_outside_inlined', '{perf,planning,analyze,consistency}', $q$
with c as (select id, a, b, d from g_cte_stats_ext) select count(*), sum(d) from c where a = :v and b = :v$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.extstats_filter');
call pgmb.reg('cte.extstats_dependent_filter_outside_materialized', '{perf,planning,analyze,consistency}', $q$
with c as materialized (select id, a, b, d from g_cte_stats_ext) select count(*), sum(d) from c where a = :v and b = :v$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.extstats_filter');

-- number of groups: 100, not 100 * 100 * 10
call pgmb.reg('cte.extstats_ndistinct_group_by_plain', '{perf,planning,analyze,consistency}', $q$
with c as (select a, b, c, count(*) as n from g_cte_stats group by a, b, c) select count(*), sum(n) from c$q$,
    equiv => 'cte.extstats_groups');
call pgmb.reg('cte.extstats_ndistinct_group_by_ext', '{perf,planning,analyze,consistency}', $q$
with c as (select a, b, c, count(*) as n from g_cte_stats_ext group by a, b, c) select count(*), sum(n) from c$q$,
    equiv => 'cte.extstats_groups');

-- the estimate decides the join that follows
call pgmb.reg('cte.extstats_join_after_filter_plain', '{perf,planning,analyze,consistency}', $q$
with c as (select id, d from g_cte_stats where a = :v and b = :v and c = :v / 10)
select count(*), sum(n.k_100) from c join g_narrow n on n.id = c.id$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.extstats_join');
call pgmb.reg('cte.extstats_join_after_filter_ext', '{perf,planning,analyze,consistency}', $q$
with c as (select id, d from g_cte_stats_ext where a = :v and b = :v and c = :v / 10)
select count(*), sum(n.k_100) from c join g_narrow n on n.id = c.id$q$,
    setup => '\set v random(0, 99)', equiv => 'cte.extstats_join');

------------------------------------------------------------------------------
-- equivalence classes across the CTE boundary
------------------------------------------------------------------------------
-- a.id = b.parent_id and a.id = :id: when both CTEs are inlined the planner
-- derives b.parent_id = :id and reads one parent's children by index; when
-- they are materialized it cannot
call pgmb.reg('cte.eqclass_two_ctes_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with a as (select id, grp from g_parent), b as (select parent_id, amount from g_child)
select count(*), sum(b.amount) from a join b on b.parent_id = a.id where a.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.eqclass_two');
call pgmb.reg('cte.eqclass_two_ctes_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with a as materialized (select id, grp from g_parent), b as materialized (select parent_id, amount from g_child)
select count(*), sum(b.amount) from a join b on b.parent_id = a.id where a.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.eqclass_two');
-- only the second one materialized: the constant reaches a, not b
call pgmb.reg('cte.eqclass_two_ctes_second_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with a as (select id, grp from g_parent), b as materialized (select parent_id, amount from g_child)
select count(*), sum(b.amount) from a join b on b.parent_id = a.id where a.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.eqclass_two');

-- a chain of three equalities over three CTEs; the constant is on the last one
call pgmb.reg('cte.eqclass_chain_of_three_inlined', '{perf,planning,analyze,consistency,oltp}', $q$
with a as (select id from g_parent), b as (select parent_id, amount from g_child), c as (select id, code from g_dim)
select count(*), sum(b.amount)
from a join b on b.parent_id = a.id join g_parent p on p.id = a.id join c on c.id = p.dim_id
where a.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.eqclass_chain');
call pgmb.reg('cte.eqclass_chain_of_three_as_tables', '{perf,planning,analyze,consistency,oltp}', $q$
select count(*), sum(b.amount)
from g_parent a join g_child b on b.parent_id = a.id join g_parent p on p.id = a.id join g_dim c on c.id = p.dim_id
where a.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.eqclass_chain');

-- the equality inside the CTE and the constant outside
call pgmb.reg('cte.eqclass_equality_inside_constant_outside', '{perf,planning,analyze,consistency,oltp}', $q$
with c as (select p.id, ch.amount from g_parent p join g_child ch on ch.parent_id = p.id)
select count(*), sum(amount) from c where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.eqclass_inside');
call pgmb.reg('cte.eqclass_equality_inside_constant_outside_materialized', '{perf,planning,analyze,consistency,olap}', $q$
with c as materialized (select p.id, ch.amount from g_parent p join g_child ch on ch.parent_id = p.id)
select count(*), sum(amount) from c where id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.eqclass_inside');

------------------------------------------------------------------------------
-- Memoize and parameterized paths into a CTE
------------------------------------------------------------------------------
-- 10,000 outer rows, ten distinct keys. An inlined CTE can be the inner side
-- of a parameterized nested loop with a cache in front; a CTE Scan has no
-- parameterized path and is read from its store for every outer row.
\set pgmb_cmemo_on 'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\nset local enable_material = off;\n'
\set pgmb_cmemo_off 'begin;\nset local enable_hashjoin = off;\nset local enable_mergejoin = off;\nset local enable_material = off;\nset local enable_memoize = off;\n'
\set pgmb_cmemo_end ';\ncommit;'

call pgmb.reg('cte.memoize_inner_inlined_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_cmemo_on' || $q$
with d as (select id, code from g_dim)
select count(*), sum(length(d.code)) from g_narrow n join d on d.id = n.k_100 % 10 + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_cmemo_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.memoize_inner');
call pgmb.reg('cte.memoize_inner_inlined_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_cmemo_off' || $q$
with d as (select id, code from g_dim)
select count(*), sum(length(d.code)) from g_narrow n join d on d.id = n.k_100 % 10 + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_cmemo_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.memoize_inner');
call pgmb.reg('cte.memoize_inner_materialized', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_cmemo_on' || $q$
with d as materialized (select id, code from g_dim)
select count(*), sum(length(d.code)) from g_narrow n join d on d.id = n.k_100 % 10 + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_cmemo_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.memoize_inner');

-- the cached value is an aggregate over the children of a CTE's row
call pgmb.reg('cte.memoize_lateral_over_cte_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_cmemo_on' || $q$
with ch as (select parent_id, amount from g_child)
select count(*), sum(s.total) from g_narrow n,
     lateral (select sum(amount) as total from ch where ch.parent_id = n.k_100 + 1) s
where n.id between :id and :id + 999$q$ || :'pgmb_cmemo_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.memoize_lateral');
call pgmb.reg('cte.memoize_lateral_over_cte_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_cmemo_off' || $q$
with ch as (select parent_id, amount from g_child)
select count(*), sum(s.total) from g_narrow n,
     lateral (select sum(amount) as total from ch where ch.parent_id = n.k_100 + 1) s
where n.id between :id and :id + 999$q$ || :'pgmb_cmemo_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.memoize_lateral');

-- keys that are mostly different: the cache costs more than it saves
call pgmb.reg('cte.memoize_many_keys_on', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_cmemo_on' || $q$
with p as (select id, grp from g_parent)
select count(*), sum(p.grp) from g_narrow n join p on p.id = n.k_10k % :n_g_parent + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_cmemo_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.memoize_many');
call pgmb.reg('cte.memoize_many_keys_off', '{perf,planning,analyze,consistency,needs_data}', :'pgmb_cmemo_off' || $q$
with p as (select id, grp from g_parent)
select count(*), sum(p.grp) from g_narrow n join p on p.id = n.k_10k % :n_g_parent + 1
where n.id between :id and :id + 9999$q$ || :'pgmb_cmemo_end',
    setup => '\set id random(1, :n_g_narrow)', equiv => 'cte.memoize_many');
