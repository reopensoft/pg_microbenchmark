-- Topic: types - data types beyond integers and short text, and DDL on a
-- loaded table: numeric types and their limits, NaN and Infinity, UUID,
-- pattern matching, collations, JSON and SQL/JSON, ranges, enums, domains,
-- composite and polymorphic types, generated columns, ALTER TABLE.
--
-- g_types holds one column per type; its indexes are in index_types.sql.

insert into pgmb.dataset (name, base_rows, exponent, min_rows) values
    ('g_types', 200000, 1, 1000),
    ('g_ddl',   200000, 1, 1000);   -- altered step by step in the DDL phase

call pgmb.reg_ddl('types.create_types', 'schema', $q$
create type g_mood as enum ('sad', 'ok', 'happy');
create type g_pair as (a int, b text);
create domain g_positive as int check (value > 0);
create domain g_code as text not null check (value ~ '^[A-Z]{3}$')$q$);

call pgmb.reg_ddl('types.create_g_types', 'schema', $q$
create table g_types (
    id  bigint not null,
    u   uuid   not null,
    j   jsonb  not null,             -- {"id", "k": 0..99, "tags": [2 of 50], "nested": {"a": 0..9, "b": text}}
    j2  jsonb  not null,             -- copy of j, indexed with jsonb_path_ops
    doc text   not null,             -- three of 1000 words, and "common"
    tsv tsvector not null,
    r   int4range not null,          -- 1 to 100 wide, starting below 100000
    r2  int4range not null,          -- copy of r, indexed with SP-GiST
    mr  int4multirange not null,
    e   g_mood not null,
    f   double precision not null,   -- 0.3% NaN, Infinity or -Infinity
    n   numeric(12,2) not null,
    s   text   not null,             -- 5000 names, in upper, lower and mixed case
    k   int    not null              -- 100 distinct
)$q$);

call pgmb.reg_ddl('types.load_g_types', 'load', $q$
insert into g_types
select i, md5(i::text)::uuid, x.j, x.j, x.doc, to_tsvector('simple', x.doc),
       int4range(x.lo, x.lo + x.len), int4range(x.lo, x.lo + x.len),
       int4multirange(int4range(x.lo, x.lo + 10), int4range(x.lo + 20, x.lo + 30)),
       (array['sad', 'ok', 'happy'])[1 + pgmb.hu(i, 11, 3)::int]::g_mood,
       case pgmb.hu(i, 12, 1000) when 0 then 'NaN'::float8 when 1 then 'Infinity'::float8
            when 2 then '-Infinity'::float8 else pgmb.hf(i, 13) * 1000 end,
       pgmb.hu(i, 14, 1000000)::numeric / 100,
       case pgmb.hu(i, 15, 3) when 0 then upper(x.w) when 1 then lower(x.w) else x.w end,
       pgmb.hu(i, 17, 100)::int
from generate_series(1, :n_g_types) i,
     lateral (select jsonb_build_object('id', i, 'k', pgmb.hu(i, 1, 100),
                         'tags', jsonb_build_array('t' || pgmb.hu(i, 2, 50), 't' || pgmb.hu(i, 3, 50)),
                         'nested', jsonb_build_object('a', pgmb.hu(i, 4, 10), 'b', pgmb.htext(i, 5, 8))) as j,
                     concat_ws(' ', 'word' || pgmb.hu(i, 6, 1000), 'word' || pgmb.hu(i, 7, 1000),
                               'word' || pgmb.hu(i, 8, 1000), 'common') as doc,
                     pgmb.hu(i, 9, 100000)::int as lo, 1 + pgmb.hu(i, 10, 100)::int as len,
                     'Name' || pgmb.hu(i, 16, 5000) as w) x$q$, target => 'g_types');

call pgmb.reg('types.expected_true', '{consistency}', $q$select true$q$, equiv => 'types.true');

------------------------------------------------------------------------------
-- integers, numeric, float
------------------------------------------------------------------------------
-- the same hundred values summed as each type
call pgmb.reg('types.sum_as_smallint', '{perf,consistency,olap,needs_data}',
    $q$select sum(k::smallint)::numeric from g_types$q$, equiv => 'types.sum_k');
