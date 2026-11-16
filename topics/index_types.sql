-- Topic: index (part 3) - access methods over the columns of g_types: GIN on
-- JSONB (both operator classes) and on tsvector, GiST and SP-GiST on ranges,
-- GiST on multiranges, SP-GiST on text, btree on uuid and on an expression;
-- btree deduplication, page splits, REINDEX.
--
-- Where two operator classes are compared the table has the column twice, so
-- that each test can only use the index it is about.

call pgmb.reg_ddl('index.pk_g_types', 'constraint', $q$alter table g_types add primary key (id)$q$, target => 'g_types_pkey');
call pgmb.reg_ddl('index.types_u', 'index', $q$create index g_types_u on g_types (u)$q$, target => 'g_types_u');
call pgmb.reg_ddl('index.types_j_gin', 'index', $q$create index g_types_j on g_types using gin (j)$q$, target => 'g_types_j');
call pgmb.reg_ddl('index.types_j2_gin_path_ops', 'index',
    $q$create index g_types_j2 on g_types using gin (j2 jsonb_path_ops)$q$, target => 'g_types_j2');
call pgmb.reg_ddl('index.types_j_k_expression', 'index',
    $q$create index g_types_j_k on g_types ((j ->> 'k'))$q$, target => 'g_types_j_k');
call pgmb.reg_ddl('index.types_tsv_gin', 'index', $q$create index g_types_tsv on g_types using gin (tsv)$q$, target => 'g_types_tsv');
call pgmb.reg_ddl('index.types_r_gist', 'index', $q$create index g_types_r on g_types using gist (r)$q$, target => 'g_types_r');
call pgmb.reg_ddl('index.types_r2_spgist', 'index', $q$create index g_types_r2 on g_types using spgist (r2)$q$, target => 'g_types_r2');
call pgmb.reg_ddl('index.types_mr_gist', 'index', $q$create index g_types_mr on g_types using gist (mr)$q$, target => 'g_types_mr');
call pgmb.reg_ddl('index.types_s_spgist', 'index', $q$create index g_types_s on g_types using spgist (s)$q$, target => 'g_types_s');
-- three distinct values: with deduplication one posting list per value, without it one entry per row
call pgmb.reg_ddl('index.types_e_btree_deduplicated', 'index',
    $q$create index g_types_e_dedup on g_types (e) with (deduplicate_items = on)$q$, target => 'g_types_e_dedup');
call pgmb.reg_ddl('index.types_e_btree_not_deduplicated', 'index',
    $q$create index g_types_e_nodedup on g_types (e) with (deduplicate_items = off)$q$, target => 'g_types_e_nodedup');
call pgmb.reg_ddl('index.vacuum_g_types', 'maintenance', $q$vacuum (analyze) g_types$q$);
-- rebuilding an index, timed like its first build
call pgmb.reg_ddl('index.reindex_types_tsv_gin', 'maintenance', $q$reindex index g_types_tsv$q$, target => 'g_types_tsv');
call pgmb.reg_ddl('index.reindex_types_u_btree', 'maintenance', $q$reindex index g_types_u$q$, target => 'g_types_u');
call pgmb.reg_ddl('index.reindex_types_r_gist', 'maintenance', $q$reindex index g_types_r$q$, target => 'g_types_r');

\set pgmb_noindex 'begin;\nset local enable_indexscan = off;\nset local enable_bitmapscan = off;\nset local enable_indexonlyscan = off;\n'
\set pgmb_noseq 'begin;\nset local enable_seqscan = off;\n'
\set pgmb_ix_end ';\ncommit;'

------------------------------------------------------------------------------
-- JSONB
------------------------------------------------------------------------------
-- containment of one key: default operator class, jsonb_path_ops, an
-- expression index on the key, no index
call pgmb.reg('index.jsonb_contains_gin', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where j @> jsonb_build_object('k', :k)$q$,
    setup => '\set k random(0, 99)', equiv => 'index.jsonb_contains');
call pgmb.reg('index.jsonb_contains_gin_path_ops', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where j2 @> jsonb_build_object('k', :k)$q$,
    setup => '\set k random(0, 99)', equiv => 'index.jsonb_contains');
call pgmb.reg('index.jsonb_key_expression_btree', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where j ->> 'k' = (:k)::text$q$,
    setup => '\set k random(0, 99)', equiv => 'index.jsonb_contains');
call pgmb.reg('index.jsonb_contains_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where j @> jsonb_build_object('k', :k)$q$ || :'pgmb_ix_end',
    setup => '\set k random(0, 99)', equiv => 'index.jsonb_contains');

-- a nested value and an array element together: more selective, more keys to look up
call pgmb.reg('index.jsonb_contains_nested_gin', '{perf,planning,consistency,needs_data}', $q$
select count(*) from g_types where j @> jsonb_build_object('nested', jsonb_build_object('a', :a), 'tags', jsonb_build_array('t' || :t))$q$,
    setup => E'\\set a random(0, 9)\n\\set t random(0, 49)', equiv => 'index.jsonb_nested');
