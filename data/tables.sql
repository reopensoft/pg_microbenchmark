-- Generic data set. Tables are named after their shape, not after a domain.
-- Every statement is one timed DDL step. :n_<name> expands to a row count.

insert into pgmb.dataset (name, base_rows, exponent, min_rows) values
    ('g_narrow',          1000000, 1,   1000),  -- many rows, few columns, varied distributions
    ('g_wide',             200000, 1,   1000),  -- wide rows
    ('g_dim',                1000, 0.5,   10),  -- small dimension, grows with sqrt(scale)
    ('g_parent',           100000, 1,    100),  -- 1:N parent
    ('g_child',           1000000, 1,   1000),  -- 1:N child, ~10 per parent, skewed
    ('g_tree',             100000, 1,    100),  -- 4-ary tree, adjacency list
    ('g_graph',            200000, 1,    400),  -- directed edges, cyclic
    ('g_graph_nodes',       50000, 1,    100),  -- (not a table) node count of g_graph
    ('g_array',            100000, 1,    500),  -- small and medium arrays
    ('g_array_big',          2000, 1,     20),  -- 2000-element arrays
    ('g_events',          1000000, 1,   1000),  -- time series
    ('g_events_entities',   10000, 1,     10);  -- (not a table) entity count of g_events

------------------------------------------------------------------------------
-- schema
------------------------------------------------------------------------------
call pgmb.reg_ddl('data.create_g_narrow', 'schema', $q$
create table g_narrow (
    id     bigint not null,
    k_uniq bigint not null,        -- unique, reverse of id
    k_100  int    not null,        -- 100 distinct, uniform
    k_10k  int    not null,        -- 10000 distinct, uniform
    k_skew int    not null,        -- 1000 distinct, heavily skewed towards 0
    k_corr bigint not null,        -- strongly correlated with physical order
    k_null int,                    -- 50% NULL
    ts     timestamptz not null,   -- one second per row
    pad    text   not null         -- 40 hex chars
)$q$);

call pgmb.reg_ddl('data.create_g_wide', 'schema', $q$
create table g_wide (
    id bigint not null,
    i1 int not null,               -- 2 distinct
    i2 int not null,               -- 10
    i3 int not null,               -- 100
    i4 int not null,               -- 1000
    i5 int not null,               -- 10000
    i6 int not null,               -- 100000
    i7 int not null,               -- skewed
    i8 bigint not null,            -- ~unique
    t1 text not null,              -- 10 chars
    t2 text not null,              -- 50 chars
    t3 text not null,              -- 200 chars
    n1 numeric(12,2) not null,
    d1 date not null,
    b1 boolean not null
)$q$);

call pgmb.reg_ddl('data.create_g_dim', 'schema', $q$
create table g_dim (
    id       int  not null,
    code     text not null,
    category int  not null,
    name     text not null
)$q$);

call pgmb.reg_ddl('data.create_g_parent', 'schema', $q$
create table g_parent (
    id         bigint not null,
    dim_id     int    not null,
    grp        int    not null,    -- 100 distinct
    status     smallint not null,  -- 5 distinct, skewed
    name       text   not null,
    val        numeric(14,2) not null,
    updated_at timestamptz not null
)$q$);

call pgmb.reg_ddl('data.create_g_child_seq', 'schema', $q$create sequence g_child_id_seq$q$);

call pgmb.reg_ddl('data.create_g_child', 'schema', $q$
create table g_child (
    id        bigint not null default nextval('g_child_id_seq'),
    parent_id bigint not null,
    seq       int    not null,
    kind      smallint not null,   -- 8 distinct
    amount    numeric(12,2) not null,
    ts        timestamptz not null,
    note      text   not null
)$q$);

call pgmb.reg_ddl('data.create_g_tree', 'schema', $q$
create table g_tree (
    id        bigint not null,
    parent_id bigint,              -- NULL for the root (id 1); children of p are 4p-2 .. 4p+1
    depth     int    not null,
    val       int    not null,
    label     text   not null
)$q$);

