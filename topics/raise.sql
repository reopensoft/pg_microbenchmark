-- Topic: raise - RAISE NOTICE in PL/pgSQL: what it formats, how often it runs,
-- what it costs.
--
-- Nothing in the benchmark reads the messages a statement sends: pgbench
-- prints them to its error output, which is stored with the run, and the
-- checks have no place to keep them. So no test lets a message reach the
-- client. Every function here runs with client_min_messages = warning, or is
-- called from a transaction that sets it. That leaves three things to test.
--
-- 1. What RAISE builds. The text and the diagnostic fields are put together
--    by the same code for every level, so they are raised as an exception,
--    caught, and compared with the expected value (consistency groups).
-- 2. How often RAISE runs. raise_notice_fn() takes a value from a sequence and
--    then raises one notice; raise_count() runs a statement and returns how
--    many values were taken. Sequences are not rolled back, so the count also
--    covers work that was undone.
-- 3. What a filtered NOTICE costs (perf): the text is built before the server
--    decides that nobody wants it.
--
-- Not covered: RAISE INFO (always sent to the client), whether and in what
-- order messages arrive, the server log, and anything that depends on the
-- client that receives them.

call pgmb.reg_ddl('raise.create_sequence', 'schema', $q$create sequence g_raise_seq$q$);

call pgmb.reg_ddl('raise.create_counting_functions', 'schema', $q$
create function raise_notice_fn(v int) returns int language plpgsql as
$f$begin
    perform nextval('pgmb_data.g_raise_seq');
    raise notice 'pgmb row %', v;
    return v;
end$f$;
create function raise_silent_fn(v int) returns int language plpgsql as
'begin return v; end';
-- number of raise_notice_fn() and trigger calls made by one statement
create function raise_count(p_sql text) returns bigint language plpgsql set client_min_messages = warning as
$f$declare
    v0 bigint;
begin
    v0 := nextval('pgmb_data.g_raise_seq');
    execute p_sql;
    return nextval('pgmb_data.g_raise_seq') - v0 - 1;
end$f$;
create function raise_trigger() returns trigger language plpgsql as
$f$begin
    perform nextval('pgmb_data.g_raise_seq');
    raise notice 'pgmb trigger % % on %', tg_op, tg_level, tg_table_name;
    return null;
end$f$$q$);

-- three copies of ten rows: no trigger, a row trigger, a statement trigger
call pgmb.reg_ddl('raise.create_tables', 'schema', $q$
create table g_raise (id int primary key, v int not null);
insert into g_raise select n, 0 from generate_series(1, 10) n;
create table g_raise_row (id int primary key, v int not null);
insert into g_raise_row select * from g_raise;
create table g_raise_stmt (id int primary key, v int not null);
insert into g_raise_stmt select * from g_raise;
create trigger g_raise_row_trg after insert or update or delete on g_raise_row
    for each row execute function raise_trigger();
create trigger g_raise_stmt_trg after insert or update or delete on g_raise_stmt
    for each statement execute function raise_trigger()$q$);

