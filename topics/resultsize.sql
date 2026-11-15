-- Topic: result size. Same access path, from zero rows to a hundred thousand,
-- narrow and wide rows, one large value.

call pgmb.reg('resultsize.rows_0', '{perf,planning,oltp}', $q$
select * from g_narrow where id = -1$q$);

call pgmb.reg('resultsize.rows_1', '{perf,planning,oltp}', $q$
select * from g_narrow where id = :id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('resultsize.rows_100', '{perf,planning,oltp}', $q$
select * from g_narrow where id between :id and :id + 99$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('resultsize.rows_10k', '{perf,planning}', $q$
select * from g_narrow where id between :id and :id + 9999$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('resultsize.rows_100k', '{perf,planning,olap}', $q$
select * from g_narrow where id <= 100000$q$);

call pgmb.reg('resultsize.one_column_10k', '{perf,planning}', $q$
select id from g_narrow where id between :id and :id + 9999$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('resultsize.wide_rows_1k', '{perf,planning}', $q$
select * from g_wide where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_wide)');

call pgmb.reg('resultsize.one_value_100kb', '{perf,planning,oltp}', $q$
select repeat(pad, 2500) from g_narrow where id = :id$q$,
    setup => '\set id random(1, :n_g_narrow)');

call pgmb.reg('resultsize.one_row_from_many', '{perf,planning,olap}', $q$
select count(*), sum(k_10k), max(pad) from g_narrow$q$);

call pgmb.reg('resultsize.limit_deep_offset', '{perf,planning}', $q$
select id from g_narrow order by id limit 10 offset 50000$q$);

call pgmb.reg('resultsize.generated_100k', '{perf,planning}', $q$
select i, i::text from generate_series(1, 100000) i$q$);

call pgmb.reg('resultsize.write_returning_100', '{perf,planning}', $q$
update g_narrow set k_null = k_null where id between :id and :id + 99 returning *$q$,
    kind => 'write', setup => '\set id random(1, :n_g_narrow)');
