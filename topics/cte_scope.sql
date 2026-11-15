-- Topic: cte (part 12) - names and scopes.
-- CTE names against table names, shadowing, forward references, column lists,
-- aliases and ambiguity, VALUES / TABLE / scalar subqueries, correlation with
-- the outer query, UNION branches, names added by SEARCH and CYCLE.
-- Mostly cheap to execute: these are parser and planner tests.
-- Elsewhere: cte.nested_shadow*, cte.nested_sibling_scopes (shadowing of an
-- outer CTE), cte.err_forward_reference, cte.err_duplicate_name.

------------------------------------------------------------------------------
-- a CTE named like a real table
------------------------------------------------------------------------------
-- inside its own body the name still means the table
call pgmb.reg('cte.scope_cte_named_like_table', '{perf,planning,consistency,oltp}', $q$
with g_parent as (select id, val from g_parent where id = :id)
select id, val from g_parent$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_named');

call pgmb.reg('cte.scope_cte_named_differently', '{perf,planning,consistency,oltp}', $q$
with c as (select id, val from g_parent where id = :id)
select id, val from c$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_named');

-- the CTE hides the table, the schema-qualified name still reaches it
call pgmb.reg('cte.scope_hidden_table_reached_by_schema', '{perf,planning,oltp}', $q$
with g_parent as (select 1 as marker)
select (select count(*) from g_parent) as cte_rows,
       (select val from pgmb_data.g_parent where id = :id) as table_val$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.scope_cte_joined_to_table_of_same_name', '{perf,planning,oltp}', $q$
with g_parent as (select id, val * 2 as val from g_parent where id between :id and :id + 9)
select count(*), sum(c.val - t.val) from g_parent c join pgmb_data.g_parent t on t.id = c.id$q$,
    setup => '\set id random(1, :n_g_parent)');

-- a later CTE sees the earlier CTE under that name, not the table
call pgmb.reg('cte.scope_later_cte_sees_cte_not_table', '{perf,planning,oltp}', $q$
with g_parent as (select id, val from g_parent where id = :id),
     twice as (select id, val from g_parent union all select id, val from g_parent)
select count(*) from twice$q$,
    setup => '\set id random(1, :n_g_parent)');

-- a CTE whose body starts another WITH with the same name
call pgmb.reg('cte.scope_inner_with_same_name', '{perf,planning,oltp}', $q$
with a as (
    with a as (select id, val from g_parent where id = :id)
    select id, val, 'inner' as origin from a)
select * from a$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- forward references
------------------------------------------------------------------------------
call pgmb.reg('cte.scope_forward_reference_with_recursive', '{perf,planning,consistency,oltp}', $q$
with recursive a as (select id, val from b),
               b as (select id, val from g_parent where id = :id)
select * from a$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_forward');

call pgmb.reg('cte.scope_backward_reference', '{perf,planning,consistency,oltp}', $q$
with b as (select id, val from g_parent where id = :id),
     a as (select id, val from b)
select * from a$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_forward');

-- RECURSIVE only to allow any order: five CTEs written backwards
call pgmb.reg('cte.scope_recursive_keyword_reversed_chain', '{perf,planning,consistency}', $q$
with recursive e as (select grp, sum(n) as n from d group by grp),
               d as (select grp, count(*) as n from c group by grp, id % 2),
               c as (select id, grp from b where id % 3 <> 0),
               b as (select id, grp from a),
               a as (select id, grp from g_parent where id between :id and :id + 300)
select count(*), sum(n) from e$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_chain');

call pgmb.reg('cte.scope_plain_ordered_chain', '{perf,planning,consistency}', $q$
with a as (select id, grp from g_parent where id between :id and :id + 300),
     b as (select id, grp from a),
     c as (select id, grp from b where id % 3 <> 0),
     d as (select grp, count(*) as n from c group by grp, id % 2),
     e as (select grp, sum(n) as n from d group by grp)
select count(*), sum(n) from e$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_chain');

-- RECURSIVE on a WITH that has no recursion at all
call pgmb.reg('cte.scope_recursive_keyword_unused', '{perf,planning,oltp}', $q$
with recursive c as (select id, val from g_parent where id = :id)
select * from c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.err_scope_mutual_recursion', '{errors}',
    $q$with recursive a as (select 1 as n union all select n from b), b as (select n from a) select * from a$q$, expect_error => '0A000');

------------------------------------------------------------------------------
-- column lists, aliases, ambiguity
------------------------------------------------------------------------------
call pgmb.reg('cte.scope_column_list_full', '{perf,planning,oltp}', $q$
with c(parent_key, amount_total) as (select id, val from g_parent where id = :id)
select parent_key, amount_total from c$q$,
    setup => '\set id random(1, :n_g_parent)');

-- fewer aliases than columns: the rest keep their names
call pgmb.reg('cte.scope_column_list_partial', '{perf,planning,oltp}', $q$
with c(parent_key) as (select id, val, grp from g_parent where id = :id)
select parent_key, val, grp from c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.scope_column_list_names_expressions', '{perf,planning,oltp}', $q$
with c(k, total, n) as (select grp, sum(val), count(*) from g_parent where id between :id and :id + 99 group by grp)
select k, total / n from c order by k$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.err_scope_too_many_column_aliases', '{errors}',
    $q$with c(a, b, c) as (select id, val from g_parent where id = 1) select * from c$q$, expect_error => '42P10');

-- aliases remove the ambiguity of two id columns
call pgmb.reg('cte.scope_aliases_resolve_ambiguity', '{perf,planning,oltp}', $q$
with c(pid, pval) as (select id, val from g_parent where id = :id)
select pid, id, pval from c join g_child on parent_id = pid order by id limit 5$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.err_scope_ambiguous_without_aliases', '{errors}',
    $q$with c as (select id, val from g_parent where id = 1) select id from c join g_child on parent_id = c.id$q$, expect_error => '42702');

-- two columns of the same name inside a CTE are fine until one is named
call pgmb.reg('cte.scope_duplicate_column_names_unreferenced', '{perf,planning,oltp}', $q$
with c as (select p.id, ch.id from g_parent p join g_child ch on ch.parent_id = p.id where p.id = :id)
select count(*) from c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.err_scope_duplicate_column_names_referenced', '{errors}',
    $q$with c as (select p.id, ch.id from g_parent p join g_child ch on ch.parent_id = p.id where p.id = 1) select id from c$q$, expect_error => '42702');

-- the table alias of the reader hides the CTE name
call pgmb.reg('cte.scope_reader_alias_hides_cte_name', '{perf,planning,oltp}', $q$
with c as (select id, val from g_parent where id between :id and :id + 9)
select x.id, y.id from c x join c y on y.id = x.id + 1$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.err_scope_cte_name_after_alias', '{errors}',
    $q$with c as (select id from g_parent where id = 1) select c.id from c x$q$, expect_error => '42P01');

------------------------------------------------------------------------------
-- VALUES, TABLE and scalar subqueries
------------------------------------------------------------------------------
call pgmb.reg('cte.scope_values_table_scalar_mixed', '{perf,planning}', $q$
with v(k, label) as (values (0, 'zero'), (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four')),
     t as (table g_dim),
     s as (select (select max(id) from g_dim) as max_dim)
select v.label, count(*) as n, min(t.code) as first_code, s.max_dim
from g_parent p join v on v.k = p.status join t on t.id = p.dim_id cross join s
where p.id between :id and :id + 199
group by v.label, s.max_dim order by v.label$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.scope_cte_as_scalar_subquery', '{perf,planning,oltp}', $q$
with mx as (select max(val) as v from g_parent where id between :id and :id + 99),
     mn as (select min(val) as v from g_parent where id between :id and :id + 99)
select id, val, (select v from mx) - val as below_max
from g_parent where id between :id and :id + 99 and val > ((select v from mx) + (select v from mn)) / 2$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.scope_table_command_over_cte', '{perf,planning,oltp}', $q$
with c as (select id, val from g_parent where id between :id and :id + 9)
table c$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.scope_values_main_statement', '{perf,planning,oltp}', $q$
with c as (select id from g_parent where id = :id)
values ((select id from c), (select count(*) from c))$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- nested WITH using columns of the outer query
------------------------------------------------------------------------------
call pgmb.reg('cte.scope_correlated_with_in_select_list', '{perf,planning,consistency}', $q$
select p.id, (with c as (select amount from g_child where parent_id = p.id) select coalesce(sum(amount), 0) from c) as total
from g_parent p where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_correlated');

call pgmb.reg('cte.scope_correlated_with_materialized', '{perf,planning,consistency}', $q$
select p.id, (with c as materialized (select amount from g_child where parent_id = p.id) select coalesce(sum(amount), 0) from c) as total
from g_parent p where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_correlated');

call pgmb.reg('cte.scope_correlated_with_in_lateral', '{perf,planning,consistency}', $q$
select p.id, s.total
from g_parent p, lateral (with c as (select amount from g_child where parent_id = p.id)
                          select coalesce(sum(amount), 0) as total from c) s
where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'cte.scope_correlated');

call pgmb.reg('cte.scope_correlated_with_in_where', '{perf,planning}', $q$
select count(*) from g_parent p
where p.id between :id and :id + 99
  and exists (with c as (select 1 from g_child where parent_id = p.id and kind = 3) select 1 from c)$q$,
    setup => '\set id random(1, :n_g_parent)');

-- two levels up
call pgmb.reg('cte.scope_correlated_two_levels_up', '{perf,planning}', $q$
select p.id,
       (select count(*) from g_child ch
        where ch.parent_id = p.id
          and ch.amount > (with c as (select p.val / 100 as threshold) select threshold from c)) as above
from g_parent p where p.id between :id and :id + 19$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- UNION branches
------------------------------------------------------------------------------
-- each branch has its own WITH; the same name means different things
call pgmb.reg('cte.scope_union_branches_own_with', '{perf,planning,oltp}', $q$
(with a as (select id, val from g_parent where id = :id) select 'first' as branch, id, val from a)
union all
(with a as (select id, val from g_parent where id = :id + 1) select 'second', id, val from a)$q$,
    setup => '\set id random(1, :n_g_parent - 1)');

-- a WITH in front of the whole UNION is visible in every branch
call pgmb.reg('cte.scope_union_shared_with', '{perf,planning,oltp}', $q$
with base as (select id, grp, val from g_parent where id between :id and :id + 99)
select 'low' as part, count(*), sum(val) from base where grp < 50
union all
select 'high', count(*), sum(val) from base where grp >= 50
union all
(with base as (select 0::numeric as val) select 'shadowed', count(*), sum(val) from base)$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('cte.err_scope_union_branch_cte_not_visible', '{errors}',
    $q$(with a as (select 1 as x) select x from a) union all (select x from a)$q$, expect_error => '42P01');

-- the trailing ORDER BY / LIMIT belong to the UNION, the WITH to all of it
call pgmb.reg('cte.scope_union_with_order_limit', '{perf,planning,oltp}', $q$
with base as (select id, val from g_parent where id between :id and :id + 99)
select id, val from base where id % 2 = 0
union all
select id, -val from base where id % 2 = 1
order by id limit 10$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- column names added by SEARCH and CYCLE
------------------------------------------------------------------------------
-- a generated column named like an existing one makes the recursive term's own
-- reference ambiguous (42702); two generated columns of one name are a syntax error
call pgmb.reg('cte.err_scope_search_column_collides', '{errors}',
    $q$with recursive t(id) as (select 1 union all select id + 1 from t where id < 3) search depth first by id set id select * from t$q$, expect_error => '42702');
call pgmb.reg('cte.err_scope_cycle_mark_column_collides', '{errors}',
    $q$with recursive t(id) as (select 1 union all select id + 1 from t where id < 3) cycle id set id using path select * from t$q$, expect_error => '42702');
call pgmb.reg('cte.err_scope_cycle_path_column_collides', '{errors}',
    $q$with recursive t(id) as (select 1 union all select id + 1 from t where id < 3) cycle id set is_cycle using id select * from t$q$, expect_error => '42702');
call pgmb.reg('cte.err_scope_search_and_cycle_same_column', '{errors}',
    $q$with recursive t(id) as (select 1 union all select id + 1 from t where id < 3) search depth first by id set seq cycle id set is_cycle using seq select * from t$q$, expect_error => '42601');
call pgmb.reg('cte.err_scope_cycle_mark_same_as_path', '{errors}',
    $q$with recursive t(id) as (select 1 union all select id + 1 from t where id < 3) cycle id set x using x select * from t$q$, expect_error => '42601');

-- the added columns can be renamed by the reader and do not clash with table columns
call pgmb.reg('cte.scope_search_cycle_columns_beside_same_names', '{perf,planning}', $q$
with recursive sub(id, parent_id) as (
    select id, parent_id from g_tree where id = :id
    union all
    select t.id, t.parent_id from g_tree t join sub s on t.parent_id = s.id)
search breadth first by id set ord
cycle id set is_cycle using path
select s.id, s.ord as search_ord, t.depth as ord, t.val as path
from sub s join g_tree t on t.id = s.id where not s.is_cycle order by s.ord limit 20$q$,
    setup => '\set id random(1, :n_g_tree / 16 + 1)');