call pgmb.reg_ddl('raise.create_capture_functions', 'schema', $q$
create function raise_capture_format() returns text language plpgsql as
$f$begin
    raise exception 'a % b %% c % d', 1, 'x';
exception when others then return sqlerrm;
end$f$;
create function raise_capture_format_many() returns text language plpgsql as
$f$begin
    raise exception '%-%-%-%-%-%-%-%-%-% 100%%', 1, 2, 3, 4, 5, 6, 7, 8, 9, 10;
exception when others then return sqlerrm;
end$f$;
create function raise_capture_scalar_types() returns text language plpgsql
    set timezone = 'UTC' set datestyle = 'ISO, YMD' as
$f$begin
    raise exception '% % % % % % % %', null::int, true, 42, 9007199254740993, 1.50::numeric,
        '2026-01-02 03:04:05'::timestamp, '2026-01-02 03:04:05+00'::timestamptz,
        '00000000-0000-0000-0000-000000000001'::uuid;
exception when others then return sqlerrm;
end$f$;
create function raise_capture_composite_types() returns text language plpgsql set bytea_output = 'hex' as
$f$begin
    raise exception '% % % % % %', array[1, 2, 3], '{"a": 1}'::jsonb, row(1, 'x'), int4range(1, 5),
        int4multirange(int4range(1, 5)), '\xdeadbeef'::bytea;
exception when others then return sqlerrm;
end$f$;
create function raise_capture_length(n int) returns int language plpgsql as
$f$begin
    raise exception '%', repeat('x', n);
exception when others then return length(sqlerrm);
end$f$;
create function raise_capture_using_message() returns text language plpgsql as
$f$begin
    raise exception using message = 'row ' || 5 || ' of ' || 10;
exception when others then return sqlerrm;
end$f$;
create function raise_capture_fields() returns text language plpgsql as
$f$declare
    v_state text; v_msg text; v_detail text; v_hint text;
    v_column text; v_constraint text; v_type text; v_table text; v_schema text;
begin
    raise exception using message = 'm', detail = 'd', hint = 'h', errcode = 'P0042',
        column = 'c', constraint = 'k', datatype = 't', table = 'tb', schema = 's';
exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail,
        v_hint = pg_exception_hint, v_column = column_name, v_constraint = constraint_name,
        v_type = pg_datatype_name, v_table = table_name, v_schema = schema_name;
    return concat_ws('|', v_state, v_msg, v_detail, v_hint, v_column, v_constraint, v_type, v_table, v_schema);
end$f$;
-- fields left out are empty, not NULL; identifiers are passed on as written
create function raise_capture_fields_empty_and_odd() returns text language plpgsql as
$f$declare
    v_state text; v_detail text; v_column text; v_table text;
begin
    raise exception 'm' using column = '', table = 'Odd "Name"';
exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail,
        v_column = column_name, v_table = table_name;
    return v_state || '|' || v_detail || '|' || v_column || '|' || v_table;
end$f$;
-- call stack of a message raised three functions deep
create function raise_ctx_l3() returns void language plpgsql as
$f$begin
    raise exception 'pgmb ctx';
end$f$;
create function raise_ctx_l2() returns void language plpgsql as
'begin perform pgmb_data.raise_ctx_l3(); end';
create function raise_ctx_l1() returns text language plpgsql as
$f$declare
    ctx text;
begin
    perform pgmb_data.raise_ctx_l2();
    return null;
exception when others then
    get stacked diagnostics ctx = pg_exception_context;
    return format('%s levels, innermost first: %s, raised at line %s',
                  regexp_count(ctx, 'PL/pgSQL function'),
                  position('raise_ctx_l3' in ctx) < position('raise_ctx_l2' in ctx)
                      and position('raise_ctx_l2' in ctx) < position('raise_ctx_l1' in ctx),
                  substring(ctx from 'raise_ctx_l3\(\) line (\d+) at RAISE'));
end$f$;
-- every form once at NOTICE level: all of them must run without an error
create function raise_notice_all_forms() returns text language plpgsql set client_min_messages = warning as
$f$begin
    raise notice 'plain';
    raise notice 'a % b %% c %', 1, 'x';
    raise notice '% % %', null::int, array[1, 2, 3], row(1, 'x');
    raise notice '';
    raise notice '%', repeat('x', 100000);
    raise notice using message = 'row ' || 5;
    raise notice 'm' using detail = 'd', hint = 'h';
    raise notice 'm' using errcode = 'P0042';
    raise notice 'm' using errcode = 'unique_violation';
    raise notice 'm' using column = 'c', constraint = 'k', datatype = 't', table = 'tb', schema = 's';
    raise notice 'same';
    raise notice 'same';
    return 'done';
end$f$$q$);