call pgmb.reg('index.jsonb_contains_nested_gin_path_ops', '{perf,planning,consistency,needs_data}', $q$
select count(*) from g_types where j2 @> jsonb_build_object('nested', jsonb_build_object('a', :a), 'tags', jsonb_build_array('t' || :t))$q$,
    setup => E'\\set a random(0, 9)\n\\set t random(0, 49)', equiv => 'index.jsonb_nested');
call pgmb.reg('index.jsonb_contains_nested_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where j @> jsonb_build_object('nested', jsonb_build_object('a', :a), 'tags', jsonb_build_array('t' || :t))$q$ || :'pgmb_ix_end',
    setup => E'\\set a random(0, 9)\n\\set t random(0, 49)', equiv => 'index.jsonb_nested');

-- a jsonpath predicate through the same indexes
call pgmb.reg('index.jsonb_jsonpath_gin', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where j @? '$.nested ? (@.a == 3)'$q$, equiv => 'index.jsonb_path');
call pgmb.reg('index.jsonb_jsonpath_gin_path_ops', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where j2 @? '$.nested ? (@.a == 3)'$q$, equiv => 'index.jsonb_path');
call pgmb.reg('index.jsonb_jsonpath_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where j @? '$.nested ? (@.a == 3)'$q$ || :'pgmb_ix_end', equiv => 'index.jsonb_path');

-- key existence: only the default operator class can answer it
call pgmb.reg('index.jsonb_key_exists_gin', '{perf,planning}',
    $q$select count(*) from g_types where j ? 'no_such_key'$q$);
call pgmb.reg('index.jsonb_key_exists_path_ops_not_indexable', '{perf,planning}',
    $q$select count(*) from g_types where j2 ? 'no_such_key'$q$);

------------------------------------------------------------------------------
-- full text search
------------------------------------------------------------------------------
call pgmb.reg('index.fts_one_term_gin', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'word' || :a)$q$,
    setup => '\set a random(0, 999)', equiv => 'index.fts_one_term');
-- the same search without a stored tsvector and without an index
call pgmb.reg('index.fts_one_term_to_tsvector_no_index', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where to_tsvector('simple', doc) @@ to_tsquery('simple', 'word' || :a)$q$,
    setup => '\set a random(0, 999)', equiv => 'index.fts_one_term');
call pgmb.reg('index.fts_one_term_like_no_index', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where ' ' || doc || ' ' like '% word' || :a || ' %'$q$,
    setup => '\set a random(0, 999)', equiv => 'index.fts_one_term');

call pgmb.reg('index.fts_two_terms_and_gin', '{perf,planning}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'word' || :a || ' & word' || :b)$q$,
    setup => E'\\set a random(0, 999)\n\\set b random(0, 999)');
call pgmb.reg('index.fts_two_terms_or_gin', '{perf,planning}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'word' || :a || ' | word' || :b)$q$,
    setup => E'\\set a random(0, 999)\n\\set b random(0, 999)');
-- a rare term and one that is in every row
call pgmb.reg('index.fts_rare_and_common_term_gin', '{perf,planning}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'common & word' || :a)$q$,
    setup => '\set a random(0, 999)');