call pgmb.reg_ddl('data.create_g_graph', 'schema', $q$
create table g_graph (
    src bigint not null,
    dst bigint not null,
    w   int    not null
)$q$);

call pgmb.reg_ddl('data.create_g_array', 'schema', $q$
create table g_array (
    id      bigint not null,
    a_small int[]  not null,       -- 0..5 elements from 0..999
    a_med   int[]  not null,       -- 50 elements from 0..9999
    tags    text[] not null        -- 1..4 of tag0..tag49
)$q$);

call pgmb.reg_ddl('data.create_g_array_big', 'schema', $q$
create table g_array_big (
    id bigint not null,
    a  int[]  not null             -- 2000 elements from 0..99999
)$q$);

call pgmb.reg_ddl('data.create_g_events', 'schema', $q$
create table g_events (
    id        bigint not null,
    entity_id int    not null,     -- ~100 events per entity
    ts        timestamptz not null,
    val       double precision not null,
    cat       smallint not null    -- 5 distinct
)$q$);

------------------------------------------------------------------------------
-- load (generation happens inside the server; its cost is part of the result)
------------------------------------------------------------------------------
call pgmb.reg_ddl('data.load_g_narrow', 'load', $q$
insert into g_narrow
select i, :n_g_narrow + 1 - i,
       pgmb.hu(i, 2, 100), pgmb.hu(i, 3, 10000), pgmb.hskew(i, 4, 1000),
       i / 10 + pgmb.hu(i, 5, 10),
       case when pgmb.hu(i, 6, 2) = 0 then pgmb.hu(i, 7, 1000) end,
       timestamptz '2020-01-01 00:00:00+00' + i * interval '1 second',
       pgmb.htext(i, 8, 40)
from generate_series(1, :n_g_narrow) i$q$, target => 'g_narrow');

call pgmb.reg_ddl('data.load_g_wide', 'load', $q$
insert into g_wide
select i, pgmb.hu(i, 1, 2), pgmb.hu(i, 2, 10), pgmb.hu(i, 3, 100), pgmb.hu(i, 4, 1000),
       pgmb.hu(i, 5, 10000), pgmb.hu(i, 6, 100000), pgmb.hskew(i, 7, 10000), pgmb.hu(i, 8, 1000000000000),
       pgmb.htext(i, 9, 10), pgmb.htext(i, 10, 50), pgmb.htext(i, 11, 200),
       pgmb.hu(i, 12, 100000000) / 100.0,
       date '2000-01-01' + pgmb.hu(i, 13, 9000)::int,
       pgmb.hu(i, 14, 3) = 0
from generate_series(1, :n_g_wide) i$q$, target => 'g_wide');

call pgmb.reg_ddl('data.load_g_dim', 'load', $q$
insert into g_dim
select i, 'D' || lpad(i::text, 8, '0'), pgmb.hu(i, 1, 10), 'dim ' || pgmb.htext(i, 2, 12)
from generate_series(1, :n_g_dim) i$q$, target => 'g_dim');

call pgmb.reg_ddl('data.load_g_parent', 'load', $q$
insert into g_parent
select i, 1 + pgmb.hu(i, 1, :n_g_dim), pgmb.hu(i, 2, 100), pgmb.hskew(i, 3, 5),
       'parent ' || pgmb.htext(i, 4, 16), pgmb.hu(i, 5, 1000000) / 100.0,
       timestamptz '2020-01-01 00:00:00+00' + pgmb.hu(i, 6, 100000000) * interval '1 second'
from generate_series(1, :n_g_parent) i$q$, target => 'g_parent');

call pgmb.reg_ddl('data.load_g_child', 'load', $q$
insert into g_child
select i, 1 + floor(:n_g_parent * power(pgmb.hf(i, 1), 1.5))::bigint,
       pgmb.hu(i, 2, 1000), pgmb.hu(i, 3, 8), pgmb.hu(i, 4, 100000) / 100.0,
       timestamptz '2020-01-01 00:00:00+00' + i * interval '10 seconds',
       pgmb.htext(i, 5, 20)
from generate_series(1, :n_g_child) i$q$, target => 'g_child');