call pgmb.reg_ddl('raise.create_flow_functions', 'schema', $q$
create function raise_flow_if_case(n int) returns void language plpgsql as
$f$begin
    for i in 1 .. n loop
        if i % 3 = 0 then
            perform pgmb_data.raise_notice_fn(i);
        end if;
        case when i % 5 = 0 then perform pgmb_data.raise_notice_fn(i);
             else null;
        end case;
    end loop;
end$f$;
-- rows 100, 99, ... of a query; stops after p_exit, skips even rows on request
create function raise_flow_for_select(p_limit int, p_exit int, p_skip_even boolean) returns void language plpgsql as
$f$declare
    r record;
begin
    for r in select n::int as n from generate_series(1, 100) n order by n desc limit p_limit loop
        continue when p_skip_even and r.n % 2 = 0;
        perform pgmb_data.raise_notice_fn(r.n);
        exit when r.n = p_exit;
    end loop;
end$f$;
create function raise_flow_nested(depth int) returns void language plpgsql as
$f$begin
    perform pgmb_data.raise_notice_fn(depth);
    if depth > 1 then
        perform pgmb_data.raise_flow_nested(depth - 1);
    end if;
end$f$;
create function raise_flow_return_early(n int) returns int language plpgsql as
$f$begin
    for i in 1 .. n loop
        perform pgmb_data.raise_notice_fn(i);
        if i = 7 then return i; end if;
    end loop;
    return n;
end$f$;
-- two notices and an insert, then an error; one more notice in the handler.
-- Returns how many of the inserted rows are still there.
create function raise_flow_exception_block() returns bigint language plpgsql as
$f$begin
    begin
        perform pgmb_data.raise_notice_fn(1);
        insert into pgmb_data.g_raise values (-1, 0);
        perform pgmb_data.raise_notice_fn(2);
        perform 1 / 0;
        perform pgmb_data.raise_notice_fn(3);
    exception when division_by_zero then
        perform pgmb_data.raise_notice_fn(4);
    end;
    return (select count(*) from pgmb_data.g_raise where id = -1);
end$f$;
create function raise_notice_then_exception() returns void language plpgsql set client_min_messages = warning as
$f$begin
    raise notice 'before the error';
    raise exception 'the error' using errcode = 'P0042';
end$f$;
create function raise_notice_then_division_by_zero() returns int language plpgsql set client_min_messages = warning as
$f$begin
    raise notice 'before the error';
    return 1 / 0;
end$f$$q$);

call pgmb.reg_ddl('raise.create_loop_functions', 'schema', $q$
create function raise_loop_none(n int) returns int language plpgsql set client_min_messages = warning as
$f$declare
    x int := 0;
begin
    for i in 1 .. n loop x := x + 1; end loop;
    return x;
end$f$;
create function raise_loop_notice_const(n int) returns int language plpgsql set client_min_messages = warning as
$f$begin
    for i in 1 .. n loop raise notice 'pgmb message'; end loop;
    return n;
end$f$;
create function raise_loop_notice_fmt1(n int) returns int language plpgsql set client_min_messages = warning as
$f$begin
    for i in 1 .. n loop raise notice 'pgmb row %', i; end loop;
    return n;
end$f$;
create function raise_loop_notice_fmt5(n int) returns int language plpgsql set client_min_messages = warning as
$f$begin
    for i in 1 .. n loop raise notice 'pgmb % % % % %', i, i, 'abc', true, 1.5; end loop;
    return n;
end$f$;
create function raise_loop_notice_using(n int) returns int language plpgsql set client_min_messages = warning as
$f$begin
    for i in 1 .. n loop
        raise notice using message = 'pgmb row ' || i, detail = 'detail', hint = 'hint';
    end loop;
    return n;
end$f$;
create function raise_loop_notice_text(n int, len int) returns int language plpgsql set client_min_messages = warning as
$f$declare
    t text := repeat('x', len);
begin
    for i in 1 .. n loop raise notice '%', t; end loop;
    return n;
end$f$;
create function raise_loop_notice_array(n int) returns int language plpgsql set client_min_messages = warning as
$f$declare
    a int[] := array(select g from generate_series(1, 100) g);
begin
    for i in 1 .. n loop raise notice '%', a; end loop;
    return n;
end$f$;
create function raise_loop_notice_jsonb(n int) returns int language plpgsql set client_min_messages = warning as
$f$declare
    j jsonb := (select jsonb_object_agg('k' || g, g) from generate_series(1, 100) g);
begin
    for i in 1 .. n loop raise notice '%', j; end loop;
    return n;
end$f$$q$);

------------------------------------------------------------------------------
-- what the compiler and RAISE itself reject
------------------------------------------------------------------------------
call pgmb.reg('raise.err_too_few_parameters', '{errors}',
    $q$do $do$ begin raise notice 'a % b %', 1; end $do$$q$, expect_error => '42601');
call pgmb.reg('raise.err_too_many_parameters', '{errors}',
    $q$do $do$ begin raise notice 'a %', 1, 2; end $do$$q$, expect_error => '42601');
-- the format must be a literal: an expression or a variable is a syntax error ...
call pgmb.reg('raise.err_format_is_expression', '{errors}',
    $q$do $do$ begin raise notice 'a' || 'b'; end $do$$q$, expect_error => '42601');
call pgmb.reg('raise.err_format_is_variable', '{errors}',
    $q$do $do$ declare f text := 'a'; begin raise notice f; end $do$$q$, expect_error => '42601');
-- ... and a bare word is read as the name of a condition
call pgmb.reg('raise.err_format_is_bare_word', '{errors}',
    $q$do $do$ begin raise notice some_text; end $do$$q$, expect_error => '42704');
