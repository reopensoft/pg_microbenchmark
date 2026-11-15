-- COMMENT ON for every generic table and column: what the initial load puts
-- there. Row counts are given for data_scale = 1. Tests that write change the
-- contents afterwards, mostly in g_parent, g_child, g_dml* and g_part.

call pgmb.reg_ddl('data.comment_g_narrow', 'schema', $q$
comment on table g_narrow is 'Many rows, few columns, one column per value distribution. 1,000,000 rows at scale 1.';
comment on column g_narrow.id     is 'Row number 1 .. n, primary key, matches the physical order after the load';
comment on column g_narrow.k_uniq is 'Unique, n + 1 - id (reverse of id)';
comment on column g_narrow.k_100  is '100 distinct values 0 .. 99, uniform';
comment on column g_narrow.k_10k  is '10,000 distinct values 0 .. 9999, uniform';
comment on column g_narrow.k_skew is '1000 distinct values 0 .. 999, heavily skewed towards 0';
comment on column g_narrow.k_corr is 'id / 10 plus noise 0 .. 9: strongly correlated with the physical order';
comment on column g_narrow.k_null is 'NULL in 50% of the rows, otherwise uniform 0 .. 999';
comment on column g_narrow.ts     is '2020-01-01 UTC plus one second per row, ascending with id';
comment on column g_narrow.pad    is '40 hex characters of filler'$q$);

call pgmb.reg_ddl('data.comment_g_wide', 'schema', $q$
comment on table g_wide is 'Wide rows (about 350 bytes) with integer columns of growing cardinality. 200,000 rows at scale 1.';
comment on column g_wide.id is 'Row number 1 .. n, primary key';
comment on column g_wide.i1 is '2 distinct values, uniform';
comment on column g_wide.i2 is '10 distinct values, uniform';
comment on column g_wide.i3 is '100 distinct values, uniform';
comment on column g_wide.i4 is '1000 distinct values, uniform';
comment on column g_wide.i5 is '10,000 distinct values, uniform';
comment on column g_wide.i6 is '100,000 distinct values, uniform';
comment on column g_wide.i7 is 'Values 0 .. 9999, heavily skewed towards 0';
comment on column g_wide.i8 is 'Uniform over 10^12 values, practically unique';
comment on column g_wide.t1 is '10 hex characters';
comment on column g_wide.t2 is '50 hex characters';
comment on column g_wide.t3 is '200 hex characters';
comment on column g_wide.n1 is 'Amount 0.00 .. 999999.99, uniform';
comment on column g_wide.d1 is 'Date within 9000 days from 2000-01-01, uniform';
comment on column g_wide.b1 is 'true in about one third of the rows'$q$);

call pgmb.reg_ddl('data.comment_g_dim', 'schema', $q$
comment on table g_dim is 'Small dimension referenced by g_parent and g_dml. 1000 rows at scale 1, grows with sqrt(scale).';
comment on column g_dim.id       is 'Row number 1 .. n, primary key';
comment on column g_dim.code     is 'Unique code: D followed by the id padded to 8 digits';
comment on column g_dim.category is '10 distinct values 0 .. 9, uniform';
comment on column g_dim.name     is '"dim " followed by 12 hex characters'$q$);

call pgmb.reg_ddl('data.comment_g_parent', 'schema', $q$
comment on table g_parent is 'Parent side of a 1:N relation with g_child. 100,000 rows at scale 1.';
comment on column g_parent.id         is 'Row number 1 .. n, primary key';
comment on column g_parent.dim_id     is 'Foreign key to g_dim.id, uniform';
comment on column g_parent.grp        is '100 distinct values 0 .. 99, uniform';
comment on column g_parent.status     is '5 distinct values 0 .. 4, skewed towards 0';
comment on column g_parent.name       is '"parent " followed by 16 hex characters';
comment on column g_parent.val        is 'Amount 0.00 .. 9999.99, uniform; incremented by write tests';
comment on column g_parent.updated_at is 'Pseudo-random moment within about 3 years from 2020-01-01; set to now() by write tests'$q$);

