-- Topic: function call overhead. Functions that do nothing, in every flavour,
-- called 10000 times per query and compared against a baseline without a call.

call pgmb.reg_ddl('funcall.create_noop_sql', 'schema', $q$
create function noop_sql(int) returns int language sql immutable return $1$q$);
call pgmb.reg_ddl('funcall.create_noop_sql_volatile', 'schema', $q$
create function noop_sql_volatile(int) returns int language sql volatile as 'select $1'$q$);
call pgmb.reg_ddl('funcall.create_noop_sql_not_inlined', 'schema', $q$
create function noop_sql_not_inlined(int) returns int language sql volatile strict security definer as 'select $1'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql', 'schema', $q$
create function noop_plpgsql(int) returns int language plpgsql as 'begin return $1; end'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql_immutable', 'schema', $q$
create function noop_plpgsql_immutable(int) returns int language plpgsql immutable as 'begin return $1; end'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql_strict', 'schema', $q$
create function noop_plpgsql_strict(int) returns int language plpgsql strict as 'begin return $1; end'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql_secdef', 'schema', $q$
create function noop_plpgsql_secdef(int) returns int language plpgsql security definer as 'begin return $1; end'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql_set', 'schema', $q$
create function noop_plpgsql_set(int) returns int language plpgsql set work_mem = '8MB' as 'begin return $1; end'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql_void', 'schema', $q$
create function noop_plpgsql_void() returns void language plpgsql as 'begin end'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql_nested', 'schema', $q$
create function noop_plpgsql_nested(int) returns int language plpgsql as 'begin return noop_plpgsql($1); end'$q$);
call pgmb.reg_ddl('funcall.create_noop_plpgsql_exception', 'schema', $q$
create function noop_plpgsql_exception(int) returns int language plpgsql as
'begin begin return $1; exception when others then return null; end; end'$q$);
call pgmb.reg_ddl('funcall.create_noop_srf', 'schema', $q$
create function noop_srf(int) returns setof int language plpgsql as 'begin return next $1; end'$q$);
call pgmb.reg_ddl('funcall.create_noop_proc', 'schema', $q$
create procedure noop_proc() language plpgsql as 'begin end'$q$);

call pgmb.reg('funcall.baseline_10k', '{perf,planning}',
    $q$select count(i) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.builtin_10k', '{perf,planning}',
    $q$select count(abs(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.sql_inlined_10k', '{perf,planning}',
    $q$select count(noop_sql(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.sql_volatile_10k', '{perf,planning}',
    $q$select count(noop_sql_volatile(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.sql_not_inlined_10k', '{perf,planning}',
    $q$select count(noop_sql_not_inlined(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_10k', '{perf,planning}',
    $q$select count(noop_plpgsql(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_immutable_const_10k', '{perf,planning}',
    $q$select count(noop_plpgsql_immutable(1)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_strict_10k', '{perf,planning}',
    $q$select count(noop_plpgsql_strict(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_secdef_10k', '{perf,planning}',
    $q$select count(noop_plpgsql_secdef(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_set_clause_10k', '{perf,planning}',
    $q$select count(noop_plpgsql_set(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_void_10k', '{perf,planning}',
    $q$select count(noop_plpgsql_void()::text) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_nested_10k', '{perf,planning}',
    $q$select count(noop_plpgsql_nested(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.plpgsql_exception_block_10k', '{perf,planning}',
    $q$select count(noop_plpgsql_exception(i)) from generate_series(1, 10000) i$q$);
call pgmb.reg('funcall.srf_lateral_10k', '{perf,planning}',
    $q$select count(x) from generate_series(1, 10000) i, noop_srf(i) x$q$);

-- one call per round trip
call pgmb.reg('funcall.single_select', '{perf,planning,oltp}', $q$select 1$q$);
call pgmb.reg('funcall.single_plpgsql', '{perf,planning,oltp}', $q$select noop_plpgsql(1)$q$);
call pgmb.reg('funcall.single_call_procedure', '{perf,oltp}', $q$call noop_proc()$q$);
call pgmb.reg('funcall.single_do_block', '{perf,oltp}', $q$do 'begin end'$q$);

call pgmb.reg('funcall.err_undefined_function', '{errors}',
    $q$select noop_missing(1)$q$, expect_error => '42883');
call pgmb.reg('funcall.err_ambiguous_function', '{errors}',
    $q$select noop_sql(null::unknown) from (select noop_plpgsql('1', '2')) s$q$, expect_error => '42883');
