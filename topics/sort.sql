-- Topic: sorting.
--   sort.query_* : ORDER BY of the main query
--   sort.agg_*   : ordering inside aggregate functions (ORDER BY in the call, WITHIN GROUP)

------------------------------------------------------------------------------
-- main query: is a sort needed at all
------------------------------------------------------------------------------
call pgmb.reg('sort.query_order_from_index', '{perf,planning,oltp}', $q$
select id, k_100 from g_narrow where id >= :id order by id limit 100$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_top_n_heapsort', '{perf,planning}', $q$
select id, k_10k from g_narrow where id between :id and :id + 20000 order by k_10k + 0, id limit 10$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_full_sort_5k', '{perf,planning}', $q$
select id, pad from g_narrow where id between :id and :id + 5000 order by pad$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_incremental', '{perf,planning}', $q$
select k_100, k_10k, k_skew from g_narrow where k_100 between :k and :k + 1 order by k_100, k_10k, k_skew$q$,
    setup => '\set k random(0, 98)');

call pgmb.reg('sort.query_deep_offset', '{perf,planning}', $q$
select id, k_10k from g_narrow where id between :id and :id + 20000 order by k_10k + 0, id limit 10 offset 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- main query: sort keys
------------------------------------------------------------------------------
-- the same rows ordered by integer, numeric, float, text and timestamp keys
call pgmb.reg('sort.query_key_integer', '{perf,planning}', $q$
select id from g_child where id between :id and :id + 10000 order by seq, id$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('sort.query_key_numeric', '{perf,planning}', $q$
select id from g_child where id between :id and :id + 10000 order by amount, id$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('sort.query_key_text', '{perf,planning}', $q$
select id from g_child where id between :id and :id + 10000 order by note, id$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('sort.query_key_text_collate_c', '{perf,planning}', $q$
select id from g_child where id between :id and :id + 10000 order by note collate "C", id$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('sort.query_key_float', '{perf,planning}', $q$
select id from g_events where id between :id and :id + 10000 order by val, id$q$,
    setup => '\set id random(1, :n_g_events)');

call pgmb.reg('sort.query_key_expression', '{perf,planning}', $q$
select id from g_narrow where id between :id and :id + 10000 order by k_10k % 100, abs(k_100 - 50), id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_key_long_common_prefix', '{perf,planning}', $q$
select id from g_narrow where id between :id and :id + 10000 order by repeat('x', 100) || pad$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_mixed_directions', '{perf,planning}', $q$
select id, k_100, k_10k from g_narrow where id between :id and :id + 10000
order by k_100 asc, k_10k desc, id asc$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_five_keys', '{perf,planning}', $q$
select id from g_wide where id between :id and :id + 5000 order by i1, i2, i3, i4, i5$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('sort.query_nulls_placement', '{perf,planning}', $q$
select id, k_null from g_narrow where id between :id and :id + 10000 order by k_null desc nulls first, id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_by_alias_and_position', '{perf,planning}', $q$
select k_100 % 10 as bucket, count(*) as n, sum(k_10k) as total
from g_narrow where id between :id and :id + 10000
group by bucket order by n desc, 3, bucket$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_by_subquery_value', '{perf,planning}', $q$
select p.id from g_parent p where p.id between :id and :id + 200
order by (select count(*) from g_child c where c.parent_id = p.id) desc, p.id$q$,
    setup => '\set id random(1, :n_g_parent)');

------------------------------------------------------------------------------
-- main query: input shape
------------------------------------------------------------------------------
call pgmb.reg('sort.query_input_already_sorted', '{perf,planning}', $q$
select id from g_narrow where id between :id and :id + 10000 order by k_corr, id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_input_reversed', '{perf,planning}', $q$
select id from g_narrow where id between :id and :id + 10000 order by k_uniq + 0$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_input_few_distinct', '{perf,planning}', $q$
select id from g_narrow where id between :id and :id + 10000 order by k_100$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_input_skewed', '{perf,planning}', $q$
select id from g_narrow where id between :id and :id + 10000 order by k_skew$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.query_wide_rows', '{perf,planning}', $q$
select * from g_wide where id between :id and :id + 2000 order by t2$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('sort.query_after_join', '{perf,planning}', $q$
select p.grp, c.amount, c.id
from g_child c join g_parent p on p.id = c.parent_id
where c.id between :id and :id + 5000
order by p.grp, c.amount desc, c.id$q$,
    setup => '\set id random(1, :n_g_child)');

call pgmb.reg('sort.query_union_all_merge', '{perf,planning}', $q$
(select id, k_100 from g_narrow where id between :id and :id + 2000 order by id)
union all
(select id, cat from g_events where id between :id and :id + 2000 order by id)
order by id limit 100$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- whole table: larger than work_mem at bigger scales, so the sort spills to disk
call pgmb.reg('sort.query_whole_table_text', '{perf,planning,olap}', $q$
select max(rn) from (select row_number() over (order by pad) as rn from g_narrow) s$q$);

call pgmb.reg('sort.query_whole_table_two_keys', '{perf,planning,olap}', $q$
select max(rn) from (select row_number() over (order by k_100, k_10k + 0, id) as rn from g_narrow) s$q$);

-- ORDER BY against an equivalent that needs no sort; results must agree
call pgmb.reg('sort.query_top20_by_sort', '{perf,planning,consistency}', $q$
select id, k_10k from g_narrow where k_100 = :k order by k_10k + 0, id limit 20$q$,
    setup => '\set k random(0, 99)', equiv => 'sort.top20');

call pgmb.reg('sort.query_top20_by_index', '{perf,planning,consistency,oltp}', $q$
select id, k_10k from (select id, k_10k from g_narrow where k_100 = :k order by k_10k limit 200) s
order by k_10k, id limit 20$q$,
    setup => '\set k random(0, 99)', equiv => 'sort.top20');

------------------------------------------------------------------------------
-- aggregates: ORDER BY inside the call
------------------------------------------------------------------------------
call pgmb.reg('sort.agg_array_agg_ordered', '{perf,planning}', $q$
select parent_id, array_agg(id order by amount desc, id)
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.agg_string_agg_ordered', '{perf,planning}', $q$
select parent_id, string_agg(note, ',' order by note)
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.agg_json_ordered', '{perf,planning}', $q$
select parent_id, jsonb_agg(jsonb_build_object('id', id, 'a', amount) order by amount, id),
       jsonb_object_agg(id, kind order by id)
from g_child where parent_id between :id and :id + 100 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

-- input already arrives in the requested order from the (parent_id, seq) index
call pgmb.reg('sort.agg_presorted_by_index', '{perf,planning}', $q$
select parent_id, array_agg(seq order by seq)
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

-- several aggregates: one shared ordering vs. three different ones
call pgmb.reg('sort.agg_three_same_order', '{perf,planning}', $q$
select parent_id, array_agg(id order by amount), array_agg(kind order by amount), string_agg(note, '' order by amount)
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.agg_three_different_orders', '{perf,planning}', $q$
select parent_id, array_agg(id order by amount), array_agg(kind order by seq), string_agg(note, '' order by note)
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.agg_distinct_ordered', '{perf,planning}', $q$
select parent_id, array_agg(distinct kind order by kind desc), count(distinct seq)
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.agg_ordered_with_filter', '{perf,planning}', $q$
select parent_id,
       array_agg(id order by amount desc) filter (where kind < 4) as low,
       array_agg(id order by amount desc) filter (where kind >= 4) as high
from g_child where parent_id between :id and :id + 200 group by parent_id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.agg_first_last_by_order', '{perf,planning}', $q$
select entity_id,
       (array_agg(val order by ts))[1] as first_val,
       (array_agg(val order by ts desc))[1] as last_val
from g_events where entity_id between :e and :e + 19 group by entity_id$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('sort.agg_one_big_group', '{perf,planning}', $q$
select cardinality(array_agg(id order by pad)), left(string_agg(pad, '' order by k_10k, id), 40)
from g_narrow where id between :id and :id + 20000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.agg_ordered_as_window', '{perf,planning}', $q$
select id, array_agg(id) over (partition by parent_id order by amount, id) as so_far
from g_child where parent_id between :id and :id + 20$q$,
    setup => '\set id random(1, :n_g_parent)');

-- ordered aggregate three ways; results must agree
call pgmb.reg('sort.agg_order_in_call', '{perf,planning,consistency,oltp}', $q$
select coalesce(array_agg(id order by amount, id), '{}') from g_child where parent_id = :id$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'sort.agg_order');

call pgmb.reg('sort.agg_order_in_subquery', '{perf,planning,consistency,oltp}', $q$
select coalesce(array_agg(id), '{}')
from (select id from g_child where parent_id = :id order by amount, id) s$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'sort.agg_order');

call pgmb.reg('sort.agg_order_in_array_constructor', '{perf,planning,consistency,oltp}', $q$
select array(select id from g_child where parent_id = :id order by amount, id)$q$,
    setup => '\set id random(1, :n_g_parent)', equiv => 'sort.agg_order');

------------------------------------------------------------------------------
-- aggregates: ordered-set and hypothetical-set (WITHIN GROUP)
------------------------------------------------------------------------------
call pgmb.reg('sort.agg_median', '{perf,planning}', $q$
select entity_id, percentile_cont(0.5) within group (order by val), percentile_disc(0.5) within group (order by val)
from g_events where entity_id between :e and :e + 19 group by entity_id$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('sort.agg_percentile_array', '{perf,planning}', $q$
select percentile_cont(array[0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99]) within group (order by val)
from g_events where id between :id and :id + 20000$q$,
    setup => '\set id random(1, :n_g_events)');

call pgmb.reg('sort.agg_mode', '{perf,planning}', $q$
select mode() within group (order by k_skew), mode() within group (order by k_100)
from g_narrow where id between :id and :id + 20000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('sort.agg_hypothetical_rank', '{perf,planning}', $q$
select rank(:v) within group (order by amount), dense_rank(:v) within group (order by amount),
       percent_rank(:v) within group (order by amount), cume_dist(:v) within group (order by amount)
from g_child where id between :id and :id + 20000$q$,
    setup => E'\\set id random(1, :n_g_child)\n\\set v random(0, 1000)');

call pgmb.reg('sort.agg_median_text_desc', '{perf,planning}', $q$
select percentile_disc(0.5) within group (order by pad desc) from g_narrow where id between :id and :id + 20000$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- median two ways; results must agree
call pgmb.reg('sort.agg_median_ordered_set', '{perf,planning,consistency,needs_data}', $q$
select percentile_disc(0.5) within group (order by k_10k) from g_narrow where id between :id and :id + 9999$q$,
    setup => '\set id random(1, :n_g_narrow / 2)', equiv => 'sort.median');

call pgmb.reg('sort.agg_median_by_offset', '{perf,planning,consistency,needs_data}', $q$
select k_10k from g_narrow where id between :id and :id + 9999 order by k_10k
offset (select (count(*) - 1) / 2 from g_narrow where id between :id and :id + 9999) limit 1$q$,
    setup => '\set id random(1, :n_g_narrow / 2)', equiv => 'sort.median');

call pgmb.reg('sort.agg_median_whole_table', '{perf,planning,olap}', $q$
select percentile_cont(0.5) within group (order by val), percentile_cont(0.99) within group (order by val)
from g_events$q$);

------------------------------------------------------------------------------
-- errors
------------------------------------------------------------------------------
call pgmb.reg('sort.err_percentile_out_of_range', '{errors}',
    $q$select percentile_cont(1.5) within group (order by val) from g_events$q$, expect_error => '22003');
call pgmb.reg('sort.err_ordered_set_without_within_group', '{errors}',
    $q$select mode() from g_events$q$, expect_error => '42883');
call pgmb.reg('sort.err_order_by_position_out_of_range', '{errors}',
    $q$select id from g_parent order by 2$q$, expect_error => '42P10');
call pgmb.reg('sort.err_union_order_by_expression', '{errors}',
    $q$select id from g_parent union select id from g_tree order by id + 1$q$, expect_error => '0A000');

------------------------------------------------------------------------------
-- Incremental Sort: the input is already ordered by a prefix of the sort key.
-- Prefixes come from g_child (parent_id, seq), g_events (entity_id, ts),
-- g_narrow (k_100, k_10k).
------------------------------------------------------------------------------
-- group size decides how much each batch has to sort
call pgmb.reg('sort.incremental_tiny_groups', '{perf,planning}', $q$
select parent_id, seq, amount from g_child where parent_id between :id and :id + 500
order by parent_id, seq, amount$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.incremental_small_groups', '{perf,planning}', $q$
select parent_id, amount, id from g_child where parent_id between :id and :id + 500
order by parent_id, amount, id$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.incremental_medium_groups', '{perf,planning}', $q$
select entity_id, val, id from g_events where entity_id between :e and :e + 49
order by entity_id, val, id$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('sort.incremental_huge_groups', '{perf,planning}', $q$
select k_100, k_skew, id from g_narrow where k_100 between :k and :k + 1 order by k_100, k_skew, id$q$,
    setup => '\set k random(0, 98)');

-- LIMIT: only the first groups are ever sorted
call pgmb.reg('sort.incremental_with_limit', '{perf,planning,oltp}', $q$
select entity_id, val, id from g_events where entity_id >= :e order by entity_id, val, id limit 20$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('sort.incremental_backward_prefix', '{perf,planning,oltp}', $q$
select entity_id, val, id from g_events where entity_id <= :e order by entity_id desc, val desc, id limit 20$q$,
    setup => '\set e random(1, :n_g_events_entities)');

-- two presorted columns, third one sorted
call pgmb.reg('sort.incremental_two_column_prefix', '{perf,planning}', $q$
select k_100, k_10k, pad from g_narrow where k_100 = :k order by k_100, k_10k, pad limit 500$q$,
    setup => '\set k random(0, 99)');

-- consumers other than ORDER BY
call pgmb.reg('sort.incremental_for_window', '{perf,planning}', $q$
select id, rank() over (partition by entity_id order by val desc)
from g_events where entity_id between :e and :e + 49$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('sort.incremental_for_group_aggregate', '{perf,planning}', $q$
select parent_id, kind, count(*), sum(amount)
from g_child where parent_id between :id and :id + 500
group by parent_id, kind order by parent_id, kind$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('sort.incremental_for_distinct', '{perf,planning}', $q$
select distinct entity_id, cat from g_events where entity_id between :e and :e + 49 order by entity_id, cat$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('sort.incremental_after_join', '{perf,planning}', $q$
select p.id, c.amount, c.id as child_id
from g_parent p join g_child c on c.parent_id = p.id
where p.id between :id and :id + 300
order by p.id, c.amount, c.id$q$,
    setup => '\set id random(1, :n_g_parent)');

-- the same ordering with the presorted prefix hidden from the planner; rows must agree
call pgmb.reg('sort.incremental_prefix_visible', '{perf,planning,consistency}', $q$
select entity_id, val, id from g_events where entity_id between :e and :e + 49 order by entity_id, val, id$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'sort.incremental');

call pgmb.reg('sort.incremental_prefix_hidden', '{perf,planning,consistency}', $q$
select entity_id, val, id from g_events where entity_id between :e and :e + 49 order by entity_id + 0, val, id$q$,
    setup => '\set e random(1, :n_g_events_entities)', equiv => 'sort.incremental');

-- the same statement with Incremental Sort allowed and forbidden
call pgmb.reg('sort.incremental_setting_on', '{perf}', $q$
begin;
set local enable_incremental_sort = on;
select entity_id, val, id from g_events where entity_id between :e and :e + 199 order by entity_id, val, id;
commit;$q$,
    setup => '\set e random(1, :n_g_events_entities)');

call pgmb.reg('sort.incremental_setting_off', '{perf}', $q$
begin;
set local enable_incremental_sort = off;
select entity_id, val, id from g_events where entity_id between :e and :e + 199 order by entity_id, val, id;
commit;$q$,
    setup => '\set e random(1, :n_g_events_entities)');