call pgmb.reg_ddl('data.comment_g_child', 'schema', $q$
comment on table g_child is 'Child side of the 1:N relation, about 10 rows per parent on average but skewed: low parent ids have many more children. 1,000,000 rows at scale 1; write tests insert and delete rows.';
comment on column g_child.id        is 'Row number 1 .. n, primary key; later rows take values from g_child_id_seq';
comment on column g_child.parent_id is 'Foreign key to g_parent.id, skewed towards low ids';
comment on column g_child.seq       is 'Uniform 0 .. 999 (not unique per parent); 0 in rows inserted by tests';
comment on column g_child.kind      is '8 distinct values 0 .. 7, uniform';
comment on column g_child.amount    is 'Amount 0.00 .. 999.99, uniform';
comment on column g_child.ts        is '2020-01-01 UTC plus 10 seconds per row, ascending with id';
comment on column g_child.note      is '20 hex characters; a short word such as "cte" in rows inserted by tests'$q$);

call pgmb.reg_ddl('data.comment_g_tree', 'schema', $q$
comment on table g_tree is 'Complete 4-ary tree stored as an adjacency list, for recursive queries. 100,000 nodes at scale 1 (deepest level 9).';
comment on column g_tree.id        is 'Node number 1 .. n in breadth-first order, primary key; 1 is the root';
comment on column g_tree.parent_id is 'Parent node, NULL for the root; the children of p are 4p - 2 .. 4p + 1';
comment on column g_tree.depth     is 'Distance from the root, 0 for the root';
comment on column g_tree.val       is 'Uniform 0 .. 999; incremented by write tests';
comment on column g_tree.label     is '"node " followed by 8 hex characters'$q$);

call pgmb.reg_ddl('data.comment_g_graph', 'schema', $q$
comment on table g_graph is 'Directed weighted edges of a cyclic graph with 4 outgoing edges per node. 200,000 edges over 50,000 nodes at scale 1. No primary key; duplicate edges are possible.';
comment on column g_graph.src is 'Source node 1 .. nodes, every node has the same number of outgoing edges';
comment on column g_graph.dst is 'Destination node; the first edge of every node points to the next node, forming one ring through all nodes, the others are pseudo-random';
comment on column g_graph.w   is 'Edge weight 1 .. 100, uniform'$q$);

call pgmb.reg_ddl('data.comment_g_array', 'schema', $q$
comment on table g_array is 'Small and medium arrays of integers and text. 100,000 rows at scale 1.';
comment on column g_array.id      is 'Row number 1 .. n, primary key';
comment on column g_array.a_small is '0 .. 5 integers from 0 .. 999, uniform; about one row in six has an empty array';
comment on column g_array.a_med   is '50 integers from 0 .. 9999, uniform';
comment on column g_array.tags    is '1 .. 4 texts out of tag0 .. tag49, skewed towards tag0'$q$);

call pgmb.reg_ddl('data.comment_g_array_big', 'schema', $q$
comment on table g_array_big is 'Large arrays stored out of line (TOAST). 2000 rows at scale 1.';
comment on column g_array_big.id is 'Row number 1 .. n, primary key';
comment on column g_array_big.a  is '2000 integers from 0 .. 99999, uniform'$q$);

call pgmb.reg_ddl('data.comment_g_events', 'schema', $q$
comment on table g_events is 'Time series: one measurement per second, spread over entities. 1,000,000 rows and 10,000 entities at scale 1.';
comment on column g_events.id        is 'Row number 1 .. n, primary key, ascending with ts';
comment on column g_events.entity_id is 'Entity 1 .. entities, uniform, about 100 events per entity';
comment on column g_events.ts        is '2024-01-01 UTC plus one second per row';
comment on column g_events.val       is 'Measurement, uniform in [0, 1000)';
comment on column g_events.cat       is '5 distinct values 0 .. 4, uniform'$q$);