call pgmb.reg_ddl('data.load_g_tree', 'load', $q$
insert into g_tree
select i, case when i > 1 then (i + 2) / 4 end,
       floor(ln((3 * i - 1.5)::double precision) / ln(4::double precision))::int,
       pgmb.hu(i, 1, 1000), 'node ' || pgmb.htext(i, 2, 8)
from generate_series(1, :n_g_tree) i$q$, target => 'g_tree');

-- The first n_g_graph_nodes edges form a ring (guaranteed cycle), the rest are pseudo-random.
call pgmb.reg_ddl('data.load_g_graph', 'load', $q$
insert into g_graph
select 1 + (i - 1) % :n_g_graph_nodes,
       case when i <= :n_g_graph_nodes then 1 + i % :n_g_graph_nodes
            else 1 + pgmb.hu(i, 1, :n_g_graph_nodes) end,
       1 + pgmb.hu(i, 2, 100)
from generate_series(1, :n_g_graph) i$q$, target => 'g_graph');

call pgmb.reg_ddl('data.load_g_array', 'load', $q$
insert into g_array
select i,
       array(select pgmb.hu(i * 8 + k, 11, 1000)::int from generate_series(1, pgmb.hu(i, 10, 6)::int) k),
       array(select pgmb.hu(i * 64 + k, 12, 10000)::int from generate_series(1, 50) k),
       array(select 'tag' || pgmb.hskew(i * 8 + k, 14, 50) from generate_series(1, 1 + pgmb.hu(i, 13, 4)::int) k)
from generate_series(1, :n_g_array) i$q$, target => 'g_array');

call pgmb.reg_ddl('data.load_g_array_big', 'load', $q$
insert into g_array_big
select i, array(select pgmb.hu(i * 4096 + k, 1, 100000)::int from generate_series(1, 2000) k)
from generate_series(1, :n_g_array_big) i$q$, target => 'g_array_big');

call pgmb.reg_ddl('data.load_g_events', 'load', $q$
insert into g_events
select i, 1 + pgmb.hu(i, 1, :n_g_events_entities),
       timestamptz '2024-01-01 00:00:00+00' + i * interval '1 second',
       pgmb.hf(i, 2) * 1000, pgmb.hu(i, 3, 5)
from generate_series(1, :n_g_events) i$q$, target => 'g_events');

------------------------------------------------------------------------------
-- primary keys and foreign keys (index build + validation time)
------------------------------------------------------------------------------
call pgmb.reg_ddl('data.pk_g_narrow',    'constraint', $q$alter table g_narrow    add primary key (id)$q$, target => 'g_narrow_pkey');
call pgmb.reg_ddl('data.pk_g_wide',      'constraint', $q$alter table g_wide      add primary key (id)$q$, target => 'g_wide_pkey');
call pgmb.reg_ddl('data.pk_g_dim',       'constraint', $q$alter table g_dim       add primary key (id)$q$, target => 'g_dim_pkey');
call pgmb.reg_ddl('data.pk_g_parent',    'constraint', $q$alter table g_parent    add primary key (id)$q$, target => 'g_parent_pkey');
call pgmb.reg_ddl('data.pk_g_child',     'constraint', $q$alter table g_child     add primary key (id)$q$, target => 'g_child_pkey');
call pgmb.reg_ddl('data.pk_g_tree',      'constraint', $q$alter table g_tree      add primary key (id)$q$, target => 'g_tree_pkey');
call pgmb.reg_ddl('data.pk_g_array',     'constraint', $q$alter table g_array     add primary key (id)$q$, target => 'g_array_pkey');
call pgmb.reg_ddl('data.pk_g_array_big', 'constraint', $q$alter table g_array_big add primary key (id)$q$, target => 'g_array_big_pkey');
call pgmb.reg_ddl('data.pk_g_events',    'constraint', $q$alter table g_events    add primary key (id)$q$, target => 'g_events_pkey');