call pgmb.reg('raise.err_message_given_twice', '{errors}',
    $q$do $do$ begin raise notice 'a' using message = 'b'; end $do$$q$, expect_error => '42601');
call pgmb.reg('raise.err_option_is_null', '{errors}',
    $q$do $do$ begin raise notice using message = null::text; end $do$$q$, expect_error => '22004');
call pgmb.reg('raise.err_unknown_condition_name', '{errors}',
    $q$do $do$ begin raise notice 'a' using errcode = 'no_such_condition'; end $do$$q$, expect_error => '42704');

-- a notice first, then an error: the statement ends with the error's SQLSTATE
call pgmb.reg('raise.err_notice_then_exception_custom_sqlstate', '{errors}',
    $q$select raise_notice_then_exception()$q$, expect_error => 'P0042');
call pgmb.reg('raise.err_notice_then_division_by_zero', '{errors}',
    $q$select raise_notice_then_division_by_zero()$q$, expect_error => '22012');

------------------------------------------------------------------------------
-- what RAISE builds: text and diagnostic fields
------------------------------------------------------------------------------
call pgmb.reg('raise.format_placeholders', '{consistency}',
    $q$select raise_capture_format()$q$, equiv => 'raise.format');
call pgmb.reg('raise.format_placeholders_expected', '{consistency}',
    $q$select 'a 1 b % c x d'::text$q$, equiv => 'raise.format');

call pgmb.reg('raise.format_ten_parameters', '{consistency}',
    $q$select raise_capture_format_many()$q$, equiv => 'raise.format_many');
call pgmb.reg('raise.format_ten_parameters_expected', '{consistency}',
    $q$select '1-2-3-4-5-6-7-8-9-10 100%'::text$q$, equiv => 'raise.format_many');

-- NULL is written as <NULL>, a boolean as t
call pgmb.reg('raise.format_scalar_types', '{consistency}',
    $q$select raise_capture_scalar_types()$q$, equiv => 'raise.scalar_types');
call pgmb.reg('raise.format_scalar_types_expected', '{consistency}', $q$
select '<NULL> t 42 9007199254740993 1.50 2026-01-02 03:04:05 2026-01-02 03:04:05+00 00000000-0000-0000-0000-000000000001'::text$q$,
    equiv => 'raise.scalar_types');

call pgmb.reg('raise.format_composite_types', '{consistency}',
    $q$select raise_capture_composite_types()$q$, equiv => 'raise.composite_types');
call pgmb.reg('raise.format_composite_types_expected', '{consistency}',
    $q$select '{1,2,3} {"a": 1} (1,x) [1,5) {[1,5)} \xdeadbeef'::text$q$, equiv => 'raise.composite_types');

call pgmb.reg('raise.format_length_0_to_100k', '{consistency}',
    $q$select n, raise_capture_length(n) from unnest(array[0, 1, 100, 1000, 100000]) n$q$, equiv => 'raise.length');
call pgmb.reg('raise.format_length_0_to_100k_expected', '{consistency}',
    $q$select n, n from unnest(array[0, 1, 100, 1000, 100000]) n$q$, equiv => 'raise.length');

call pgmb.reg('raise.using_message_expression', '{consistency}',
    $q$select raise_capture_using_message()$q$, equiv => 'raise.using_message');
call pgmb.reg('raise.using_message_expression_expected', '{consistency}',
    $q$select 'row 5 of 10'::text$q$, equiv => 'raise.using_message');

call pgmb.reg('raise.using_all_fields', '{consistency}',
    $q$select raise_capture_fields()$q$, equiv => 'raise.fields');
call pgmb.reg('raise.using_all_fields_expected', '{consistency}',
    $q$select 'P0042|m|d|h|c|k|t|tb|s'::text$q$, equiv => 'raise.fields');

call pgmb.reg('raise.using_fields_empty_and_odd', '{consistency}',
    $q$select raise_capture_fields_empty_and_odd()$q$, equiv => 'raise.fields_odd');
call pgmb.reg('raise.using_fields_empty_and_odd_expected', '{consistency}',
    $q$select 'P0001|||Odd "Name"'::text$q$, equiv => 'raise.fields_odd');

call pgmb.reg('raise.context_three_levels', '{consistency}',
    $q$select raise_ctx_l1()$q$, equiv => 'raise.context');
call pgmb.reg('raise.context_three_levels_expected', '{consistency}',
    $q$select '3 levels, innermost first: t, raised at line 2'::text$q$, equiv => 'raise.context');

