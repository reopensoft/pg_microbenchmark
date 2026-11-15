-- Topic: MATERIALIZED / NOT MATERIALIZED.
-- Each case comes as default / MATERIALIZED / NOT MATERIALIZED. The variants of
-- a case form a consistency group: they must return identical rows.

-- Filter applied outside a single-reader CTE: inlined by default, fenced when MATERIALIZED.
call pgmb.reg('materialized.filter_default', '{perf,planning,consistency,oltp}', $q$
with c as (select id, parent_id, amount from g_child)
select * from c where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.filter');
call pgmb.reg('materialized.filter_materialized', '{perf,planning,consistency,olap}', $q$
with c as materialized (select id, parent_id, amount from g_child)
select * from c where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.filter');
call pgmb.reg('materialized.filter_not_materialized', '{perf,planning,consistency,oltp}', $q$
with c as not materialized (select id, parent_id, amount from g_child)
select * from c where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.filter');

-- CTE read twice: materialized by default, computed twice when NOT MATERIALIZED.
call pgmb.reg('materialized.two_readers_default', '{perf,planning,consistency}', $q$
with c as (select parent_id, sum(amount) as s from g_child where parent_id between :id and :id + 50 group by parent_id)
select a.parent_id, a.s, b.s as s_next from c a join c b on b.parent_id = a.parent_id + 1$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.two_readers');
call pgmb.reg('materialized.two_readers_materialized', '{perf,planning,consistency}', $q$
with c as materialized (select parent_id, sum(amount) as s from g_child where parent_id between :id and :id + 50 group by parent_id)
select a.parent_id, a.s, b.s as s_next from c a join c b on b.parent_id = a.parent_id + 1$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.two_readers');
call pgmb.reg('materialized.two_readers_not_materialized', '{perf,planning,consistency}', $q$
with c as not materialized (select parent_id, sum(amount) as s from g_child where parent_id between :id and :id + 50 group by parent_id)
select a.parent_id, a.s, b.s as s_next from c a join c b on b.parent_id = a.parent_id + 1$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.two_readers');

-- Join qual that can only reach the aggregate when the CTE is inlined.
call pgmb.reg('materialized.join_pushdown_default', '{perf,planning,consistency,oltp}', $q$
with c as (select parent_id, count(*) as n from g_child group by parent_id)
select p.id, c.n from g_parent p join c on c.parent_id = p.id where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.join_pushdown');
call pgmb.reg('materialized.join_pushdown_materialized', '{perf,planning,consistency,olap}', $q$
with c as materialized (select parent_id, count(*) as n from g_child group by parent_id)
select p.id, c.n from g_parent p join c on c.parent_id = p.id where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.join_pushdown');
call pgmb.reg('materialized.join_pushdown_not_materialized', '{perf,planning,consistency,oltp}', $q$
with c as not materialized (select parent_id, count(*) as n from g_child group by parent_id)
select p.id, c.n from g_parent p join c on c.parent_id = p.id where p.id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'materialized.join_pushdown');

-- ORDER BY ... LIMIT over the CTE: inlining lets the limit stop the scan early.
call pgmb.reg('materialized.limit_default', '{perf,planning,consistency}', $q$
with c as (select id, k_100, k_10k from g_narrow where k_100 = :k)
select * from c order by k_10k, id limit 10$q$,
    setup => '\set k random(0, 99)', equiv => 'materialized.limit');
call pgmb.reg('materialized.limit_materialized', '{perf,planning,consistency}', $q$
with c as materialized (select id, k_100, k_10k from g_narrow where k_100 = :k)
select * from c order by k_10k, id limit 10$q$,
    setup => '\set k random(0, 99)', equiv => 'materialized.limit');
call pgmb.reg('materialized.limit_not_materialized', '{perf,planning,consistency}', $q$
with c as not materialized (select id, k_100, k_10k from g_narrow where k_100 = :k)
select * from c order by k_10k, id limit 10$q$,
    setup => '\set k random(0, 99)', equiv => 'materialized.limit');

-- A volatile function forces materialization even when NOT MATERIALIZED is requested.
call pgmb.reg('materialized.volatile_forced', '{perf,planning}', $q$
with c as not materialized (select id, random() as r from g_parent where grp = :grp)
select count(*) from c where id % 7 = 0$q$,
    setup => '\set grp random(0, 99)');

-- Nested: an inlined CTE reading a materialized one.
call pgmb.reg('materialized.nested_mixed', '{perf,planning}', $q$
with m as materialized (select id, grp, val from g_parent where grp = :grp),
     n as not materialized (select grp, avg(val) as av from m group by grp)
select m.id from m join n using (grp) where m.val > n.av$q$,
    setup => '\set grp random(0, 99)');

call pgmb.reg('materialized.err_syntax_order', '{errors}',
    $q$with c materialized as (select 1) select * from c$q$, expect_error => '42601');