call pgmb.reg_ddl('data.fk_g_parent_dim', 'constraint',
    $q$alter table g_parent add constraint g_parent_dim_fk foreign key (dim_id) references g_dim$q$);
call pgmb.reg_ddl('data.fk_g_child_parent', 'constraint',
    $q$alter table g_child add constraint g_child_parent_fk foreign key (parent_id) references g_parent$q$);
call pgmb.reg_ddl('data.fk_g_tree_parent', 'constraint',
    $q$alter table g_tree add constraint g_tree_parent_fk foreign key (parent_id) references g_tree$q$);

------------------------------------------------------------------------------
-- maintenance
------------------------------------------------------------------------------
call pgmb.reg_ddl('data.seq_g_child', 'maintenance',
    $q$do $do$ begin perform setval('pgmb_data.g_child_id_seq', (select max(id) from pgmb_data.g_child)); end $do$$q$);

call pgmb.reg_ddl('data.vacuum_g_narrow',    'maintenance', $q$vacuum (analyze) g_narrow$q$);
call pgmb.reg_ddl('data.vacuum_g_wide',      'maintenance', $q$vacuum (analyze) g_wide$q$);
call pgmb.reg_ddl('data.vacuum_g_dim',       'maintenance', $q$vacuum (analyze) g_dim$q$);
call pgmb.reg_ddl('data.vacuum_g_parent',    'maintenance', $q$vacuum (analyze) g_parent$q$);
call pgmb.reg_ddl('data.vacuum_g_child',     'maintenance', $q$vacuum (analyze) g_child$q$);
call pgmb.reg_ddl('data.vacuum_g_tree',      'maintenance', $q$vacuum (analyze) g_tree$q$);
call pgmb.reg_ddl('data.vacuum_g_graph',     'maintenance', $q$vacuum (analyze) g_graph$q$);
call pgmb.reg_ddl('data.vacuum_g_array',     'maintenance', $q$vacuum (analyze) g_array$q$);
call pgmb.reg_ddl('data.vacuum_g_array_big', 'maintenance', $q$vacuum (analyze) g_array_big$q$);
call pgmb.reg_ddl('data.vacuum_g_events',    'maintenance', $q$vacuum (analyze) g_events$q$);

------------------------------------------------------------------------------
-- g_part: range-partitioned table, 16 partitions by bucket (hash of the row
-- number, so every partition holds rows from the whole id range)
------------------------------------------------------------------------------
insert into pgmb.dataset (name, base_rows, exponent, min_rows) values ('g_part', 500000, 1, 1600);

call pgmb.reg_ddl('data.create_g_part', 'schema', $q$
create table g_part (
    id     bigint not null,
    bucket int    not null,        -- partition key, 0..15
    ts     timestamptz not null,
    val    double precision not null,
    pad    text   not null
) partition by range (bucket)$q$);

call pgmb.reg_ddl('data.create_g_part_partitions', 'schema', $q$
do $do$
begin
    for b in 0 .. 15 loop
        execute format('create table pgmb_data.g_part_%s partition of pgmb_data.g_part for values from (%s) to (%s)', b, b, b + 1);
    end loop;
end $do$$q$);

call pgmb.reg_ddl('data.load_g_part', 'load', $q$
insert into g_part
select i, pgmb.hu(i, 1, 16),
       timestamptz '2024-01-01 00:00:00+00' + i * interval '1 second',
       pgmb.hf(i, 2) * 1000, pgmb.htext(i, 3, 40)
from generate_series(1, :n_g_part) i$q$, target => 'g_part');

call pgmb.reg_ddl('data.pk_g_part', 'constraint', $q$alter table g_part add primary key (bucket, id)$q$);
call pgmb.reg_ddl('data.vacuum_g_part', 'maintenance', $q$vacuum (analyze) g_part$q$);