call pgmb.reg('raise.notice_all_forms_run', '{consistency}',
    $q$select raise_notice_all_forms()$q$, equiv => 'raise.all_forms');
call pgmb.reg('raise.notice_all_forms_run_expected', '{consistency}',
    $q$select 'done'::text$q$, equiv => 'raise.all_forms');

-- Polish letters, a four-byte character and a tab; only in a UTF8 database
select current_setting('server_encoding') = 'UTF8' as pgmb_raise_utf8 \gset
\if :pgmb_raise_utf8
call pgmb.reg_ddl('raise.create_capture_unicode', 'schema', $q$
create function raise_capture_unicode() returns text language plpgsql as
$f$begin
    raise exception 'zażółć gęślą jaźń % 🐘', E'tab\there';
exception when others then return sqlerrm;
end$f$$q$);
call pgmb.reg('raise.format_unicode', '{consistency}',
    $q$select raise_capture_unicode(), length(raise_capture_unicode()), octet_length(raise_capture_unicode())$q$,
    equiv => 'raise.unicode');
call pgmb.reg('raise.format_unicode_expected', '{consistency}',
    $q$select E'zażółć gęślą jaźń tab\there 🐘'::text, 28, 40$q$, equiv => 'raise.unicode');
\endif

------------------------------------------------------------------------------
-- how often RAISE runs: control flow in PL/pgSQL
------------------------------------------------------------------------------
call pgmb.reg('raise.expected_0',   '{consistency}', $q$select 0::bigint$q$,   equiv => 'raise.count_0');
call pgmb.reg('raise.expected_1',   '{consistency}', $q$select 1::bigint$q$,   equiv => 'raise.count_1');
call pgmb.reg('raise.expected_2',   '{consistency}', $q$select 2::bigint$q$,   equiv => 'raise.count_2');
call pgmb.reg('raise.expected_3',   '{consistency}', $q$select 3::bigint$q$,   equiv => 'raise.count_3');
call pgmb.reg('raise.expected_5',   '{consistency}', $q$select 5::bigint$q$,   equiv => 'raise.count_5');
call pgmb.reg('raise.expected_7',   '{consistency}', $q$select 7::bigint$q$,   equiv => 'raise.count_7');
call pgmb.reg('raise.expected_10',  '{consistency}', $q$select 10::bigint$q$,  equiv => 'raise.count_10');
call pgmb.reg('raise.expected_16',  '{consistency}', $q$select 16::bigint$q$,  equiv => 'raise.count_16');
call pgmb.reg('raise.expected_20',  '{consistency}', $q$select 20::bigint$q$,  equiv => 'raise.count_20');
call pgmb.reg('raise.expected_50',  '{consistency}', $q$select 50::bigint$q$,  equiv => 'raise.count_50');
call pgmb.reg('raise.expected_60',  '{consistency}', $q$select 60::bigint$q$,  equiv => 'raise.count_60');
call pgmb.reg('raise.expected_100', '{consistency}', $q$select 100::bigint$q$, equiv => 'raise.count_100');

-- 30 iterations: every third in the IF, every fifth in the CASE
call pgmb.reg('raise.flow_if_and_case_branches', '{consistency}',
    $q$select raise_count($s$select raise_flow_if_case(30)$s$)$q$, equiv => 'raise.count_16');
call pgmb.reg('raise.flow_loop_never_entered', '{consistency}',
    $q$select raise_count($s$select raise_flow_if_case(0)$s$)$q$, equiv => 'raise.count_0');

call pgmb.reg('raise.flow_for_select_empty', '{consistency}',
    $q$select raise_count($s$select raise_flow_for_select(0, null, false)$s$)$q$, equiv => 'raise.count_0');
call pgmb.reg('raise.flow_for_select_limit_10', '{consistency}',
    $q$select raise_count($s$select raise_flow_for_select(10, null, false)$s$)$q$, equiv => 'raise.count_10');
-- the rows arrive in descending order: EXIT at 91 is reached after ten rows
call pgmb.reg('raise.flow_for_select_exit', '{consistency}',
    $q$select raise_count($s$select raise_flow_for_select(100, 91, false)$s$)$q$, equiv => 'raise.count_10');
call pgmb.reg('raise.flow_for_select_continue', '{consistency}',
    $q$select raise_count($s$select raise_flow_for_select(10, null, true)$s$)$q$, equiv => 'raise.count_5');

