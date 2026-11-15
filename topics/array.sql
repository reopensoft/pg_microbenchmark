-- Topic: arrays. Sizes from empty to 2000 elements, operators, GIN vs sequential plans.

------------------------------------------------------------------------------
-- operators with GIN support
------------------------------------------------------------------------------
call pgmb.reg('array.gin_contains', '{perf,planning,consistency,oltp}', $q$
select id from g_array where a_small @> array[:v]$q$,
    setup => '\set v random(0, 999)', equiv => 'array.contains');

call pgmb.reg('array.any_seqscan', '{perf,planning,consistency,olap}', $q$
select id from g_array where :v = any (a_small)$q$,
    setup => '\set v random(0, 999)', equiv => 'array.contains');

call pgmb.reg('array.gin_overlap', '{perf,planning}', $q$
select count(*) from g_array where a_med && array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

call pgmb.reg('array.gin_contains_2', '{perf,planning,oltp}', $q$
select count(*) from g_array where a_med @> array[:v, :w]$q$,
    setup => E'\\set v random(0, 9999)\n\\set w random(0, 9999)');

call pgmb.reg('array.gin_contained_by', '{perf,planning,olap}', $q$
select count(*) from g_array where a_small <@ array[:v, :v + 1, :v + 2, :v + 3]$q$,
    setup => '\set v random(0, 990)');

call pgmb.reg('array.gin_text_contains', '{perf,planning}', $q$
select count(*) from g_array where tags @> array['tag' || :v::text]$q$,
    setup => '\set v random(10, 49)');

call pgmb.reg('array.gin_equal', '{perf,planning,oltp}', $q$
select count(*) from g_array where a_small = array[:v]$q$,
    setup => '\set v random(0, 999)');

------------------------------------------------------------------------------
-- arrays as parameters
------------------------------------------------------------------------------
call pgmb.reg('array.any_index_4', '{perf,planning,oltp}', $q$
select id, val from g_parent where id = any (array[:a, :a + 7, :a + 31, :a + 101]::bigint[])$q$,
    setup => '\set a random(1, :n_g_parent)');

select string_agg((i * 7)::text, ',') as pgmb_ids from generate_series(1, 1000) i \gset
call pgmb.reg('array.any_index_1000', '{perf,planning}', format($q$
select count(*) from g_narrow where id = any ('{%s}'::bigint[])$q$, :'pgmb_ids'));

------------------------------------------------------------------------------
-- element access, construction, unnesting
------------------------------------------------------------------------------
call pgmb.reg('array.scalar_ops', '{perf,planning,oltp}', $q$
select array_length(a_med, 1), array_position(a_med, a_med[10]), a_med[2:5], a_med || a_small,
       array_remove(a_med, a_med[1]), cardinality(a_small), array_to_string(tags, ',')
from g_array where id = :id$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('array.unnest_group', '{perf,planning}', $q$
select t.tag, count(*)
from g_array a, unnest(a.tags) as t(tag)
where a.id between :id and :id + 999
group by t.tag$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('array.sort_distinct', '{perf,planning,oltp}', $q$
select array(select distinct x from unnest(a_med) x order by x) from g_array where id = :id$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('array.agg_build', '{perf,planning,oltp}', $q$
select parent_id, array_agg(id order by id), array_agg(distinct kind)
from g_child where parent_id between :id and :id + 20 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('array.empty_and_null', '{perf,planning}', $q$
select count(*) filter (where a_small = '{}'), count(*) filter (where a_small[1] is null),
       count(*) filter (where cardinality(a_small) = 5)
from g_array where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_array)');

------------------------------------------------------------------------------
-- big arrays (TOASTed)
------------------------------------------------------------------------------
call pgmb.reg('array.big_subscript', '{perf,planning,oltp}', $q$
select a[1], a[1000], a[array_upper(a, 1)] from g_array_big where id = :id$q$,
    setup => '\set id random(1, :n_g_array_big)');

call pgmb.reg('array.big_unnest_sum', '{perf,planning}', $q$
select sum(x), count(distinct x) from g_array_big, unnest(a) as x where id = :id$q$,
    setup => '\set id random(1, :n_g_array_big)');

call pgmb.reg('array.big_contains_seqscan', '{perf,planning,olap}', $q$
select count(*) from g_array_big where a @> array[:v]$q$,
    setup => '\set v random(0, 99999)');

call pgmb.reg('array.big_build_10k', '{perf,planning}', $q$
select cardinality(array_agg(i)), cardinality(array(select generate_series(1, 10000)))
from generate_series(1, 10000) i$q$);

------------------------------------------------------------------------------
-- writes
------------------------------------------------------------------------------
call pgmb.reg('array.update_append', '{perf,planning,oltp}', $q$
update g_array set a_small = (:v || a_small)[1:5] where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_array)\n\\set v random(0, 999)');

call pgmb.reg('array.update_element', '{perf,planning,oltp}', $q$
update g_array set a_med[:k] = :v where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_array)\n\\set k random(1, 50)\n\\set v random(0, 9999)');

------------------------------------------------------------------------------
-- errors
------------------------------------------------------------------------------
call pgmb.reg('array.err_dimension_mismatch', '{errors}',
    $q$select array[[1, 2], [3]]$q$, expect_error => '2202E');
call pgmb.reg('array.err_malformed_literal', '{errors}',
    $q$select '{1,2'::int[]$q$, expect_error => '22P02');
call pgmb.reg('array.err_element_type', '{errors}',
    $q$select array[1, 2] @> array['x'::text]$q$, expect_error => '42883');

------------------------------------------------------------------------------
-- large array_agg results passed to functions
------------------------------------------------------------------------------
call pgmb.reg_ddl('array.create_arr_count', 'schema', $q$
create function arr_count(a bigint[]) returns int language plpgsql immutable as
'begin return cardinality(a); end'$q$);
call pgmb.reg_ddl('array.create_arr_sum_foreach', 'schema', $q$
create function arr_sum_foreach(a bigint[]) returns bigint language plpgsql immutable as
'declare s bigint := 0; x bigint; begin foreach x in array a loop s := s + x; end loop; return s; end'$q$);
call pgmb.reg_ddl('array.create_arr_sum_subscript', 'schema', $q$
create function arr_sum_subscript(a bigint[]) returns bigint language plpgsql immutable as
'declare s bigint := 0; begin for i in 1 .. coalesce(array_length(a, 1), 0) loop s := s + a[i]; end loop; return s; end'$q$);
call pgmb.reg_ddl('array.create_arr_sum_sql', 'schema', $q$
create function arr_sum_sql(a bigint[]) returns bigint language sql immutable as
'select coalesce(sum(x), 0)::bigint from unnest(a) as x'$q$);
call pgmb.reg_ddl('array.create_arr_append_loop', 'schema', $q$
create function arr_append_loop(a bigint[]) returns int language plpgsql immutable as
'declare r bigint[] := ''{}''; x bigint; begin foreach x in array a loop r := r || x; end loop; return cardinality(r); end'$q$);

-- the array is built and only handed over: cost of aggregation plus argument passing
call pgmb.reg('array.agg_50k_passed_only', '{perf,planning}', $q$
select arr_count(array_agg(id)) from g_narrow where id <= 50000$q$);

-- the function walks the array: FOREACH, subscripting, unnest in SQL
call pgmb.reg('array.agg_50k_plpgsql_foreach', '{perf,planning,consistency}', $q$
select arr_sum_foreach(array_agg(id)) from g_narrow where id <= 50000$q$, equiv => 'array.agg_sum');

call pgmb.reg('array.agg_50k_plpgsql_subscript', '{perf,planning,consistency}', $q$
select arr_sum_subscript(array_agg(id)) from g_narrow where id <= 50000$q$, equiv => 'array.agg_sum');

call pgmb.reg('array.agg_50k_sql_unnest', '{perf,planning,consistency}', $q$
select arr_sum_sql(array_agg(id)) from g_narrow where id <= 50000$q$, equiv => 'array.agg_sum');

call pgmb.reg('array.agg_50k_no_array', '{perf,planning,consistency}', $q$
select sum(id)::bigint from g_narrow where id <= 50000$q$, equiv => 'array.agg_sum');

-- the function rebuilds the array element by element
call pgmb.reg('array.agg_5k_plpgsql_append_loop', '{perf,planning}', $q$
select arr_append_loop(array_agg(id)) from g_narrow where id <= 5000$q$);

-- built-in functions over a large aggregated array
call pgmb.reg('array.agg_50k_builtin_chain', '{perf,planning}', $q$
select cardinality(a), array_position(a, a[cardinality(a)]), cardinality(array_remove(a, a[1])),
       cardinality(a || a), length(array_to_string(a, ','))
from (select array_agg(id) as a from g_narrow where id <= 50000) s$q$);

call pgmb.reg('array.agg_50k_sort_reverse', '{perf,planning}', $q$
select (array_sort(a))[1], (array_reverse(a))[1], cardinality(array_sort(a))
from (select array_agg(k_10k) as a from g_narrow where id <= 50000) s$q$);

call pgmb.reg('array.agg_50k_text_joined', '{perf,planning}', $q$
select length(array_to_string(array_agg(pad), ',')), cardinality(string_to_array(string_agg(pad, ','), ','))
from g_narrow where id <= 50000$q$);

-- aggregated array used as a search key
call pgmb.reg('array.agg_keys_to_any', '{perf,planning}', $q$
select count(*), sum(amount) from g_child
where parent_id = any ((select array_agg(id) from g_parent where grp = :g)::bigint[])$q$,
    setup => '\set g random(0, 99)');

call pgmb.reg('array.agg_keys_to_unnest_join', '{perf,planning}', $q$
select count(*), sum(c.amount)
from unnest((select array_agg(id) from g_parent where grp = :g)) as k(id)
join g_child c on c.parent_id = k.id$q$,
    setup => '\set g random(0, 99)');

-- one array per group, each passed to a function
call pgmb.reg('array.agg_per_group_to_function', '{perf,planning}', $q$
select parent_id, arr_sum_foreach(array_agg(id)), arr_count(array_agg(id))
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('array.agg_per_group_big', '{perf,planning,olap}', $q$
select count(*), max(arr_count(a)), sum(arr_sum_sql(a))
from (select k_100, array_agg(id) as a from g_narrow group by k_100) s$q$);

-- array of arrays and array of rows
call pgmb.reg('array.agg_2d_from_arrays', '{perf,planning}', $q$
select array_ndims(a), array_length(a, 1), array_length(a, 2)
from (select array_agg(a_med) as a from g_array where id between :id and :id + 500) s$q$,
    setup => '\set id random(1, :n_g_array)');

call pgmb.reg('array.agg_rows_to_unnest', '{perf,planning}', $q$
select count(*), sum((r).val)
from unnest((select array_agg(p) from g_parent p where p.grp = :g)) as r$q$,
    setup => '\set g random(0, 99)');
