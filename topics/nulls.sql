-- Topic: NULL handling. COALESCE, NULLIF, IS [NOT] DISTINCT FROM, IS NULL,
-- NULLs in aggregates, ordering, joins, arrays and function calls.
-- g_narrow.k_null is NULL in half of the rows and holds 0..999 otherwise.

------------------------------------------------------------------------------
-- COALESCE
------------------------------------------------------------------------------
-- wrapping the column hides it from the index; the plain comparison does not
call pgmb.reg('nulls.coalesce_in_filter', '{perf,planning,consistency}', $q$
select count(*), min(id) from g_narrow where coalesce(k_null, -1) = :v$q$,
    setup => '\set v random(0, 999)', equiv => 'nulls.equal_value');

call pgmb.reg('nulls.plain_equality', '{perf,planning,consistency}', $q$
select count(*), min(id) from g_narrow where k_null = :v$q$,
    setup => '\set v random(0, 999)', equiv => 'nulls.equal_value');

call pgmb.reg('nulls.not_distinct_from_value', '{perf,planning,consistency}', $q$
select count(*), min(id) from g_narrow where k_null is not distinct from :v$q$,
    setup => '\set v random(0, 999)', equiv => 'nulls.equal_value');

call pgmb.reg('nulls.coalesce_projection', '{perf,planning}', $q$
select id, coalesce(k_null, k_skew, k_100, 0), coalesce(k_null::text, 'none')
from g_narrow where id between :id and :id + 2000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.coalesce_10_arguments', '{perf,planning}', $q$
select sum(coalesce(nullif(k_null, k_null), nullif(k_100, k_100), nullif(k_10k, k_10k), nullif(k_skew, k_skew),
                    null, null, null, null, k_null, k_100))
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.coalesce_in_aggregate', '{perf,planning}', $q$
select sum(coalesce(k_null, 0)), avg(coalesce(k_null, 0)), avg(k_null), count(coalesce(k_null, 0)), count(k_null)
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.coalesce_after_outer_join', '{perf,planning}', $q$
select p.id, coalesce(c.n, 0) as n, coalesce(c.total, 0) as total
from g_parent p
left join (select parent_id, count(*) as n, sum(amount) as total from g_child where kind = 0 group by parent_id) c
       on c.parent_id = p.id
where p.id between :id and :id + 200$q$,
    setup => '\set id random(1, :n_g_parent)');

call pgmb.reg('nulls.coalesce_subquery_fallback', '{perf,planning,oltp}', $q$
select coalesce((select max(amount) from g_child where parent_id = :id and kind = 0),
                (select max(amount) from g_child where parent_id = :id),
                0)$q$,
    setup => '\set id random(1, :n_g_parent)');

-- COALESCE, CASE and a UNION written to give the same answer
call pgmb.reg('nulls.default_by_coalesce', '{perf,planning,consistency}', $q$
select id, coalesce(k_null, -1) as v from g_narrow where id between :id and :id + 1000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'nulls.default');

call pgmb.reg('nulls.default_by_case', '{perf,planning,consistency}', $q$
select id, case when k_null is null then -1 else k_null end as v from g_narrow where id between :id and :id + 1000$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'nulls.default');

call pgmb.reg('nulls.default_by_union', '{perf,planning,consistency}', $q$
select id, k_null as v from g_narrow where id between :id and :id + 1000 and k_null is not null
union all
select id, -1 from g_narrow where id between :id and :id + 1000 and k_null is null$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'nulls.default');