call pgmb.reg('raise.flow_nested_calls_5_deep', '{consistency}',
    $q$select raise_count($s$select raise_flow_nested(5)$s$)$q$, equiv => 'raise.count_5');
call pgmb.reg('raise.flow_return_ends_loop', '{consistency}',
    $q$select raise_count($s$select raise_flow_return_early(100)$s$)$q$, equiv => 'raise.count_7');

-- the failed block raised twice and its handler once; the row it inserted is gone
call pgmb.reg('raise.flow_exception_block_raise_count', '{consistency}',
    $q$select raise_count($s$select raise_flow_exception_block()$s$)$q$, equiv => 'raise.count_3');
call pgmb.reg('raise.flow_exception_block_row_undone', '{consistency}', $q$
begin;
set local client_min_messages = warning;
select raise_flow_exception_block();
commit;$q$, equiv => 'raise.count_0');

------------------------------------------------------------------------------
-- how often RAISE runs: a raising function inside SQL
------------------------------------------------------------------------------
-- readers that stop early
call pgmb.reg('raise.sql_all_rows', '{consistency}',
    $q$select raise_count($s$select raise_notice_fn(n::int) from generate_series(1, 100) n$s$)$q$,
    equiv => 'raise.count_100');
call pgmb.reg('raise.sql_limit_5', '{consistency}',
    $q$select raise_count($s$select raise_notice_fn(n::int) from generate_series(1, 100) n limit 5$s$)$q$,
    equiv => 'raise.count_5');
call pgmb.reg('raise.sql_exists_first_row', '{consistency}', $q$
select raise_count($s$select exists (select 1 from generate_series(1, 100) n where raise_notice_fn(n::int) > 0)$s$)$q$,
    equiv => 'raise.count_1');
-- EXISTS does not evaluate the select list
call pgmb.reg('raise.sql_exists_select_list_not_evaluated', '{consistency}', $q$
select raise_count($s$select exists (select raise_notice_fn(n::int) from generate_series(1, 100) n)$s$)$q$,
    equiv => 'raise.count_0');

-- CTEs: a volatile function is never inlined, so it runs once per row whatever
-- the number of readers
call pgmb.reg('raise.cte_unreferenced', '{consistency}', $q$
select raise_count($s$with c as (select raise_notice_fn(n::int) as v from generate_series(1, 100) n) select 1$s$)$q$,
    equiv => 'raise.count_0');
call pgmb.reg('raise.cte_one_reader', '{consistency}', $q$
select raise_count($s$with c as (select raise_notice_fn(n::int) as v from generate_series(1, 100) n)
                      select count(v) from c$s$)$q$, equiv => 'raise.count_100');
call pgmb.reg('raise.cte_two_readers_default', '{consistency}', $q$
select raise_count($s$with c as (select raise_notice_fn(n::int) as v from generate_series(1, 100) n)
                      select (select count(v) from c), (select max(v) from c)$s$)$q$, equiv => 'raise.count_100');
call pgmb.reg('raise.cte_two_readers_materialized', '{consistency}', $q$
select raise_count($s$with c as materialized (select raise_notice_fn(n::int) as v from generate_series(1, 100) n)
                      select (select count(v) from c), (select max(v) from c)$s$)$q$, equiv => 'raise.count_100');
call pgmb.reg('raise.cte_two_readers_not_materialized', '{consistency}', $q$
select raise_count($s$with c as not materialized (select raise_notice_fn(n::int) as v from generate_series(1, 100) n)
                      select (select count(v) from c), (select max(v) from c)$s$)$q$, equiv => 'raise.count_100');
call pgmb.reg('raise.cte_reader_limit_5', '{consistency}', $q$
select raise_count($s$with c as materialized (select raise_notice_fn(n::int) as v from generate_series(1, 100) n)
                      select v from c limit 5$s$)$q$, equiv => 'raise.count_5');

-- once per outer row
call pgmb.reg('raise.sql_correlated_subquery_20_rows', '{consistency}', $q$
select raise_count($s$select (select raise_notice_fn(o.n::int)) from generate_series(1, 20) o(n)$s$)$q$,
    equiv => 'raise.count_20');
call pgmb.reg('raise.sql_lateral_20_by_3', '{consistency}', $q$
select raise_count($s$select s.v from generate_series(1, 20) o(n),
                      lateral (select raise_notice_fn((o.n * 10 + i)::int) as v from generate_series(1, 3) i) s$s$)$q$,
    equiv => 'raise.count_60');