------------------------------------------------------------------------------
-- g_dml: scratch tables for data-modifying statements. g_dml carries a primary
-- key, a UNIQUE, a CHECK and a FOREIGN KEY; g_dml_trig is the same table with
-- BEFORE and AFTER row triggers; g_dml_audit receives the trigger output.
-- Ids 1 .. n exist after the load; tests that insert use ids n+1 .. 2n, or
-- ids of the form i * 1024 + :client_id where concurrent clients must not collide.
------------------------------------------------------------------------------
insert into pgmb.dataset (name, base_rows, exponent, min_rows) values ('g_dml', 100000, 1, 100);

call pgmb.reg_ddl('data.create_g_dml', 'schema', $q$
create table g_dml (
    id         bigint not null,
    dim_id     int    not null,
    code       text   not null,
    qty        int    not null,
    val        numeric(14,2) not null,
    updated_at timestamptz not null
)$q$);
call pgmb.reg_ddl('data.create_g_dml_trig', 'schema', $q$create table g_dml_trig (like g_dml)$q$);
call pgmb.reg_ddl('data.create_g_dml_audit', 'schema', $q$
create table g_dml_audit (
    id      bigint generated always as identity,
    dml_id  bigint not null,
    action  text   not null,
    qty     int,
    at      timestamptz not null default now()
)$q$);
call pgmb.reg_ddl('data.create_g_dml_trig_functions', 'schema', $q$
create function g_dml_before() returns trigger language plpgsql as
'begin new.updated_at := clock_timestamp(); return new; end';
create function g_dml_after() returns trigger language plpgsql as
'begin insert into pgmb_data.g_dml_audit (dml_id, action, qty) values (new.id, tg_op, new.qty); return null; end'$q$);

call pgmb.reg_ddl('data.load_g_dml', 'load', $q$
insert into g_dml
select i, 1 + pgmb.hu(i, 1, :n_g_dim), 'c' || i, pgmb.hu(i, 2, 100), round((pgmb.hf(i, 3) * 1000)::numeric, 2),
       timestamptz '2024-01-01 00:00:00+00' + i * interval '1 second'
from generate_series(1, :n_g_dml) i$q$, target => 'g_dml');
call pgmb.reg_ddl('data.load_g_dml_trig', 'load', $q$insert into g_dml_trig select * from g_dml$q$, target => 'g_dml_trig');

call pgmb.reg_ddl('data.pk_g_dml',      'constraint', $q$alter table g_dml      add primary key (id)$q$, target => 'g_dml_pkey');
call pgmb.reg_ddl('data.pk_g_dml_trig', 'constraint', $q$alter table g_dml_trig add primary key (id)$q$, target => 'g_dml_trig_pkey');
call pgmb.reg_ddl('data.pk_g_dml_audit', 'constraint', $q$alter table g_dml_audit add primary key (id)$q$, target => 'g_dml_audit_pkey');
call pgmb.reg_ddl('data.uq_g_dml_code', 'constraint', $q$alter table g_dml add constraint g_dml_code_uq unique (code)$q$, target => 'g_dml_code_uq');
call pgmb.reg_ddl('data.ck_g_dml_qty',  'constraint', $q$alter table g_dml add constraint g_dml_qty_ck check (qty >= 0)$q$);
call pgmb.reg_ddl('data.fk_g_dml_dim',  'constraint', $q$alter table g_dml add constraint g_dml_dim_fk foreign key (dim_id) references g_dim$q$);
call pgmb.reg_ddl('data.ix_g_dml_audit', 'constraint', $q$create index g_dml_audit_dml_id on g_dml_audit (dml_id)$q$, target => 'g_dml_audit_dml_id');
call pgmb.reg_ddl('data.triggers_g_dml_trig', 'constraint', $q$
create trigger g_dml_trig_before before insert or update on g_dml_trig for each row execute function g_dml_before();
create trigger g_dml_trig_after after insert or update on g_dml_trig for each row execute function g_dml_after()$q$);

call pgmb.reg_ddl('data.vacuum_g_dml',      'maintenance', $q$vacuum (analyze) g_dml$q$);
call pgmb.reg_ddl('data.vacuum_g_dml_trig', 'maintenance', $q$vacuum (analyze) g_dml_trig$q$);