call pgmb.reg_ddl('data.comment_g_part', 'schema', $q$
comment on table g_part is 'Range-partitioned table with 16 partitions g_part_0 .. g_part_15, one per bucket. 500,000 rows at scale 1. Primary key (bucket, id).';
comment on column g_part.id     is 'Row number 1 .. n, unique across all partitions';
comment on column g_part.bucket is 'Partition key 0 .. 15, a hash of id, so every partition covers the whole id range; changed by row-movement tests';
comment on column g_part.ts     is '2024-01-01 UTC plus one second per row';
comment on column g_part.val    is 'Uniform in [0, 1000); incremented by write tests';
comment on column g_part.pad    is '40 hex characters of filler; "routed" in rows inserted by tests'$q$);

call pgmb.reg_ddl('data.comment_g_dml', 'schema', $q$
comment on table g_dml is 'Scratch table for data-modifying statements with a primary key, a UNIQUE, a CHECK and a FOREIGN KEY. 100,000 rows at scale 1 with ids 1 .. n; tests insert further ids above n.';
comment on column g_dml.id         is 'Primary key; 1 .. n after the load. Tests add n + 1 .. 2n and keys of the form i * 1024 + client_id';
comment on column g_dml.dim_id     is 'Foreign key to g_dim.id, uniform';
comment on column g_dml.code       is 'Unique: "c" followed by the id';
comment on column g_dml.qty        is 'Uniform 0 .. 99 after the load, CHECK (qty >= 0); incremented by tests';
comment on column g_dml.val        is 'Amount 0.00 .. 1000.00, uniform';
comment on column g_dml.updated_at is '2024-01-01 UTC plus one second per row; set to now() by tests';
comment on table g_dml_trig is 'Copy of g_dml (same columns and initial rows, primary key only) with a BEFORE row trigger that sets updated_at and an AFTER row trigger that writes to g_dml_audit.';
comment on column g_dml_trig.id         is 'Primary key, same values as g_dml.id after the load';
comment on column g_dml_trig.dim_id     is 'Same as g_dml.dim_id, without the foreign key';
comment on column g_dml_trig.code       is 'Same as g_dml.code, without the unique constraint';
comment on column g_dml_trig.qty        is 'Same as g_dml.qty, without the check constraint';
comment on column g_dml_trig.val        is 'Same as g_dml.val';
comment on column g_dml_trig.updated_at is 'Overwritten with clock_timestamp() by the BEFORE trigger on every insert and update';
comment on table g_dml_audit is 'Audit rows written by the AFTER trigger on g_dml_trig and directly by tests. Empty after the load, grows during a run.';
comment on column g_dml_audit.id     is 'Identity, primary key';
comment on column g_dml_audit.dml_id is 'Id of the g_dml / g_dml_trig row the entry is about';
comment on column g_dml_audit.action is 'INSERT or UPDATE from the trigger, or a free word chosen by the test that wrote the row';
comment on column g_dml_audit.qty    is 'qty of the row at the time of the entry, may be NULL';
comment on column g_dml_audit.at     is 'Transaction start time of the writer'$q$);