call pgmb.reg('raise.sql_lateral_no_outer_rows', '{consistency}', $q$
select raise_count($s$select s.v from generate_series(1, 0) o(n),
                      lateral (select raise_notice_fn(i::int) as v from generate_series(1, 3) i) s$s$)$q$,
    equiv => 'raise.count_0');

-- recursion: once per iteration; an outer LIMIT ends an endless one
call pgmb.reg('raise.recursive_50_iterations', '{consistency}', $q$
select raise_count($s$with recursive r(n) as (select raise_notice_fn(1) union all
                                               select raise_notice_fn(n + 1) from r where n < 50)
                      select count(*) from r$s$)$q$, equiv => 'raise.count_50');
call pgmb.reg('raise.recursive_endless_limit_5', '{consistency}', $q$
select raise_count($s$with recursive r(n) as (select raise_notice_fn(1) union all
                                               select raise_notice_fn(n + 1) from r where n < 1000000)
                      select n from r limit 5$s$)$q$, equiv => 'raise.count_5');

-- RETURNING: once per row written, also when nobody reads the rows
call pgmb.reg('raise.returning_update_7_rows', '{consistency}', $q$
select raise_count($s$update g_raise set v = v + 1 where id <= 7 returning raise_notice_fn(id)$s$)$q$,
    equiv => 'raise.count_7');
call pgmb.reg('raise.returning_in_unread_cte', '{consistency}', $q$
select raise_count($s$with u as (update g_raise set v = v + 1 where id <= 7 returning raise_notice_fn(id))
                      select 1$s$)$q$, equiv => 'raise.count_7');
call pgmb.reg('raise.returning_cte_reader_limit_2', '{consistency}', $q$
select raise_count($s$with u as (update g_raise set v = v + 1 where id <= 7 returning raise_notice_fn(id) as r)
                      select r from u limit 2$s$)$q$, equiv => 'raise.count_7');

------------------------------------------------------------------------------
-- how often RAISE runs: triggers
------------------------------------------------------------------------------
-- per row
call pgmb.reg('raise.trigger_row_insert_10', '{consistency}', $q$
select raise_count($s$insert into g_raise_row select n, 0 from generate_series(11, 20) n$s$)$q$,
    equiv => 'raise.count_10');
call pgmb.reg('raise.trigger_row_update_10', '{consistency}',
    $q$select raise_count($s$update g_raise_row set v = v + 1$s$)$q$, equiv => 'raise.count_10');
call pgmb.reg('raise.trigger_row_update_no_rows', '{consistency}',
    $q$select raise_count($s$update g_raise_row set v = v + 1 where id < 0$s$)$q$, equiv => 'raise.count_0');
call pgmb.reg('raise.trigger_row_delete_10', '{consistency}',
    $q$select raise_count($s$delete from g_raise_row$s$)$q$, equiv => 'raise.count_10');
-- rows 6 to 15: five are updated, five inserted
call pgmb.reg('raise.trigger_row_on_conflict_5_and_5', '{consistency}', $q$
select raise_count($s$insert into g_raise_row select n, 0 from generate_series(6, 15) n
                      on conflict (id) do update set v = g_raise_row.v + 1$s$)$q$, equiv => 'raise.count_10');
call pgmb.reg('raise.trigger_row_merge_5_and_5', '{consistency}', $q$
select raise_count($s$merge into g_raise_row t using generate_series(6, 15) s(n) on t.id = s.n
                      when matched then update set v = t.v + 1
                      when not matched then insert values (s.n, 0)$s$)$q$, equiv => 'raise.count_10');

-- per statement: once, also when no row is touched; ON CONFLICT DO UPDATE and
-- MERGE fire the trigger once for each kind of action they name
call pgmb.reg('raise.trigger_statement_insert_10', '{consistency}', $q$
select raise_count($s$insert into g_raise_stmt select n, 0 from generate_series(11, 20) n$s$)$q$,
    equiv => 'raise.count_1');
call pgmb.reg('raise.trigger_statement_update_10', '{consistency}',
    $q$select raise_count($s$update g_raise_stmt set v = v + 1$s$)$q$, equiv => 'raise.count_1');
call pgmb.reg('raise.trigger_statement_update_no_rows', '{consistency}',
    $q$select raise_count($s$update g_raise_stmt set v = v + 1 where id < 0$s$)$q$, equiv => 'raise.count_1');
call pgmb.reg('raise.trigger_statement_delete_10', '{consistency}',
    $q$select raise_count($s$delete from g_raise_stmt$s$)$q$, equiv => 'raise.count_1');