call pgmb.reg('types.sum_as_integer', '{perf,consistency,olap,needs_data}',
    $q$select sum(k)::numeric from g_types$q$, equiv => 'types.sum_k');
call pgmb.reg('types.sum_as_bigint', '{perf,consistency,olap,needs_data}',
    $q$select sum(k::bigint)::numeric from g_types$q$, equiv => 'types.sum_k');
call pgmb.reg('types.sum_as_numeric', '{perf,consistency,olap,needs_data}',
    $q$select sum(k::numeric) from g_types$q$, equiv => 'types.sum_k');
call pgmb.reg('types.sum_as_float8', '{perf,consistency,olap,needs_data}',
    $q$select sum(k::float8)::numeric from g_types$q$, equiv => 'types.sum_k');

-- arithmetic on a numeric and on a float column
call pgmb.reg('types.arithmetic_numeric', '{perf,olap}',
    $q$select sum(n * 1.1 + n / 3), avg(n) from g_types$q$);
call pgmb.reg('types.arithmetic_float8', '{perf,olap}',
    $q$select sum(f * 1.1 + f / 3), avg(f) from g_types where f < 'Infinity' and f > '-Infinity'$q$);

-- where each type ends
call pgmb.reg('types.err_smallint_overflow', '{errors}',
    $q$select 32767::smallint + 1::smallint$q$, expect_error => '22003');
call pgmb.reg('types.err_integer_overflow', '{errors}',
    $q$select 2147483647 + 1$q$, expect_error => '22003');
call pgmb.reg('types.err_bigint_overflow', '{errors}',
    $q$select 9223372036854775807 + 1$q$, expect_error => '22003');
call pgmb.reg('types.err_cast_integer_to_smallint', '{errors}',
    $q$select 40000::smallint$q$, expect_error => '22003');
call pgmb.reg('types.err_numeric_precision', '{errors}',
    $q$select 1000::numeric(5, 2)$q$, expect_error => '22003');
call pgmb.reg('types.err_float8_overflow', '{errors}',
    $q$select 1e308::float8 * 10$q$, expect_error => '22003');
call pgmb.reg('types.err_float8_division_by_zero', '{errors}',
    $q$select 1::float8 / 0$q$, expect_error => '22012');
call pgmb.reg('types.err_sum_cast_overflow', '{errors}',
    $q$select sum(n)::integer from generate_series(2147483000, 2147483647) n$q$, expect_error => '22003');

-- NaN equals itself and is larger than everything, Infinity included
call pgmb.reg('types.nan_and_infinity_comparisons', '{consistency}', $q$
select 'NaN'::float8 = 'NaN'::float8, 'NaN'::float8 > 'Infinity'::float8, 'NaN'::numeric = 'NaN'::numeric,
       'Infinity'::float8 + 1 = 'Infinity'::float8, 'Infinity'::numeric > 1e300::numeric,
       ('Infinity'::float8 - 'Infinity'::float8)::text = 'NaN'$q$, equiv => 'types.nan');
call pgmb.reg('types.nan_and_infinity_comparisons_expected', '{consistency}',
    $q$select true, true, true, true, true, true$q$, equiv => 'types.nan');

call pgmb.reg('types.nan_sorts_last', '{consistency}', $q$
select array_agg(x order by x)::text from (values (1::float8), ('NaN'), ('Infinity'), ('-Infinity')) v(x)$q$,
    equiv => 'types.nan_sort');
call pgmb.reg('types.nan_sorts_last_expected', '{consistency}',
    $q$select '{-Infinity,1,Infinity,NaN}'::text$q$, equiv => 'types.nan_sort');

-- a column with a few NaN and infinite values: sorted, and aggregated around them
call pgmb.reg('types.sort_float8_with_nan_top_10', '{perf,planning}',
    $q$select f from g_types order by f desc, id limit 10$q$);
call pgmb.reg('types.count_nan_and_infinite', '{perf,planning}', $q$
select count(*) filter (where f = 'NaN'), count(*) filter (where f = 'Infinity'),
       count(*) filter (where f = '-Infinity') from g_types$q$);

------------------------------------------------------------------------------
-- UUID
------------------------------------------------------------------------------
call pgmb.reg('types.uuid_generate_1000', '{perf}',
    $q$select count(gen_random_uuid()) from generate_series(1, 1000)$q$);
