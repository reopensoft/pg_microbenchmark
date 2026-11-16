-- Topic: array (part 5) - the remaining functions and operators of intarray
-- (sort_asc, sort_desc, idx, subarray, icount and #, intset, the set
-- operators), and integer paths in recursive queries: built-in || against
-- intarray +, four ways of detecting a cycle, a path against the set of
-- visited nodes, paths of 1 to 10,000 elements.
-- Registered only with -v intarray=1; see array_intarray.sql for the schema.
\if :pgmb_has_intarray

------------------------------------------------------------------------------
-- sort, sort_asc, sort_desc
------------------------------------------------------------------------------
call pgmb.reg('array.intarray_sort_family', '{consistency}', pgmb.ia($q$
select pgmb_intarray.sort(a)::text, pgmb_intarray.sort_asc(a)::text, pgmb_intarray.sort(a, 'asc')::text,
       pgmb_intarray.sort_desc(a)::text, pgmb_intarray.sort(a, 'desc')::text
from (select array[3, 1, 2, 3, -5] as a) s$q$), equiv => 'array.intarray_sort_family');
call pgmb.reg('array.intarray_sort_family_expected', '{consistency}', $q$
select '{-5,1,2,3,3}'::text, '{-5,1,2,3,3}'::text, '{-5,1,2,3,3}'::text, '{3,3,2,1,-5}'::text, '{3,3,2,1,-5}'::text$q$,
    equiv => 'array.intarray_sort_family');