call pgmb.reg('raise.trigger_statement_on_conflict', '{consistency}', $q$
select raise_count($s$insert into g_raise_stmt select n, 0 from generate_series(6, 15) n
                      on conflict (id) do update set v = g_raise_stmt.v + 1$s$)$q$, equiv => 'raise.count_2');
call pgmb.reg('raise.trigger_statement_merge', '{consistency}', $q$
select raise_count($s$merge into g_raise_stmt t using generate_series(6, 15) s(n) on t.id = s.n
                      when matched then update set v = t.v + 1
                      when not matched then insert values (s.n, 0)$s$)$q$, equiv => 'raise.count_2');

------------------------------------------------------------------------------
-- cost of a NOTICE that is filtered out, in a PL/pgSQL loop
------------------------------------------------------------------------------
call pgmb.reg('raise.loop_none_10k', '{perf}', $q$select raise_loop_none(10000)$q$);
call pgmb.reg('raise.loop_notice_const_1', '{perf,oltp}', $q$select raise_loop_notice_const(1)$q$);
call pgmb.reg('raise.loop_notice_const_100', '{perf,oltp}', $q$select raise_loop_notice_const(100)$q$);
call pgmb.reg('raise.loop_notice_const_1k', '{perf}', $q$select raise_loop_notice_const(1000)$q$);
call pgmb.reg('raise.loop_notice_const_10k', '{perf}', $q$select raise_loop_notice_const(10000)$q$);
call pgmb.reg('raise.loop_notice_const_100k', '{perf}', $q$select raise_loop_notice_const(100000)$q$);

-- constant text against one and five parameters, and against USING
call pgmb.reg('raise.loop_notice_one_parameter_10k', '{perf}', $q$select raise_loop_notice_fmt1(10000)$q$);
call pgmb.reg('raise.loop_notice_five_parameters_10k', '{perf}', $q$select raise_loop_notice_fmt5(10000)$q$);
call pgmb.reg('raise.loop_notice_using_fields_10k', '{perf}', $q$select raise_loop_notice_using(10000)$q$);

-- values that are converted to text for every message
call pgmb.reg('raise.loop_notice_array_100_elements_10k', '{perf}', $q$select raise_loop_notice_array(10000)$q$);
call pgmb.reg('raise.loop_notice_jsonb_100_keys_10k', '{perf}', $q$select raise_loop_notice_jsonb(10000)$q$);

-- one megabyte of text: 10,000 messages of 100 bytes, 1,000 of 1 kB, 10 of 100 kB
call pgmb.reg('raise.loop_notice_text_100b_10k', '{perf}', $q$select raise_loop_notice_text(10000, 100)$q$);
call pgmb.reg('raise.loop_notice_text_1kb_1k', '{perf}', $q$select raise_loop_notice_text(1000, 1000)$q$);
call pgmb.reg('raise.loop_notice_text_100kb_10', '{perf}', $q$select raise_loop_notice_text(10, 100000)$q$);

------------------------------------------------------------------------------
-- cost of a filtered NOTICE raised by a function called from SQL
------------------------------------------------------------------------------
-- the same 1000 messages as raise.loop_notice_const_1k, one function call each
call pgmb.reg('raise.sql_calls_silent_1k', '{perf}',
    $q$select count(raise_silent_fn(n::int)) from generate_series(1, 1000) n$q$);
call pgmb.reg('raise.sql_calls_notice_1k', '{perf}', $q$
begin;
set local client_min_messages = warning;
select count(raise_notice_fn(n::int)) from generate_series(1, 1000) n;
commit;$q$);

------------------------------------------------------------------------------
-- cost of a filtered NOTICE raised by a trigger: per row against per statement
------------------------------------------------------------------------------
-- Every client updates the same ten rows, so the clients queue on row locks.
call pgmb.reg('raise.trigger_cost_none_10_rows', '{perf,concurrency}', $q$
begin;
set local client_min_messages = warning;
update g_raise set v = v + 1;
commit;$q$, kind => 'write');
call pgmb.reg('raise.trigger_cost_per_row_10_rows', '{perf,concurrency}', $q$
begin;
set local client_min_messages = warning;
update g_raise_row set v = v + 1;
commit;$q$, kind => 'write');
call pgmb.reg('raise.trigger_cost_per_statement_10_rows', '{perf,concurrency}', $q$
begin;
set local client_min_messages = warning;
update g_raise_stmt set v = v + 1;
commit;$q$, kind => 'write');