------------------------------------------------------------------------------
-- g_intarr: many numbers in integer[] columns, one column per shape.
--   arr1           1 element, 100 distinct values
--   arr1_unique    1 element, unique in the table, in pseudo-random order
--   arr5           5 elements, uniform over 10000 values
--   arr10          10 elements, uniform over 10000 values
--   arr10_lowcard  10 elements over 20 values (duplicates inside the array)
--   arr10_skew     10 elements over 10000 values, skewed towards small ones
--   arr10_unique   10 elements, every number unique in the table, ascending
--   arr10_sorted   10 elements, uniform over 100000 values, ascending
--   arr_var        0 .. 20 elements over 1000 values (empty arrays included)
--   arr_nulls      5 elements with about 20% NULL elements; the whole column
--                  is NULL in about 5% of the rows
--   arr100         100 elements, uniform over 100000 values
--   arr_n          :arr_len elements over :arr_distinct values (run variables)
-- The two variables are registered as datasets with exponent 0, so tests can
-- use :n_g_intarr_len and :n_g_intarr_distinct like any row count.
------------------------------------------------------------------------------
insert into pgmb.dataset (name, base_rows, exponent, min_rows) values
    ('g_intarr',          100000, 1, 500),
    ('g_intarr_len',      greatest(:'arr_len'::int, 0), 0, 0),       -- (not a table) length of arr_n
    ('g_intarr_distinct', greatest(:'arr_distinct'::int, 1), 0, 1);  -- (not a table) value domain of arr_n

call pgmb.reg_ddl('data.create_g_intarr', 'schema', $q$
create table g_intarr (
    id            integer   not null,
    arr1          integer[] not null,
    arr1_unique   integer[] not null,
    arr5          integer[] not null,
    arr10         integer[] not null,
    arr10_lowcard integer[] not null,
    arr10_skew    integer[] not null,
    arr10_unique  integer[] not null,
    arr10_sorted  integer[] not null,
    arr_var       integer[] not null,
    arr_nulls     integer[],
    arr100        integer[] not null,
    arr_n         integer[] not null
)$q$);

call pgmb.reg_ddl('data.load_g_intarr', 'load', $q$
insert into g_intarr
select i,
       array[pgmb.hu(i, 21, 100)::int],
       array[(i::bigint * 2654435761 % 2147483647)::int],
       array(select pgmb.hu(i::bigint * 128 + k, 22, 10000)::int from generate_series(1, 5) k),
       array(select pgmb.hu(i::bigint * 128 + k, 23, 10000)::int from generate_series(1, 10) k),
       array(select pgmb.hu(i::bigint * 128 + k, 24, 20)::int from generate_series(1, 10) k),
       array(select pgmb.hskew(i::bigint * 128 + k, 25, 10000)::int from generate_series(1, 10) k),
       array(select (i - 1) * 10 + k from generate_series(1, 10) k),
       array(select v from (select pgmb.hu(i::bigint * 128 + k, 26, 100000)::int as v from generate_series(1, 10) k) s order by v),
       array(select pgmb.hu(i::bigint * 128 + k, 28, 1000)::int from generate_series(1, pgmb.hu(i, 27, 21)::int) k),
       case when pgmb.hu(i, 29, 20) = 0 then null
            else array(select case when pgmb.hu(i::bigint * 128 + k, 30, 5) = 0 then null
                                   else pgmb.hu(i::bigint * 128 + k, 31, 1000)::int end
                       from generate_series(1, 5) k) end,
       array(select pgmb.hu(i::bigint * 128 + k, 32, 100000)::int from generate_series(1, 100) k),
       array(select pgmb.hu(i::bigint * 65536 + k, 33, :n_g_intarr_distinct)::int from generate_series(1, :n_g_intarr_len) k)
from generate_series(1, :n_g_intarr) i$q$, target => 'g_intarr');

call pgmb.reg_ddl('data.pk_g_intarr', 'constraint', $q$alter table g_intarr add primary key (id)$q$, target => 'g_intarr_pkey');
call pgmb.reg_ddl('data.vacuum_g_intarr', 'maintenance', $q$vacuum (analyze) g_intarr$q$);