call pgmb.reg('index.fts_common_term_gin', '{perf,planning}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'common')$q$);
call pgmb.reg('index.fts_negation_gin', '{perf,planning}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'word' || :a || ' & !word' || :b)$q$,
    setup => E'\\set a random(0, 999)\n\\set b random(0, 999)');
call pgmb.reg('index.fts_prefix_gin', '{perf,planning}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'word12:*')$q$);
-- a phrase needs positions: the index finds candidates, the heap decides
call pgmb.reg('index.fts_phrase_gin', '{perf,planning}',
    $q$select count(*) from g_types where tsv @@ to_tsquery('simple', 'word' || :a || ' <-> common')$q$,
    setup => '\set a random(0, 999)');
call pgmb.reg('index.fts_ranked_top_10', '{perf,planning}', $q$
select id, ts_rank(tsv, q) as rank
from g_types, to_tsquery('simple', 'word' || :a || ' | word' || :b) q
where tsv @@ q order by rank desc, id limit 10$q$,
    setup => E'\\set a random(0, 999)\n\\set b random(0, 999)');

------------------------------------------------------------------------------
-- ranges and multiranges: GiST against SP-GiST against no index
------------------------------------------------------------------------------
call pgmb.reg('index.range_contains_element_gist', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where r @> :v$q$, setup => '\set v random(0, 100000)', equiv => 'index.range_contains');
call pgmb.reg('index.range_contains_element_spgist', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where r2 @> :v$q$, setup => '\set v random(0, 100000)', equiv => 'index.range_contains');
call pgmb.reg('index.range_contains_element_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where r @> :v$q$ || :'pgmb_ix_end',
    setup => '\set v random(0, 100000)', equiv => 'index.range_contains');
-- the same question as two comparisons, which no index here can answer
call pgmb.reg('index.range_contains_element_as_bounds', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where lower(r) <= :v and upper(r) > :v$q$,
    setup => '\set v random(0, 100000)', equiv => 'index.range_contains');

call pgmb.reg('index.range_overlap_gist', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where r && int4range(:v, :v + 50)$q$,
    setup => '\set v random(0, 100000)', equiv => 'index.range_overlap');
call pgmb.reg('index.range_overlap_spgist', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where r2 && int4range(:v, :v + 50)$q$,
    setup => '\set v random(0, 100000)', equiv => 'index.range_overlap');
call pgmb.reg('index.range_overlap_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where r && int4range(:v, :v + 50)$q$ || :'pgmb_ix_end',
    setup => '\set v random(0, 100000)', equiv => 'index.range_overlap');

call pgmb.reg('index.range_contained_by_gist', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where r <@ int4range(:v, :v + 500)$q$,
    setup => '\set v random(0, 100000)', equiv => 'index.range_contained');
call pgmb.reg('index.range_contained_by_spgist', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where r2 <@ int4range(:v, :v + 500)$q$,
    setup => '\set v random(0, 100000)', equiv => 'index.range_contained');

call pgmb.reg('index.multirange_contains_element_gist', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where mr @> :v$q$, setup => '\set v random(0, 100000)', equiv => 'index.multirange_contains');
call pgmb.reg('index.multirange_contains_element_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where mr @> :v$q$ || :'pgmb_ix_end',
    setup => '\set v random(0, 100000)', equiv => 'index.multirange_contains');

------------------------------------------------------------------------------
-- SP-GiST on text, btree on uuid
------------------------------------------------------------------------------
call pgmb.reg('index.spgist_text_equality', '{perf,planning,consistency,oltp,needs_data}',
    $q$select count(*) from g_types where s = 'Name' || :a$q$, setup => '\set a random(0, 4999)', equiv => 'index.spgist_eq');
call pgmb.reg('index.spgist_text_equality_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where s = 'Name' || :a$q$ || :'pgmb_ix_end',
    setup => '\set a random(0, 4999)', equiv => 'index.spgist_eq');
call pgmb.reg('index.spgist_text_prefix', '{perf,planning,consistency,needs_data}',
    $q$select count(*) from g_types where s ^@ 'Name12'$q$, equiv => 'index.spgist_prefix');
call pgmb.reg('index.spgist_text_prefix_no_index', '{perf,planning,consistency,needs_data}', :'pgmb_noindex' || $q$
select count(*) from g_types where s ^@ 'Name12'$q$ || :'pgmb_ix_end', equiv => 'index.spgist_prefix');

call pgmb.reg('index.uuid_btree_point', '{perf,planning,oltp}',
    $q$select id from g_types where u = md5((:id)::text)::uuid$q$, setup => '\set id random(1, :n_g_types)');
call pgmb.reg('index.uuid_btree_range_ordered', '{perf,planning}',
    $q$select id from g_types where u >= md5((:id)::text)::uuid order by u limit 100$q$,
    setup => '\set id random(1, :n_g_types)');

------------------------------------------------------------------------------
-- btree deduplication
------------------------------------------------------------------------------
-- the two indexes on the three-valued column hold the same entries
call pgmb.reg('index.dedup_makes_index_smaller', '{consistency,needs_data}', $q$
select pg_relation_size('g_types_e_dedup') < pg_relation_size('g_types_e_nodedup')$q$, equiv => 'index.true');
call pgmb.reg('index.expected_true', '{consistency,needs_data}', $q$select true$q$, equiv => 'index.true');

------------------------------------------------------------------------------
-- page splits: where new keys land
------------------------------------------------------------------------------
-- Random keys go to pages all over the index and split them; ascending keys
-- only ever fill the last page. The third table leaves 30% of every leaf free.
call pgmb.reg_ddl('index.create_split_tables', 'schema', $q$
create table g_split_random (k uuid primary key);
create table g_split_random_ff70 (k uuid not null);
create unique index g_split_random_ff70_k on g_split_random_ff70 (k) with (fillfactor = 70);
create table g_split_ascending (k bigserial primary key)$q$);

call pgmb.reg('index.split_insert_100_random_keys', '{perf}',
    $q$insert into g_split_random select gen_random_uuid() from generate_series(1, 100)$q$, kind => 'write');
call pgmb.reg('index.split_insert_100_random_keys_fillfactor_70', '{perf}',
    $q$insert into g_split_random_ff70 select gen_random_uuid() from generate_series(1, 100)$q$, kind => 'write');
call pgmb.reg('index.split_insert_100_ascending_keys', '{perf}',
    $q$insert into g_split_ascending select nextval('g_split_ascending_k_seq') from generate_series(1, 100)$q$, kind => 'write');