call pgmb.reg('types.uuid_sort_1000', '{perf,planning}',
    $q$select u from g_types where id between :id and :id + 999 order by u$q$, setup => '\set id random(1, :n_g_types)');
-- compared as a value, and as text
call pgmb.reg('types.uuid_compare_as_uuid', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where u < '80000000-0000-0000-0000-000000000000'$q$, equiv => 'types.uuid_half');
call pgmb.reg('types.uuid_compare_as_text', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where left(u::text, 1) < '8'$q$, equiv => 'types.uuid_half');
call pgmb.reg('types.err_uuid_malformed', '{errors}',
    $q$select 'not-a-uuid'::uuid$q$, expect_error => '22P02');

------------------------------------------------------------------------------
-- pattern matching
------------------------------------------------------------------------------
-- names that start with "Name12", written four ways
call pgmb.reg('types.match_like_prefix', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where s like 'Name12%'$q$, equiv => 'types.name12');
call pgmb.reg('types.match_regex_anchored', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where s ~ '^Name12'$q$, equiv => 'types.name12');
call pgmb.reg('types.match_starts_with', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where starts_with(s, 'Name12')$q$, equiv => 'types.name12');
call pgmb.reg('types.match_left_equality', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where left(s, 6) = 'Name12'$q$, equiv => 'types.name12');

-- the same in any spelling
call pgmb.reg('types.match_ilike_prefix', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where s ilike 'name12%'$q$, equiv => 'types.name12_ci');
call pgmb.reg('types.match_regex_case_insensitive', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where s ~* '^name12'$q$, equiv => 'types.name12_ci');
call pgmb.reg('types.match_lower_like_prefix', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where lower(s) like 'name12%'$q$, equiv => 'types.name12_ci');

-- patterns that cannot use a prefix
call pgmb.reg('types.match_like_infix', '{perf,planning}',
    $q$select count(*) from g_types where s like '%me12%'$q$);
call pgmb.reg('types.match_regex_alternation', '{perf,planning}',
    $q$select count(*) from g_types where s ~ '^(Name|NAME)1[0-9]{2}$'$q$);
call pgmb.reg('types.match_similar_to', '{perf,planning}',
    $q$select count(*) from g_types where s similar to '(Name|NAME)1[0-9][0-9]'$q$);
call pgmb.reg('types.match_regexp_replace', '{perf,planning}',
    $q$select count(distinct regexp_replace(s, '[0-9]+$', '')) from g_types$q$);

------------------------------------------------------------------------------
-- Unicode and ICU collations
------------------------------------------------------------------------------
select current_setting('server_encoding') = 'UTF8' as pgmb_types_utf8,
       exists (select from pg_collation where collname = 'und-x-icu') as pgmb_types_icu \gset
\if :pgmb_types_utf8
-- characters against bytes; a letter with an accent as one code point and as two
call pgmb.reg('types.unicode_lengths', '{consistency}', $q$
select length('zażółć 🐘'), octet_length('zażółć 🐘'), length(U&'\00E9'), length(normalize(U&'\00E9', NFD)),
       U&'\00E9' = normalize(U&'e\0301', NFC)$q$, equiv => 'types.unicode');
call pgmb.reg('types.unicode_lengths_expected', '{consistency}',
    $q$select 8, 15, 1, 2, true$q$, equiv => 'types.unicode');
\endif
\if :pgmb_types_icu
call pgmb.reg_ddl('types.create_collation', 'schema',
    $q$create collation g_ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false)$q$);

-- a nondeterministic collation makes strings equal that are not the same bytes
call pgmb.reg('types.collation_case_insensitive_equality', '{consistency}', $q$
select 'ABC' = 'abc' collate g_ci, 'ABC' = 'abc' collate "C", 'a' < 'B' collate "und-x-icu", 'a' < 'B' collate "C"$q$,
    equiv => 'types.collation');
call pgmb.reg('types.collation_case_insensitive_equality_expected', '{consistency}',
    $q$select true, false, true, false$q$, equiv => 'types.collation');

-- grouping by a nondeterministic collation against grouping by lower()
call pgmb.reg('types.collation_group_case_insensitive', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from (select 1 from g_types group by s collate g_ci) x$q$, equiv => 'types.names_ci');
call pgmb.reg('types.collation_group_by_lower', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from (select 1 from g_types group by lower(s)) x$q$, equiv => 'types.names_ci');