-- g_dml_defer: copy of g_dml whose UNIQUE and FOREIGN KEY are DEFERRABLE
-- INITIALLY IMMEDIATE. Rows 1 .. n/2 are reserved for per-client lock tests,
-- the upper half is used by tests that swap values.
call pgmb.reg_ddl('data.create_g_dml_defer', 'schema', $q$create table g_dml_defer (like g_dml)$q$);
call pgmb.reg_ddl('data.load_g_dml_defer', 'load', $q$insert into g_dml_defer select * from g_dml$q$, target => 'g_dml_defer');
call pgmb.reg_ddl('data.pk_g_dml_defer', 'constraint', $q$alter table g_dml_defer add primary key (id)$q$, target => 'g_dml_defer_pkey');
call pgmb.reg_ddl('data.uq_g_dml_defer_code', 'constraint',
    $q$alter table g_dml_defer add constraint g_dml_defer_code_uq unique (code) deferrable initially immediate$q$, target => 'g_dml_defer_code_uq');
call pgmb.reg_ddl('data.fk_g_dml_defer_dim', 'constraint',
    $q$alter table g_dml_defer add constraint g_dml_defer_dim_fk foreign key (dim_id) references g_dim deferrable initially immediate$q$);
call pgmb.reg_ddl('data.vacuum_g_dml_defer', 'maintenance', $q$vacuum (analyze) g_dml_defer$q$);

------------------------------------------------------------------------------
-- g_rls: table with row level security. 100 tenants; a session sees the rows
-- of the tenant named in the setting pgmb.tenant. Policies apply to every role
-- except the table owner and superusers, so the tests read it through the role
-- given as -v rls_role=... (see rls_role.sql). Without that variable the table
-- is loaded but no RLS test is registered.
------------------------------------------------------------------------------
insert into pgmb.dataset (name, base_rows, exponent, min_rows) values ('g_rls', 100000, 1, 1000);

call pgmb.reg_ddl('data.create_g_rls', 'schema', $q$
create table g_rls (
    id     bigint not null,
    tenant int    not null,        -- id % 100
    grp    int    not null,        -- 100 distinct
    val    numeric(14,2) not null,
    note   text   not null
)$q$);

call pgmb.reg_ddl('data.load_g_rls', 'load', $q$
insert into g_rls
select i, i % 100, pgmb.hu(i, 1, 100), pgmb.hu(i, 2, 1000000) / 100.0, pgmb.htext(i, 3, 20)
from generate_series(1, :n_g_rls) i$q$, target => 'g_rls');

call pgmb.reg_ddl('data.pk_g_rls', 'constraint', $q$alter table g_rls add primary key (id)$q$, target => 'g_rls_pkey');
call pgmb.reg_ddl('data.ix_g_rls_tenant', 'constraint', $q$create index g_rls_tenant_id on g_rls (tenant, id)$q$, target => 'g_rls_tenant_id');
call pgmb.reg_ddl('data.policies_g_rls', 'constraint', $q$
alter table g_rls enable row level security;
create policy g_rls_read on g_rls for select
    using (tenant = current_setting('pgmb.tenant')::int);
create policy g_rls_write on g_rls for update
    using (tenant = current_setting('pgmb.tenant')::int)
    with check (tenant = current_setting('pgmb.tenant')::int and val >= 0)$q$);
call pgmb.reg_ddl('data.vacuum_g_rls', 'maintenance', $q$vacuum (analyze) g_rls$q$);