------------------------------------------------------------------------------
-- NULLIF
------------------------------------------------------------------------------
call pgmb.reg('nulls.nullif_division_guard', '{perf,planning}', $q$
select sum(k_10k::numeric / nullif(k_100, 0)), count(*) filter (where nullif(k_100, 0) is null)
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.nullif_in_filter', '{perf,planning}', $q$
select count(*) from g_narrow where id between :id and :id + 5000 and nullif(k_skew, 0) is null$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.nullif_text_empty', '{perf,planning}', $q$
select count(nullif(left(pad, 1), 'a')), count(nullif(trim(repeat(' ', k_100 % 3)), ''))
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.nullif_coalesce_round_trip', '{perf,planning}', $q$
select count(*) filter (where coalesce(nullif(coalesce(k_null, -1), -1), -2) = -2)
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- IS [NOT] DISTINCT FROM
------------------------------------------------------------------------------
call pgmb.reg('nulls.distinct_from_value', '{perf,planning,consistency}', $q$
select count(*) from g_narrow where id between :id and :id + 5000 and k_null is distinct from :v$q$,
    setup => E'\\set id random(1, :n_g_narrow)\n\\set v random(0, 999)', equiv => 'nulls.differs');

call pgmb.reg('nulls.distinct_from_spelled_out', '{perf,planning,consistency}', $q$
select count(*) from g_narrow where id between :id and :id + 5000 and (k_null <> :v or k_null is null)$q$,
    setup => E'\\set id random(1, :n_g_narrow)\n\\set v random(0, 999)', equiv => 'nulls.differs');

call pgmb.reg('nulls.distinct_from_coalesce', '{perf,planning,consistency}', $q$
select count(*) from g_narrow where id between :id and :id + 5000 and coalesce(k_null, -1) <> :v$q$,
    setup => E'\\set id random(1, :n_g_narrow)\n\\set v random(0, 999)', equiv => 'nulls.differs');

call pgmb.reg('nulls.distinct_from_null_literal', '{perf,planning}', $q$
select count(*) filter (where k_null is distinct from null), count(*) filter (where k_null is not distinct from null)
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.distinct_from_two_columns', '{perf,planning}', $q$
select count(*) from g_narrow where id between :id and :id + 5000 and k_null is distinct from k_skew$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- NULL-safe join three ways
call pgmb.reg('nulls.join_not_distinct_from', '{perf,planning,consistency}', $q$
select count(*)
from (select id, k_null from g_narrow where id between :id and :id + 300) a
join (select id, k_null from g_narrow where id between :id + 301 and :id + 600) b
  on a.k_null is not distinct from b.k_null$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'nulls.join');

call pgmb.reg('nulls.join_coalesce_both_sides', '{perf,planning,consistency}', $q$
select count(*)
from (select id, k_null from g_narrow where id between :id and :id + 300) a
join (select id, k_null from g_narrow where id between :id + 301 and :id + 600) b
  on coalesce(a.k_null, -1) = coalesce(b.k_null, -1)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'nulls.join');

call pgmb.reg('nulls.join_equal_or_both_null', '{perf,planning,consistency}', $q$
select count(*)
from (select id, k_null from g_narrow where id between :id and :id + 300) a
join (select id, k_null from g_narrow where id between :id + 301 and :id + 600) b
  on a.k_null = b.k_null or (a.k_null is null and b.k_null is null)$q$,
    setup => '\set id random(1, :n_g_narrow)', equiv => 'nulls.join');

call pgmb.reg('nulls.row_changed_detection', '{perf,planning}', $q$
select count(*)
from g_narrow a join g_narrow b on b.id = a.id + 1
where a.id between :id and :id + 2000
  and (a.k_100, a.k_skew, a.k_null) is distinct from (b.k_100, b.k_skew, b.k_null)$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- IS NULL, ordering, three-valued logic
------------------------------------------------------------------------------
call pgmb.reg('nulls.is_null_by_index', '{perf,planning,oltp}', $q$
select id from g_narrow where k_null is null and id > :id order by id limit 20$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.is_null_counts', '{perf,planning}', $q$
select count(*), count(k_null), count(*) - count(k_null), count(*) filter (where k_null is null),
       sum((k_null is null)::int), num_nulls(k_null, k_skew), num_nonnulls(k_null, k_skew)
from g_narrow where id between :id and :id + 5000
group by num_nulls(k_null, k_skew), num_nonnulls(k_null, k_skew)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.order_nulls_first', '{perf,planning}', $q$
select id, k_null from g_narrow where id between :id and :id + 5000 order by k_null nulls first, id limit 50$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.order_nulls_last_desc', '{perf,planning}', $q$
select id, k_null from g_narrow where id between :id and :id + 5000 order by k_null desc nulls last, id limit 50$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.row_is_null', '{perf,planning}', $q$
select count(*) filter (where (k_null, nullif(k_skew, 0)) is null) as all_null,
       count(*) filter (where (k_null, nullif(k_skew, 0)) is not null) as none_null,
       count(*) filter (where not ((k_null, nullif(k_skew, 0)) is null)) as not_all_null
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.three_valued_logic', '{perf,planning}', $q$
select count(*) filter (where k_null > 500 or k_100 < 50) as or_true,
       count(*) filter (where not (k_null > 500)) as not_gt,
       count(*) filter (where (k_null > 500) is unknown) as unknown,
       count(*) filter (where (k_null > 500 and k_100 < 50) is not true) as not_true
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

-- NOT IN over a set that contains NULL can never be true; NOT EXISTS ignores the NULLs
call pgmb.reg('nulls.not_in_set_with_nulls', '{perf,planning}', $q$
select count(*) from g_narrow
where id between :id and :id + 2000
  and k_100 not in (select k_null from g_narrow where id between :id + 2001 and :id + 2200)$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.not_exists_set_with_nulls', '{perf,planning}', $q$
select count(*) from g_narrow a
where a.id between :id and :id + 2000
  and not exists (select 1 from g_narrow b where b.id between :id + 2001 and :id + 2200 and b.k_null = a.k_100)$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- NULLs in aggregates, arrays, strings and functions
------------------------------------------------------------------------------
call pgmb.reg('nulls.aggregates_skip_nulls', '{perf,planning}', $q$
select k_100, sum(k_null), avg(k_null), min(k_null), max(k_null), bool_or(k_null > 990), count(distinct k_null)
from g_narrow where id between :id and :id + 5000 group by k_100$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.group_by_nullable', '{perf,planning}', $q$
select k_null, count(*) from g_narrow where id between :id and :id + 5000 group by k_null$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.array_with_nulls', '{perf,planning}', $q$
select cardinality(a), cardinality(array_remove(a, null)), array_position(a, null),
       (select count(*) from unnest(a) x where x is null)
from (select array_agg(k_null) as a from g_narrow where id between :id and :id + 5000) s$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.string_concat', '{perf,planning}', $q$
select count(k_null::text || pad), count(concat(k_null, pad)), count(concat_ws('-', k_null, k_skew, pad)),
       count(format('%s/%s', k_null, k_skew))
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.greatest_least', '{perf,planning}', $q$
select sum(greatest(k_null, k_skew, 0)), sum(least(k_null, k_skew)), count(greatest(k_null, null))
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.strict_function_skipped', '{perf,planning}', $q$
select count(noop_plpgsql_strict(k_null)), count(noop_plpgsql(k_null))
from g_narrow where id between :id and :id + 5000$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('nulls.window_ignore_nulls_emulation', '{perf,planning}', $q$
select id, k_null,
       (array_remove(array_agg(k_null) over (order by id rows between 10 preceding and current row), null))[1] as recent
from g_narrow where id between :id and :id + 2000$q$,
    setup => '\set id random(1, :n_g_narrow)');

------------------------------------------------------------------------------
-- writes
------------------------------------------------------------------------------
call pgmb.reg('nulls.update_nullif', '{perf,planning,oltp}', $q$
update g_narrow set k_null = nullif(coalesce(k_null, :v), :v + 1) where id = :id$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_narrow)\n\\set v random(0, 999)');

call pgmb.reg('nulls.update_where_distinct_from', '{perf,planning,oltp}', $q$
update g_narrow set k_null = :v where id between :id and :id + 9 and k_null is distinct from :v$q$,
    kind => 'write', setup => E'\\set id random(1, :n_g_narrow)\n\\set v random(0, 999)');

------------------------------------------------------------------------------
-- errors
------------------------------------------------------------------------------
call pgmb.reg('nulls.err_coalesce_type_mismatch', '{errors}',
    $q$select coalesce(k_null, 'none') from g_narrow limit 1$q$, expect_error => '22P02');
call pgmb.reg('nulls.err_nullif_no_operator', '{errors}',
    $q$select nullif(k_null, pad) from g_narrow limit 1$q$, expect_error => '42883');
call pgmb.reg('nulls.err_not_null_violation', '{errors,needs_data}',
    $q$update g_narrow set k_100 = nullif(k_100, k_100) where id = 1$q$, expect_error => '23502');