-- the same sort under three collations
call pgmb.reg('types.collation_sort_c', '{perf,planning}',
    $q$select s from g_types where id between :id and :id + 9999 order by s collate "C"$q$,
    setup => '\set id random(1, :n_g_types)');
call pgmb.reg('types.collation_sort_icu', '{perf,planning}',
    $q$select s from g_types where id between :id and :id + 9999 order by s collate "und-x-icu"$q$,
    setup => '\set id random(1, :n_g_types)');
call pgmb.reg('types.collation_sort_icu_nondeterministic', '{perf,planning}',
    $q$select s from g_types where id between :id and :id + 9999 order by s collate g_ci$q$,
    setup => '\set id random(1, :n_g_types)');
\endif

------------------------------------------------------------------------------
-- JSON, jsonpath, SQL/JSON
------------------------------------------------------------------------------
-- JSON_TABLE against the older ways of turning a document into rows
call pgmb.reg('types.json_table_literal', '{perf,planning,consistency}', $q$
select a, b from json_table('[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}]'::jsonb, '$[*]'
                            columns (a int path '$.a', b text path '$.b')) t$q$, equiv => 'types.json_rows');
call pgmb.reg('types.json_to_recordset_literal', '{perf,planning,consistency}', $q$
select a, b from jsonb_to_recordset('[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}]'::jsonb) as t(a int, b text)$q$,
    equiv => 'types.json_rows');
call pgmb.reg('types.json_array_elements_literal', '{perf,planning,consistency}', $q$
select (e ->> 'a')::int as a, e ->> 'b' as b
from jsonb_array_elements('[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}]'::jsonb) e$q$, equiv => 'types.json_rows');