------------------------------------------------------------------------------
-- intarray (optional, -v intarray=1): the extension's functions and operators
-- for integer[]. It is installed into its own schema, pgmb_intarray, which is
-- NOT on the search_path: once its operators are visible, "integer[] @> integer[]"
-- resolves to them instead of the built-in ones and the default GIN indexes stop
-- matching, which would change every other array test. Tests name the schema
-- explicitly. If the database already has intarray somewhere else, that schema
-- is used; pgmb.ia() rewrites "pgmb_intarray" in the test text accordingly.
-- intarray is a trusted extension: CREATE on the database is enough.
------------------------------------------------------------------------------
select :'intarray' = '1' as pgmb_has_intarray \gset
\if :pgmb_has_intarray
    select coalesce((select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace
                     where e.extname = 'intarray'), '') as pgmb_ia_schema \gset
    select :'pgmb_ia_schema' = '' as pgmb_ia_missing \gset
    \if :pgmb_ia_missing
        do $$
        begin
            if not exists (select from pg_available_extensions where name = 'intarray') then
                raise exception 'intarray=1 needs the intarray extension (package postgresql-contrib) on the server';
            end if;
        end $$;
        \set pgmb_ia_schema pgmb_intarray
        call pgmb.reg_ddl('data.create_extension_intarray', 'schema',
            $q$create schema if not exists pgmb_intarray; create extension intarray schema pgmb_intarray$q$);
    \endif
    select set_config('pgmb.intarray_schema', :'pgmb_ia_schema', false) \gset pgmb_ignore_
    create function pgmb.ia(p_sql text) returns text stable language sql
    return replace(p_sql, 'pgmb_intarray', quote_ident(current_setting('pgmb.intarray_schema')));

    -- g_ia_dml: scratch table for writes to integer[] columns, three copies of
    -- the same 10-element arrays (values 0 .. 99) under different indexes, one
    -- large array and a plain counter. fillfactor 70 leaves room for HOT updates.
    -- Ids 1 .. n exist after the load; tests insert and delete ids n+1 .. 2n.
    insert into pgmb.dataset (name, base_rows, exponent, min_rows) values ('g_ia_dml', 20000, 1, 200);
    call pgmb.reg_ddl('data.create_g_ia_dml', 'schema', $q$
create table g_ia_dml (
    id      integer   not null,
    a_gin   integer[] not null,    -- GIN gin__int_ops
    a_gist  integer[] not null,    -- GiST gist__int_ops
    a_plain integer[] not null,    -- no index
    a_big   integer[] not null,    -- 500 elements, no index
    n       integer   not null     -- counter, no index
) with (fillfactor = 70)$q$);
    call pgmb.reg_ddl('data.load_g_ia_dml', 'load', $q$
insert into g_ia_dml
select i, a, a, a, array(select pgmb.hu(i::bigint * 1024 + k, 42, 100000)::int from generate_series(1, 500) k), 0
from generate_series(1, :n_g_ia_dml) i,
     lateral (select array(select pgmb.hu(i::bigint * 128 + k, 41, 100)::int from generate_series(1, 10) k) as a) s$q$, target => 'g_ia_dml');
    call pgmb.reg_ddl('data.pk_g_ia_dml', 'constraint', $q$alter table g_ia_dml add primary key (id)$q$, target => 'g_ia_dml_pkey');
    call pgmb.reg_ddl('data.ix_g_ia_dml_gin', 'constraint', pgmb.ia($q$create index g_ia_dml_gin on g_ia_dml using gin (a_gin pgmb_intarray.gin__int_ops)$q$), target => 'g_ia_dml_gin');
    call pgmb.reg_ddl('data.ix_g_ia_dml_gist', 'constraint', pgmb.ia($q$create index g_ia_dml_gist on g_ia_dml using gist (a_gist pgmb_intarray.gist__int_ops)$q$), target => 'g_ia_dml_gist');
    call pgmb.reg_ddl('data.vacuum_g_ia_dml', 'maintenance', $q$vacuum (analyze) g_ia_dml$q$);

    -- runs one statement with the extension's schema on the search_path; used
    -- where name resolution itself is the subject and one statement is needed
    call pgmb.reg_ddl('data.create_ia_on_path', 'schema', pgmb.ia($q$
create function ia_on_path(p_sql text) returns bigint language plpgsql
set search_path = pgmb_data, pgmb, pgmb_intarray, public as
'declare n bigint; begin execute p_sql into n; return n; end'$q$));
\endif