call pgmb.reg_ddl('data.comment_g_intarr', 'schema', $q$
comment on table g_intarr is 'Many numbers in integer[] columns, one column per array length and value distribution. 100,000 rows at scale 1.';
comment on column g_intarr.id            is 'Row number 1 .. n, primary key';
comment on column g_intarr.arr1          is 'Always 1 element, 100 distinct values 0 .. 99, uniform';
comment on column g_intarr.arr1_unique   is 'Always 1 element, unique in the table, in pseudo-random order';
comment on column g_intarr.arr5          is 'Always 5 elements from 0 .. 9999, uniform';
comment on column g_intarr.arr10         is 'Always 10 elements from 0 .. 9999, uniform';
comment on column g_intarr.arr10_lowcard is 'Always 10 elements from 0 .. 19, so values repeat inside one array';
comment on column g_intarr.arr10_skew    is 'Always 10 elements from 0 .. 9999, heavily skewed towards 0';
comment on column g_intarr.arr10_unique  is 'Always 10 elements, every number occurs once in the whole table, ascending: (id - 1) * 10 + 1 .. id * 10';
comment on column g_intarr.arr10_sorted  is 'Always 10 elements from 0 .. 99999, uniform, sorted ascending';
comment on column g_intarr.arr_var       is '0 .. 20 elements from 0 .. 999, uniform; empty arrays included';
comment on column g_intarr.arr_nulls     is '5 elements from 0 .. 999 of which about 20% are NULL; the column itself is NULL in about 5% of the rows';
comment on column g_intarr.arr100        is 'Always 100 elements from 0 .. 99999, uniform';
comment on column g_intarr.arr_n         is 'arr_len elements from 0 .. arr_distinct - 1, uniform (run variables, default 20 and 1000)'$q$);

call pgmb.reg_ddl('data.comment_g_dml_defer', 'schema', $q$
comment on table g_dml_defer is 'Copy of g_dml (same columns and initial rows) whose UNIQUE (code) and FOREIGN KEY (dim_id) are DEFERRABLE INITIALLY IMMEDIATE. Ids 1 .. n/2 are reserved for per-client lock tests, the upper half for tests that swap values.';
comment on column g_dml_defer.id         is 'Primary key, 1 .. n';
comment on column g_dml_defer.dim_id     is 'Deferrable foreign key to g_dim.id; rotated by tests';
comment on column g_dml_defer.code       is 'Deferrable unique: "c" followed by a number; tests swap the codes of neighbouring rows, so it stops matching the id';
comment on column g_dml_defer.qty        is 'Same as g_dml.qty, without the check constraint';
comment on column g_dml_defer.val        is 'Same as g_dml.val';
comment on column g_dml_defer.updated_at is 'Same as g_dml.updated_at'$q$);

call pgmb.reg_ddl('data.comment_g_rls', 'schema', $q$
comment on table g_rls is 'Table with row level security: a role other than the owner sees and updates only the rows whose tenant equals the setting pgmb.tenant. 100,000 rows and 100 tenants at scale 1. Used by the cte.rls_* tests, registered only with -v rls_role=...';
comment on column g_rls.id     is 'Row number 1 .. n, primary key';
comment on column g_rls.tenant is 'id % 100: the tenant the row belongs to, compared with current_setting(''pgmb.tenant'') by the policies';
comment on column g_rls.grp    is '100 distinct values 0 .. 99, uniform, independent of tenant';
comment on column g_rls.val    is 'Amount 0.00 .. 9999.99, uniform; the update policy also requires val >= 0';
comment on column g_rls.note   is '20 hex characters'$q$);

\if :pgmb_has_intarray
call pgmb.reg_ddl('data.comment_g_ia_dml', 'schema', $q$
comment on table g_ia_dml is 'Scratch table for writes to integer[] columns (only with intarray=1): the same 10-element array stored three times under different indexes, a large array and a counter. 20,000 rows at scale 1, fillfactor 70. Ids 1 .. n after the load; tests insert and delete ids n+1 .. 2n.';
comment on column g_ia_dml.id      is 'Primary key';
comment on column g_ia_dml.a_gin   is '10 integers from 0 .. 99 after the load (same as a_gist and a_plain), indexed with GIN gin__int_ops; tests add and remove elements';
comment on column g_ia_dml.a_gist  is 'Same initial array, indexed with GiST gist__int_ops';
comment on column g_ia_dml.a_plain is 'Same initial array, not indexed, so updates of it can be HOT';
comment on column g_ia_dml.a_big   is '500 integers from 0 .. 99999, not indexed, stored out of line';
comment on column g_ia_dml.n       is 'Counter, 0 after the load, not indexed'$q$);
\endif