-- one field out of 1000 documents, five ways
call pgmb.reg('types.json_field_arrow', '{perf,planning,consistency,needs_data}', $q$
select sum((j -> 'nested' ->> 'a')::int) from g_types where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)', equiv => 'types.json_field');
call pgmb.reg('types.json_field_path_operator', '{perf,planning,consistency,needs_data}', $q$
select sum((j #>> '{nested,a}')::int) from g_types where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)', equiv => 'types.json_field');
call pgmb.reg('types.json_field_jsonpath', '{perf,planning,consistency,needs_data}', $q$
select sum((jsonb_path_query_first(j, '$.nested.a') #>> '{}')::int) from g_types where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)', equiv => 'types.json_field');
call pgmb.reg('types.json_field_json_value', '{perf,planning,consistency,needs_data}', $q$
select sum(json_value(j, '$.nested.a' returning int)) from g_types where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)', equiv => 'types.json_field');
call pgmb.reg('types.json_field_json_table', '{perf,planning,consistency,needs_data}', $q$
select sum(t.a) from g_types g, json_table(g.j, '$.nested' columns (a int path '$.a')) t
where g.id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)', equiv => 'types.json_field');

-- an array inside the document unnested
call pgmb.reg('types.json_array_unnest_elements', '{perf,planning,consistency,needs_data}', $q$
select count(*) from g_types g, jsonb_array_elements_text(g.j -> 'tags') t where g.id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)', equiv => 'types.json_tags');
call pgmb.reg('types.json_array_unnest_json_table', '{perf,planning,consistency,needs_data}', $q$
select count(*) from g_types g, json_table(g.j, '$.tags[*]' columns (t text path '$')) x
where g.id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)', equiv => 'types.json_tags');

-- text to json (checked, kept as text) and to jsonb (parsed into its binary form)
call pgmb.reg('types.json_parse_as_json', '{perf}', $q$
select count(j::text::json) from g_types where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)');
call pgmb.reg('types.json_parse_as_jsonb', '{perf}', $q$
select count(j::text::jsonb) from g_types where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)');
call pgmb.reg('types.json_build_and_aggregate', '{perf}', $q$
select jsonb_agg(jsonb_build_object('id', id, 'k', k, 's', s)) from g_types where id between :id and :id + 999$q$,
    setup => '\set id random(1, :n_g_types)');

call pgmb.reg('types.json_exists_and_query', '{consistency}', $q$
select json_exists('{"a": [1, 2, 3]}'::jsonb, '$.a[*] ? (@ > 2)'), json_query('{"a": [1, 2, 3]}'::jsonb, '$.a')::text,
       json_value('{"a": "x"}'::jsonb, '$.a'), json_value('{"a": "x"}'::jsonb, '$.b' default 'none' on empty)$q$,
    equiv => 'types.json_functions');
call pgmb.reg('types.json_exists_and_query_expected', '{consistency}',
    $q$select true, '[1, 2, 3]'::text, 'x'::text, 'none'::text$q$, equiv => 'types.json_functions');

call pgmb.reg('types.err_json_malformed', '{errors}',
    $q$select '{"a": }'::jsonb$q$, expect_error => '22P02');
call pgmb.reg('types.err_json_value_not_scalar', '{errors}',
    $q$select json_value('{"a": [1, 2]}'::jsonb, '$.a' error on error)$q$, expect_error => '2203F');

------------------------------------------------------------------------------
-- ranges and multiranges
------------------------------------------------------------------------------
call pgmb.reg('types.range_operators', '{consistency}', $q$
select (int4range(1, 5) + int4range(3, 9))::text, (int4range(1, 9) * int4range(3, 5))::text,
       (int4range(1, 9) - int4range(1, 3))::text, int4multirange(int4range(1, 3), int4range(2, 6))::text,
       (int4multirange(int4range(1, 9)) - int4multirange(int4range(3, 5)))::text,
       int4range(1, 5) @> 4, int4range(1, 5) @> 5, int4range(1, 5) && int4range(5, 9), isempty(int4range(3, 3))$q$,
    equiv => 'types.range');
call pgmb.reg('types.range_operators_expected', '{consistency}', $q$
select '[1,9)'::text, '[3,5)'::text, '[3,9)'::text, '{[1,6)}'::text, '{[1,3),[5,9)}'::text,
       true, false, false, true$q$, equiv => 'types.range');

-- a range cannot hold a hole, a multirange can
call pgmb.reg('types.err_range_difference_not_contiguous', '{errors}',
    $q$select int4range(1, 9) - int4range(3, 5)$q$, expect_error => '22000');
call pgmb.reg('types.err_range_bounds_reversed', '{errors}',
    $q$select int4range(5, 1)$q$, expect_error => '22000');

-- all ranges of 1000 rows merged into a multirange
call pgmb.reg('types.range_agg_1000', '{perf,planning}', $q$
select range_agg(r) from g_types where id between :id and :id + 999$q$, setup => '\set id random(1, :n_g_types)');
call pgmb.reg('types.range_width_and_bounds', '{perf,planning,consistency,needs_data}', $q$
select sum(upper(r) - lower(r)) from g_types$q$, equiv => 'types.range_width');
call pgmb.reg('types.multirange_unnest_width', '{perf,planning,consistency,needs_data}', $q$
select sum(upper(x) - lower(x)) from g_types, unnest(r::int4multirange) x$q$, equiv => 'types.range_width');

------------------------------------------------------------------------------
-- enum, domain, composite, polymorphic
------------------------------------------------------------------------------
-- an enum sorts in the order of its declaration, not of its labels
call pgmb.reg('types.enum_order', '{consistency}', $q$
select array_agg(e order by e)::text, 'sad'::g_mood < 'happy'::g_mood, enum_range(null::g_mood)::text
from (values ('happy'::g_mood), ('sad'), ('ok')) v(e)$q$, equiv => 'types.enum');
call pgmb.reg('types.enum_order_expected', '{consistency}',
    $q$select '{sad,ok,happy}'::text, true, '{sad,ok,happy}'::text$q$, equiv => 'types.enum');
call pgmb.reg('types.err_enum_unknown_label', '{errors}',
    $q$select 'angry'::g_mood$q$, expect_error => '22P02');

call pgmb.reg('types.enum_group_by', '{perf,planning,consistency,needs_data}',
    $q$select e::text, count(*) from g_types group by e$q$, equiv => 'types.enum_groups');
call pgmb.reg('types.enum_group_by_as_text', '{perf,planning,consistency,needs_data}',
    $q$select e::text, count(*) from g_types group by e::text$q$, equiv => 'types.enum_groups');
call pgmb.reg('types.enum_filter', '{perf,planning}',
    $q$select count(*) from g_types where e >= 'ok'$q$);

-- a domain checks every value that is cast to it
call pgmb.reg('types.err_domain_check', '{errors}',
    $q$select (-1)::g_positive$q$, expect_error => '23514');
call pgmb.reg('types.err_domain_not_null', '{errors}',
    $q$select null::g_code$q$, expect_error => '23502');
call pgmb.reg('types.err_domain_pattern', '{errors}',
    $q$select 'abc'::g_code$q$, expect_error => '23514');
call pgmb.reg('types.domain_cast_10k', '{perf,consistency}',
    $q$select sum(n::g_positive) from generate_series(1, 10000) n$q$, equiv => 'types.domain_sum');
call pgmb.reg('types.domain_cast_10k_base_type', '{perf,consistency}',
    $q$select sum(n::int) from generate_series(1, 10000) n$q$, equiv => 'types.domain_sum');

call pgmb.reg('types.composite_fields_and_comparison', '{consistency}', $q$
select (row(1, 'x')::g_pair).b, row(1, 'x')::g_pair = row(1, 'x')::g_pair, row(1, 'a')::g_pair < row(1, 'b')::g_pair,
       ((array[row(1, 'x')::g_pair, row(2, 'y')::g_pair])[2]).a$q$, equiv => 'types.composite');
call pgmb.reg('types.composite_fields_and_comparison_expected', '{consistency}',
    $q$select 'x'::text, true, true, 2$q$, equiv => 'types.composite');
call pgmb.reg('types.composite_build_and_take_apart_10k', '{perf}',
    $q$select sum((p).a), count((p).b) from (select row(n, n::text)::g_pair as p from generate_series(1, 10000) n offset 0) s$q$);

call pgmb.reg_ddl('types.create_polymorphic_functions', 'schema', $q$
create function g_first(anyarray) returns anyelement language sql immutable as 'select $1[1]';
create function g_same(anyelement, anyelement) returns boolean language sql immutable as 'select $1 = $2';
create function g_pick(anycompatible, anycompatible) returns anycompatible language sql immutable as
'select coalesce($1, $2)'$q$);

-- anyelement wants identical types, anycompatible finds a common one
call pgmb.reg('types.polymorphic_resolution', '{consistency}', $q$
select g_first(array[7, 8]), g_first(array['a', 'b']), g_same(1, 1), g_pick(1, 2.5), pg_typeof(g_pick(1, 2.5))::text$q$,
    equiv => 'types.polymorphic');
call pgmb.reg('types.polymorphic_resolution_expected', '{consistency}',
    $q$select 7, 'a'::text, true, 1::numeric, 'numeric'::text$q$, equiv => 'types.polymorphic');
call pgmb.reg('types.err_polymorphic_anyelement_mismatch', '{errors}',
    $q$select g_same(1, 'a'::text)$q$, expect_error => '42883');
call pgmb.reg('types.polymorphic_calls_10k', '{perf}',
    $q$select count(g_pick(n, 2.5)), count(g_first(array[n, n])) from generate_series(1, 10000) n$q$);

------------------------------------------------------------------------------
-- generated columns
------------------------------------------------------------------------------
call pgmb.reg_ddl('types.create_generated_tables', 'schema', $q$
create table g_gen (id int primary key, a int not null, b int not null, s int generated always as (a + b) stored);
insert into g_gen (id, a, b) select n, n, n * 2 from generate_series(1, 1000) n;
create table g_gen_plain (id int primary key, a int not null, b int not null, s int);
insert into g_gen_plain select n, n, n * 2, n * 3 from generate_series(1, 1000) n$q$);

call pgmb.reg('types.generated_stored_is_computed', '{consistency}',
    $q$select bool_and(s = a + b) from g_gen$q$, equiv => 'types.true');
call pgmb.reg('types.err_generated_insert_value', '{errors}',
    $q$insert into g_gen (id, a, b, s) values (-1, 1, 1, 5)$q$, expect_error => '428C9');
call pgmb.reg('types.err_generated_update_value', '{errors}',
    $q$update g_gen set s = 1 where id = 1$q$, expect_error => '428C9');

call pgmb.reg('types.generated_stored_insert_100', '{perf}', $q$
begin;
insert into g_gen (id, a, b) select :b + n, n, n from generate_series(1, 100) n;
delete from g_gen where id between :b + 1 and :b + 100;
commit;$q$, kind => 'write', setup => '\set b (:client_id + 1) * 1000');
call pgmb.reg('types.generated_none_insert_100', '{perf}', $q$
begin;
insert into g_gen_plain select :b + n, n, n, n + n from generate_series(1, 100) n;
delete from g_gen_plain where id between :b + 1 and :b + 100;
commit;$q$, kind => 'write', setup => '\set b (:client_id + 1) * 1000');
call pgmb.reg('types.generated_stored_read', '{perf,planning,consistency}',
    $q$select sum(s) from g_gen where id <= 1000$q$, equiv => 'types.generated_sum');
call pgmb.reg('types.generated_none_read_expression', '{perf,planning,consistency}',
    $q$select sum(a + b) from g_gen_plain where id <= 1000$q$, equiv => 'types.generated_sum');

-- a virtual column is computed when it is read (PostgreSQL 18)
select current_setting('server_version_num')::int >= 180000 as pgmb_types_virtual \gset
\if :pgmb_types_virtual
call pgmb.reg_ddl('types.create_generated_virtual', 'schema', $q$
create table g_gen_virtual (id int primary key, a int not null, b int not null, s int generated always as (a + b) virtual);
insert into g_gen_virtual (id, a, b) select n, n, n * 2 from generate_series(1, 1000) n$q$);
call pgmb.reg('types.generated_virtual_read', '{perf,planning,consistency}',
    $q$select sum(s) from g_gen_virtual where id <= 1000$q$, equiv => 'types.generated_sum');
call pgmb.reg('types.generated_virtual_insert_100', '{perf}', $q$
begin;
insert into g_gen_virtual (id, a, b) select :b + n, n, n from generate_series(1, 100) n;
delete from g_gen_virtual where id between :b + 1 and :b + 100;
commit;$q$, kind => 'write', setup => '\set b (:client_id + 1) * 1000');
\endif

------------------------------------------------------------------------------
-- ALTER TABLE on a loaded table: timed steps of the DDL phase
------------------------------------------------------------------------------
-- Each step is recorded with its time, its WAL and the size of the table
-- afterwards, which shows which of them rewrite the table.
call pgmb.reg_ddl('types.create_g_ddl', 'schema', $q$
create table g_ddl (id bigint not null, a int not null, v varchar(10) not null, pad text not null);
create table g_ddl_part (id bigint not null, b int not null) partition by range (b);
create table g_ddl_p_scan (id bigint not null, b int not null);
create table g_ddl_p_check (id bigint not null, b int not null)$q$);
call pgmb.reg_ddl('types.load_g_ddl', 'load', $q$
insert into g_ddl select i, pgmb.hu(i, 1, 1000)::int, pgmb.htext(i, 2, 10), pgmb.htext(i, 3, 40)
from generate_series(1, :n_g_ddl) i$q$, target => 'g_ddl');
call pgmb.reg_ddl('types.load_g_ddl_p_scan', 'load', $q$
insert into g_ddl_p_scan select i, pgmb.hu(i, 1, 10)::int from generate_series(1, :n_g_ddl) i$q$, target => 'g_ddl_p_scan');
call pgmb.reg_ddl('types.load_g_ddl_p_check', 'load', $q$
insert into g_ddl_p_check select i, 10 + pgmb.hu(i, 1, 10)::int from generate_series(1, :n_g_ddl) i$q$,
    target => 'g_ddl_p_check');
call pgmb.reg_ddl('types.pk_g_ddl', 'constraint', $q$alter table g_ddl add primary key (id)$q$, target => 'g_ddl_pkey');
-- with this constraint in place the partition can be attached without a scan
call pgmb.reg_ddl('types.check_g_ddl_p_check', 'constraint',
    $q$alter table g_ddl_p_check add constraint g_ddl_p_check_b check (b >= 10 and b < 20)$q$, target => 'g_ddl_p_check');

call pgmb.reg_ddl('types.ddl_01_add_column', 'maintenance',
    $q$alter table g_ddl add column c1 int$q$, target => 'g_ddl');
-- a constant default is stored in the catalog, the rows are not touched
call pgmb.reg_ddl('types.ddl_02_add_column_constant_default', 'maintenance',
    $q$alter table g_ddl add column c2 int default 7$q$, target => 'g_ddl');
-- a volatile default has to be computed for every row: the table is rewritten
call pgmb.reg_ddl('types.ddl_03_add_column_volatile_default', 'maintenance',
    $q$alter table g_ddl add column c3 double precision default random()$q$, target => 'g_ddl');
call pgmb.reg_ddl('types.ddl_04_alter_type_int_to_bigint', 'maintenance',
    $q$alter table g_ddl alter column a type bigint$q$, target => 'g_ddl');
-- a longer varchar needs neither a rewrite nor a scan
call pgmb.reg_ddl('types.ddl_05_alter_type_widen_varchar', 'maintenance',
    $q$alter table g_ddl alter column v type varchar(20)$q$, target => 'g_ddl');
call pgmb.reg_ddl('types.ddl_06_set_not_null', 'maintenance',
    $q$alter table g_ddl alter column c2 set not null$q$, target => 'g_ddl');
call pgmb.reg_ddl('types.ddl_07_drop_column', 'maintenance',
    $q$alter table g_ddl drop column c3$q$, target => 'g_ddl');
call pgmb.reg_ddl('types.ddl_08_attach_partition_scanned', 'maintenance',
    $q$alter table g_ddl_part attach partition g_ddl_p_scan for values from (0) to (10)$q$, target => 'g_ddl_p_scan');
call pgmb.reg_ddl('types.ddl_09_attach_partition_with_check', 'maintenance',
    $q$alter table g_ddl_part attach partition g_ddl_p_check for values from (10) to (20)$q$, target => 'g_ddl_p_check');
call pgmb.reg_ddl('types.ddl_10_detach_partition', 'maintenance',
    $q$alter table g_ddl_part detach partition g_ddl_p_scan$q$, target => 'g_ddl_p_scan');
call pgmb.reg_ddl('types.ddl_11_vacuum_analyze', 'maintenance', $q$vacuum (analyze) g_ddl$q$, target => 'g_ddl');
-- a view with a rule that redirects inserts into the table
call pgmb.reg_ddl('types.ddl_12_create_view_and_rule', 'maintenance', $q$
create view v_ddl as select id, a from g_ddl;
create rule v_ddl_insert as on insert to v_ddl
    do instead insert into g_ddl (id, a, v, pad) values (new.id, new.a, 'rule', 'rule')$q$);

-- a table with 1000 columns and one row
select 'create table g_ddl_wide (' || string_agg(format('c%s int', i), ', ' order by i) || ')' as pgmb_wide_ddl,
       'insert into g_ddl_wide select ' || string_agg(i::text, ', ' order by i) as pgmb_wide_ins
from generate_series(1, 1000) i \gset
call pgmb.reg_ddl('types.ddl_create_table_1000_columns', 'schema', :'pgmb_wide_ddl', target => 'g_ddl_wide');
call pgmb.reg_ddl('types.ddl_fill_table_1000_columns', 'load', :'pgmb_wide_ins', target => 'g_ddl_wide');

call pgmb.reg('types.wide_table_first_column', '{perf,planning,oltp}', $q$select c1 from g_ddl_wide$q$);
call pgmb.reg('types.wide_table_last_column', '{perf,planning,oltp}', $q$select c1000 from g_ddl_wide$q$);
call pgmb.reg('types.wide_table_all_columns', '{perf,planning,oltp}', $q$select * from g_ddl_wide$q$);

-- columns added later read as NULL or as their stored default
call pgmb.reg('types.ddl_added_columns_read', '{perf,planning,consistency,needs_data}',
    $q$select count(*) filter (where c1 is null and c2 = 7) = count(*) from g_ddl$q$, equiv => 'types.true');

-- an insert through the view is rewritten by the rule
call pgmb.reg('types.rule_insert_through_view', '{perf,oltp}', $q$
begin;
insert into v_ddl values (-1 - :client_id, 1);
delete from g_ddl where id = -1 - :client_id;
commit;$q$, kind => 'write');
call pgmb.reg('types.rule_insert_direct', '{perf,oltp}', $q$
begin;
insert into g_ddl (id, a, v, pad) values (-1 - :client_id, 1, 'rule', 'rule');
delete from g_ddl where id = -1 - :client_id;
commit;$q$, kind => 'write');