-- the largest of 100 elements, for 1000 rows, four ways
call pgmb.reg('array.intarray_sort_desc_first', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum((pgmb_intarray.sort_desc(arr100))[1]) from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_max100');
call pgmb.reg('array.intarray_sort_with_direction_first', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum((pgmb_intarray.sort(arr100, 'desc'))[1]) from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_max100');
call pgmb.reg('array.intarray_sort_asc_last', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum((pgmb_intarray.sort_asc(arr100))[100]) from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_max100');
call pgmb.reg('array.intarray_max_by_unnest', '{perf,planning,consistency,needs_data}', $q$
select sum((select max(x) from unnest(arr100) x)) from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_max100');

------------------------------------------------------------------------------
-- idx
------------------------------------------------------------------------------
-- the first position of a value, 0 when it is not there
call pgmb.reg('array.intarray_idx_cases', '{consistency}', pgmb.ia($q$
select pgmb_intarray.idx(array[5, 7, 5], 5), pgmb_intarray.idx(array[5, 7, 5], 7), pgmb_intarray.idx(array[5, 7, 5], 9),
       pgmb_intarray.idx('{}'::integer[], 1), pgmb_intarray.idx(array[2147483647, -2147483648], -2147483648),
       pgmb_intarray.idx(array[1, 2, 3], 3), array[5, 7, 5] operator(pgmb_intarray.#) 7$q$),
    equiv => 'array.intarray_idx');
call pgmb.reg('array.intarray_idx_cases_expected', '{consistency}',
    $q$select 1, 2, 0, 0, 2, 3, 2$q$, equiv => 'array.intarray_idx');

call pgmb.reg('array.intarray_idx_100_elements', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum(pgmb_intarray.idx(arr100, arr100[50] + :d)) from g_intarr where id between :id and :id + 999$q$),
    setup => E'\\set id random(1, :n_g_intarr)\n\\set d random(0, 1)', equiv => 'array.intarray_idx100');
call pgmb.reg('array.intarray_idx_as_array_position', '{perf,planning,consistency,needs_data}', $q$
select sum(coalesce(array_position(arr100, arr100[50] + :d), 0)) from g_intarr where id between :id and :id + 999$q$,
    setup => E'\\set id random(1, :n_g_intarr)\n\\set d random(0, 1)', equiv => 'array.intarray_idx100');

------------------------------------------------------------------------------
-- subarray
------------------------------------------------------------------------------
-- from a position to the end; a position and a length; a negative position
-- counts from the end, a negative length leaves that many elements off
call pgmb.reg('array.intarray_subarray_cases', '{consistency}', pgmb.ia($q$
select pgmb_intarray.subarray(a, 2)::text, pgmb_intarray.subarray(a, 2, 2)::text, pgmb_intarray.subarray(a, -2)::text,
       pgmb_intarray.subarray(a, 2, -1)::text, pgmb_intarray.subarray(a, 1, 100)::text, pgmb_intarray.subarray(a, 6)::text
from (select array[1, 2, 3, 4, 5] as a) s$q$), equiv => 'array.intarray_subarray');
call pgmb.reg('array.intarray_subarray_cases_expected', '{consistency}', $q$
select '{2,3,4,5}'::text, '{2,3}'::text, '{4,5}'::text, '{2,3,4}'::text, '{1,2,3,4,5}'::text, '{}'::text$q$,
    equiv => 'array.intarray_subarray');

call pgmb.reg('array.intarray_subarray_10_of_100', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum((pgmb_intarray.subarray(arr100, 11, 10))[1]), sum(cardinality(pgmb_intarray.subarray(arr100, 11, 10)))
from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_slice');
call pgmb.reg('array.intarray_subarray_as_slice', '{perf,planning,consistency,needs_data}', $q$
select sum(arr100[11]), sum(cardinality(arr100[11 : 20]))
from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_slice');

------------------------------------------------------------------------------
-- icount, #, intset
------------------------------------------------------------------------------
call pgmb.reg('array.intarray_count_cases', '{consistency}', pgmb.ia($q$
select pgmb_intarray.icount(array[1, 2, 2]), operator(pgmb_intarray.#) array[1, 2, 2], pgmb_intarray.icount('{}'::integer[]),
       cardinality('{}'::integer[]), array_length('{}'::integer[], 1) is null,
       pgmb_intarray.intset(7)::text, pgmb_intarray.intset(7) = array[7]$q$), equiv => 'array.intarray_count');
call pgmb.reg('array.intarray_count_cases_expected', '{consistency}',
    $q$select 3, 3, 0, 0, true, '{7}'::text, true$q$, equiv => 'array.intarray_count');

call pgmb.reg('array.intarray_icount_100_elements', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum(pgmb_intarray.icount(arr100)) from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_len100');
call pgmb.reg('array.intarray_count_operator_100_elements', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum(operator(pgmb_intarray.#) arr100) from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_len100');
call pgmb.reg('array.intarray_cardinality_100_elements', '{perf,planning,consistency,needs_data}', $q$
select sum(cardinality(arr100)) from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_len100');

-- a one-element array as a search key, built with intset() and with ARRAY[]
call pgmb.reg('array.intarray_intset_as_search_key', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@>) pgmb_intarray.intset(:v)$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_intset');
call pgmb.reg('array.intarray_array_constructor_as_search_key', '{perf,planning,consistency,oltp}', pgmb.ia($q$
select count(*) from g_intarr where arr5 operator(pgmb_intarray.@>) array[:v]$q$),
    setup => '\set v random(0, 9999)', equiv => 'array.intarray_intset');

------------------------------------------------------------------------------
-- set operators: | & + -
------------------------------------------------------------------------------
-- | and & return sorted sets; + only appends; - removes every occurrence
call pgmb.reg('array.intarray_set_operator_cases', '{consistency}', pgmb.ia($q$
select (array[3, 1] operator(pgmb_intarray.|) array[2, 3])::text, (array[3, 1] operator(pgmb_intarray.|) 2)::text,
       (array[1, 2, 3, 2] operator(pgmb_intarray.&) array[2, 5])::text,
       (array[3, 1] operator(pgmb_intarray.+) array[1, 2])::text, (array[3, 1] operator(pgmb_intarray.+) 1)::text,
       (array[1, 2, 3, 2] operator(pgmb_intarray.-) 2)::text,
       (array[1, 2, 3, 2] operator(pgmb_intarray.-) array[2, 3])::text$q$), equiv => 'array.intarray_set_ops');
call pgmb.reg('array.intarray_set_operator_cases_expected', '{consistency}', $q$
select '{1,2,3}'::text, '{1,2,3}'::text, '{2}'::text, '{3,1,1,2}'::text, '{3,1,1}'::text, '{1,3}'::text, '{1}'::text$q$,
    equiv => 'array.intarray_set_ops');

-- the union of two columns of 1000 rows, by the operator and by hand
call pgmb.reg('array.intarray_union_operator', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
select sum(pgmb_intarray.icount(arr5 operator(pgmb_intarray.|) arr10)) from g_intarr where id between :id and :id + 999$q$),
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_union');
call pgmb.reg('array.intarray_union_by_unnest', '{perf,planning,consistency,needs_data}', $q$
select sum((select count(distinct x) from unnest(arr5 || arr10) x)) from g_intarr where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_intarr)', equiv => 'array.intarray_union');

------------------------------------------------------------------------------
-- a path in a recursive query: built-in || against intarray +
------------------------------------------------------------------------------
-- four levels down the tree from one node, every row carrying the way to it
call pgmb.reg('array.intarray_path_builtin_concat', '{perf,planning,consistency,needs_data}', $q$
with recursive w(id, path) as (
    select id::int, array[id::int] from g_tree where id = :r
    union all
    select t.id::int, w.path || t.id::int from g_tree t join w on t.parent_id = w.id where cardinality(w.path) < 5)
select count(*), sum(cardinality(path)), sum(path[cardinality(path)]) from w$q$,
    setup => '\set r random(1, 20)', equiv => 'array.intarray_path');
call pgmb.reg('array.intarray_path_extension_plus', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
with recursive w(id, path) as (
    select id::int, array[id::int] from g_tree where id = :r
    union all
    select t.id::int, w.path operator(pgmb_intarray.+) t.id::int from g_tree t join w on t.parent_id = w.id
    where pgmb_intarray.icount(w.path) < 5)
select count(*), sum(cardinality(path)), sum(path[cardinality(path)]) from w$q$),
    setup => '\set r random(1, 20)', equiv => 'array.intarray_path');
call pgmb.reg('array.intarray_path_array_append', '{perf,planning,consistency,needs_data}', $q$
with recursive w(id, path) as (
    select id::int, array[id::int] from g_tree where id = :r
    union all
    select t.id::int, array_append(w.path, t.id::int) from g_tree t join w on t.parent_id = w.id
    where cardinality(w.path) < 5)
select count(*), sum(cardinality(path)), sum(path[cardinality(path)]) from w$q$,
    setup => '\set r random(1, 20)', equiv => 'array.intarray_path');

------------------------------------------------------------------------------
-- detecting a cycle: is the next node already on the path?
------------------------------------------------------------------------------
-- walks of up to five nodes through the cyclic graph, never entering a node twice
call pgmb.reg('array.intarray_cycle_not_equal_all', '{perf,planning,consistency,needs_data}', $q$
with recursive w(node, path) as (
    select :s, array[:s]
    union all
    select g.dst::int, w.path || g.dst::int from g_graph g join w on g.src = w.node
    where cardinality(w.path) < 5 and g.dst::int <> all (w.path))
select count(*), sum(node) from w$q$,
    setup => '\set s random(1, :n_g_graph_nodes)', equiv => 'array.intarray_cycle');
call pgmb.reg('array.intarray_cycle_idx_is_zero', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
with recursive w(node, path) as (
    select :s, array[:s]
    union all
    select g.dst::int, w.path || g.dst::int from g_graph g join w on g.src = w.node
    where cardinality(w.path) < 5 and pgmb_intarray.idx(w.path, g.dst::int) = 0)
select count(*), sum(node) from w$q$),
    setup => '\set s random(1, :n_g_graph_nodes)', equiv => 'array.intarray_cycle');
call pgmb.reg('array.intarray_cycle_not_contains_extension', '{perf,planning,consistency,needs_data}', pgmb.ia($q$
with recursive w(node, path) as (
    select :s, array[:s]
    union all
    select g.dst::int, w.path || g.dst::int from g_graph g join w on g.src = w.node
    where cardinality(w.path) < 5 and not (w.path operator(pgmb_intarray.@>) array[g.dst::int]))
select count(*), sum(node) from w$q$),
    setup => '\set s random(1, :n_g_graph_nodes)', equiv => 'array.intarray_cycle');
call pgmb.reg('array.intarray_cycle_not_contains_builtin', '{perf,planning,consistency,needs_data}', $q$
with recursive w(node, path) as (
    select :s, array[:s]
    union all
    select g.dst::int, w.path || g.dst::int from g_graph g join w on g.src = w.node
    where cardinality(w.path) < 5 and not (w.path operator(pg_catalog.@>) array[g.dst::int]))
select count(*), sum(node) from w$q$,
    setup => '\set s random(1, :n_g_graph_nodes)', equiv => 'array.intarray_cycle');
-- the CYCLE clause keeps the path itself; rows that close a cycle are marked, not dropped
call pgmb.reg('array.intarray_cycle_clause', '{perf,planning,consistency,needs_data}', $q$
with recursive w(node, depth) as (
    select :s, 0
    union all
    select g.dst::int, w.depth + 1 from g_graph g join w on g.src = w.node where w.depth < 4)
    cycle node set is_cycle using cycle_path
select count(*) filter (where not is_cycle), sum(node) filter (where not is_cycle) from w$q$,
    setup => '\set s random(1, :n_g_graph_nodes)', equiv => 'array.intarray_cycle');

------------------------------------------------------------------------------
-- a path is not the set of visited nodes
------------------------------------------------------------------------------
call pgmb.reg('array.intarray_path_is_not_a_set', '{consistency}', pgmb.ia($q$
select array[3, 1, 3]::text, pgmb_intarray.uniq(pgmb_intarray.sort(array[3, 1, 3]))::text,
       cardinality(array[3, 1, 3]), pgmb_intarray.icount(pgmb_intarray.uniq(pgmb_intarray.sort(array[3, 1, 3]))),
       array[3, 1] = array[1, 3],
       pgmb_intarray.uniq(pgmb_intarray.sort(array[3, 1])) = pgmb_intarray.uniq(pgmb_intarray.sort(array[1, 3]))$q$),
    equiv => 'array.intarray_path_set');
call pgmb.reg('array.intarray_path_is_not_a_set_expected', '{consistency}',
    $q$select '{3,1,3}'::text, '{1,3}'::text, 3, 2, false, true$q$, equiv => 'array.intarray_path_set');

-- The same walk with two kinds of state. With the path, every way of reaching
-- a node is a row. With the sorted set of visited nodes and UNION, two ways
-- through the same nodes are one row: never more rows than paths.
call pgmb.reg('array.intarray_walk_state_is_path', '{perf,planning,needs_data}', $q$
with recursive w(node, path) as (
    select :s, array[:s]
    union all
    select g.dst::int, w.path || g.dst::int from g_graph g join w on g.src = w.node
    where cardinality(w.path) < 5 and g.dst::int <> all (w.path))
select count(*) from w$q$, setup => '\set s random(1, :n_g_graph_nodes)');
call pgmb.reg('array.intarray_walk_state_is_visited_set', '{perf,planning,needs_data}', pgmb.ia($q$
with recursive w(node, seen) as (
    select :s, array[:s]
    union
    select g.dst::int, pgmb_intarray.uniq(pgmb_intarray.sort(w.seen operator(pgmb_intarray.+) g.dst::int))
    from g_graph g join w on g.src = w.node
    where pgmb_intarray.icount(w.seen) < 5 and pgmb_intarray.idx(w.seen, g.dst::int) = 0)
select count(*) from w$q$), setup => '\set s random(1, :n_g_graph_nodes)');
call pgmb.reg('array.intarray_walk_sets_never_more_than_paths', '{consistency,needs_data}', pgmb.ia($q$
with recursive p(node, path) as (
    select 1, array[1]
    union all
    select g.dst::int, p.path || g.dst::int from g_graph g join p on g.src = p.node
    where cardinality(p.path) < 5 and g.dst::int <> all (p.path)),
s(node, seen) as (
    select 1, array[1]
    union
    select g.dst::int, pgmb_intarray.uniq(pgmb_intarray.sort(s.seen operator(pgmb_intarray.+) g.dst::int))
    from g_graph g join s on g.src = s.node
    where pgmb_intarray.icount(s.seen) < 5 and pgmb_intarray.idx(s.seen, g.dst::int) = 0)
select (select count(*) from s) <= (select count(*) from p)$q$), equiv => 'array.intarray_true');
call pgmb.reg('array.intarray_expected_true', '{consistency,needs_data}', $q$select true$q$, equiv => 'array.intarray_true');

------------------------------------------------------------------------------
-- growing paths: 1 to 10,000 elements in the working table
------------------------------------------------------------------------------
-- One row per step, each with a path one element longer: the path is copied
-- at every step. 10,000 steps keep 50 million elements in the result and are
-- opt-in (optin_long_path).
select format($f$call pgmb.reg('array.intarray_path_length_%1$s_builtin', %3$L, %4$L, equiv => 'array.intarray_path_len_%1$s')$f$,
              len, null, tags,
              format(E'with recursive r(n, path) as (\n    select 1, array[1]\n    union all\n'
                     '    select n + 1, path || (n + 1) from r where n < %s)\n'
                     'select max(cardinality(path)), sum(path[cardinality(path)]) from r', len))
from (values (1, '{perf,planning,consistency,oltp}'), (10, '{perf,planning,consistency,oltp}'),
             (100, '{perf,planning,consistency}'), (1000, '{perf,planning,consistency}'),
             (10000, '{perf,consistency,optin_long_path}')) v(len, tags) \gexec
select format($f$call pgmb.reg('array.intarray_path_length_%1$s_extension', %3$L, pgmb.ia(%4$L), equiv => 'array.intarray_path_len_%1$s')$f$,
              len, null, tags,
              format(E'with recursive r(n, path) as (\n    select 1, array[1]\n    union all\n'
                     '    select n + 1, path operator(pgmb_intarray.+) (n + 1) from r where n < %s)\n'
                     'select max(pgmb_intarray.icount(path)), sum(path[pgmb_intarray.icount(path)]) from r', len))
from (values (1, '{perf,planning,consistency,oltp}'), (10, '{perf,planning,consistency,oltp}'),
             (100, '{perf,planning,consistency}'), (1000, '{perf,planning,consistency}'),
             (10000, '{perf,consistency,optin_long_path}')) v(len, tags) \gexec

\endif
