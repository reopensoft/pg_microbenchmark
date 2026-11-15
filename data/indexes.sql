-- Secondary indexes. Each build is a timed step of the "index" topic;
-- the read tests in topics/index.sql (and others) rely on them.

-- btree variants on g_narrow
call pgmb.reg_ddl('index.btree_unique',     'index', $q$create unique index g_narrow_k_uniq on g_narrow (k_uniq)$q$,                         target => 'g_narrow_k_uniq');
call pgmb.reg_ddl('index.btree_multi',      'index', $q$create index g_narrow_k100_k10k on g_narrow (k_100, k_10k)$q$,                       target => 'g_narrow_k100_k10k');
call pgmb.reg_ddl('index.btree_include',    'index', $q$create index g_narrow_k10k_incl on g_narrow (k_10k) include (k_100)$q$,              target => 'g_narrow_k10k_incl');
call pgmb.reg_ddl('index.btree_partial',    'index', $q$create index g_narrow_skew_part on g_narrow (k_skew) where k_null is not null$q$,    target => 'g_narrow_skew_part');
call pgmb.reg_ddl('index.btree_expression', 'index', $q$create index g_narrow_expr on g_narrow ((k_uniq % 1000))$q$,                         target => 'g_narrow_expr');
call pgmb.reg_ddl('index.btree_text_pattern','index', $q$create index g_narrow_pad on g_narrow (pad text_pattern_ops)$q$,                    target => 'g_narrow_pad');
call pgmb.reg_ddl('index.btree_desc_nulls', 'index', $q$create index g_narrow_null_desc on g_narrow (k_null desc nulls last, id)$q$,         target => 'g_narrow_null_desc');
call pgmb.reg_ddl('index.brin_ts',          'index', $q$create index g_narrow_ts_brin on g_narrow using brin (ts)$q$,                        target => 'g_narrow_ts_brin');
call pgmb.reg_ddl('index.brin_corr',        'index', $q$create index g_narrow_corr_brin on g_narrow using brin (k_corr) with (pages_per_range = 16)$q$, target => 'g_narrow_corr_brin');

-- g_wide: three-column btree without an index on the trailing columns (skip scan), hash
call pgmb.reg_ddl('index.btree_3col',       'index', $q$create index g_wide_i3_i4_i5 on g_wide (i3, i4, i5)$q$,                              target => 'g_wide_i3_i4_i5');
call pgmb.reg_ddl('index.hash',             'index', $q$create index g_wide_i6_hash on g_wide using hash (i6)$q$,                            target => 'g_wide_i6_hash');

-- GIN on arrays
call pgmb.reg_ddl('index.gin_small',        'index', $q$create index g_array_small_gin on g_array using gin (a_small)$q$,                    target => 'g_array_small_gin');
call pgmb.reg_ddl('index.gin_medium',       'index', $q$create index g_array_med_gin on g_array using gin (a_med)$q$,                        target => 'g_array_med_gin');
call pgmb.reg_ddl('index.gin_text',         'index', $q$create index g_array_tags_gin on g_array using gin (tags)$q$,                        target => 'g_array_tags_gin');

-- supporting indexes for joins, LATERAL, recursion and window queries
call pgmb.reg_ddl('index.dim_code',         'index', $q$create unique index g_dim_code on g_dim (code)$q$,                                   target => 'g_dim_code');
call pgmb.reg_ddl('index.parent_grp',       'index', $q$create index g_parent_grp on g_parent (grp)$q$,                                      target => 'g_parent_grp');
call pgmb.reg_ddl('index.parent_dim',       'index', $q$create index g_parent_dim on g_parent (dim_id)$q$,                                   target => 'g_parent_dim');
call pgmb.reg_ddl('index.child_parent_seq', 'index', $q$create index g_child_parent_seq on g_child (parent_id, seq)$q$,                      target => 'g_child_parent_seq');
call pgmb.reg_ddl('index.tree_parent',      'index', $q$create index g_tree_parent on g_tree (parent_id)$q$,                                 target => 'g_tree_parent');
call pgmb.reg_ddl('index.graph_src',        'index', $q$create index g_graph_src on g_graph (src)$q$,                                        target => 'g_graph_src');
call pgmb.reg_ddl('index.graph_dst',        'index', $q$create index g_graph_dst on g_graph (dst)$q$,                                        target => 'g_graph_dst');
call pgmb.reg_ddl('index.events_entity_ts', 'index', $q$create index g_events_entity_ts on g_events (entity_id, ts)$q$,                      target => 'g_events_entity_ts');

-- g_intarr: GIN for containment/overlap, btree for whole-array equality and order
call pgmb.reg_ddl('index.intarr_arr1_gin',    'index', $q$create index g_intarr_arr1_gin on g_intarr using gin (arr1)$q$,             target => 'g_intarr_arr1_gin');
call pgmb.reg_ddl('index.intarr_arr5_gin',    'index', $q$create index g_intarr_arr5_gin on g_intarr using gin (arr5)$q$,             target => 'g_intarr_arr5_gin');
call pgmb.reg_ddl('index.intarr_arr10_gin',   'index', $q$create index g_intarr_arr10_gin on g_intarr using gin (arr10)$q$,           target => 'g_intarr_arr10_gin');
call pgmb.reg_ddl('index.intarr_arr_n_gin',   'index', $q$create index g_intarr_arr_n_gin on g_intarr using gin (arr_n)$q$,           target => 'g_intarr_arr_n_gin');
call pgmb.reg_ddl('index.intarr_arr1_btree',  'index', $q$create index g_intarr_arr1_btree on g_intarr (arr1)$q$,                     target => 'g_intarr_arr1_btree');
call pgmb.reg_ddl('index.intarr_arr1_unique', 'index', $q$create unique index g_intarr_arr1_unique on g_intarr (arr1_unique)$q$,      target => 'g_intarr_arr1_unique');

-- intarray operator classes (only with -v intarray=1). The built-in GIN indexes
-- above serve the built-in operators; these serve the extension's.
--
-- Full indexes: arr5 GIN gin__int_ops, arr10 GiST gist__int_ops.
--
-- Variants. Several indexes of the extension's operator classes on one column
-- would leave the choice to the planner, so each variant is a partial index
-- WHERE id <> -K. No id is negative, so the index holds every row, and a query
-- that adds "AND id <> -K" can use variant K and no other. K is in the name.
--   arr1 (1 value)                           v01 GiST gist__int_ops numranges 1 (a key holds at most
--                                            2 * numranges - 1 elements, so 1 range fits only these)
--   arr10_sorted (10 values, uniform)        v02-v04 GiST gist__int_ops numranges 10/100/252, v05 GIN
--   arr10_lowcard (20 distinct values)       v06 GIN, v07 GiST gist__int_ops, v08 GiST gist__intbig_ops
--   arr10_unique (10 consecutive numbers)    v09 GIN, v10 GiST gist__int_ops, v11 GiST gist__intbig_ops
--   arr100 (100 values)                      v12-v16 GiST gist__intbig_ops siglen 1/16/32/128/2024, v17 GIN
--                                            (gist__int_ops is left out here: it stores the elements
--                                            themselves and is about 9 kB per row at this length)
-- Build time and size of every one of them are part of the DDL report.
\if :pgmb_has_intarray
call pgmb.reg_ddl('index.intarr_arr5_gin_int',   'index', pgmb.ia($q$create index g_intarr_arr5_gin_int on g_intarr using gin (arr5 pgmb_intarray.gin__int_ops)$q$),     target => 'g_intarr_arr5_gin_int');
call pgmb.reg_ddl('index.intarr_arr10_gist_int', 'index', pgmb.ia($q$create index g_intarr_arr10_gist_int on g_intarr using gist (arr10 pgmb_intarray.gist__int_ops)$q$), target => 'g_intarr_arr10_gist_int');

call pgmb.reg_ddl('index.intarr_v01_arr1_gist_numranges_1',   'index', pgmb.ia($q$create index g_intarr_v01 on g_intarr using gist (arr1 pgmb_intarray.gist__int_ops (numranges = 1)) where id <> -1$q$),   target => 'g_intarr_v01');
call pgmb.reg_ddl('index.intarr_v02_sorted_gist_numranges_10',  'index', pgmb.ia($q$create index g_intarr_v02 on g_intarr using gist (arr10_sorted pgmb_intarray.gist__int_ops (numranges = 10)) where id <> -2$q$),  target => 'g_intarr_v02');
call pgmb.reg_ddl('index.intarr_v03_sorted_gist_numranges_100', 'index', pgmb.ia($q$create index g_intarr_v03 on g_intarr using gist (arr10_sorted pgmb_intarray.gist__int_ops (numranges = 100)) where id <> -3$q$), target => 'g_intarr_v03');
call pgmb.reg_ddl('index.intarr_v04_sorted_gist_numranges_252', 'index', pgmb.ia($q$create index g_intarr_v04 on g_intarr using gist (arr10_sorted pgmb_intarray.gist__int_ops (numranges = 252)) where id <> -4$q$), target => 'g_intarr_v04');
call pgmb.reg_ddl('index.intarr_v05_sorted_gin',                'index', pgmb.ia($q$create index g_intarr_v05 on g_intarr using gin (arr10_sorted pgmb_intarray.gin__int_ops) where id <> -5$q$),                    target => 'g_intarr_v05');

call pgmb.reg_ddl('index.intarr_v06_lowcard_gin',      'index', pgmb.ia($q$create index g_intarr_v06 on g_intarr using gin (arr10_lowcard pgmb_intarray.gin__int_ops) where id <> -6$q$),      target => 'g_intarr_v06');
call pgmb.reg_ddl('index.intarr_v07_lowcard_gist',     'index', pgmb.ia($q$create index g_intarr_v07 on g_intarr using gist (arr10_lowcard pgmb_intarray.gist__int_ops) where id <> -7$q$),    target => 'g_intarr_v07');
call pgmb.reg_ddl('index.intarr_v08_lowcard_gist_big', 'index', pgmb.ia($q$create index g_intarr_v08 on g_intarr using gist (arr10_lowcard pgmb_intarray.gist__intbig_ops) where id <> -8$q$), target => 'g_intarr_v08');

call pgmb.reg_ddl('index.intarr_v09_unique_gin',      'index', pgmb.ia($q$create index g_intarr_v09 on g_intarr using gin (arr10_unique pgmb_intarray.gin__int_ops) where id <> -9$q$),       target => 'g_intarr_v09');
call pgmb.reg_ddl('index.intarr_v10_unique_gist',     'index', pgmb.ia($q$create index g_intarr_v10 on g_intarr using gist (arr10_unique pgmb_intarray.gist__int_ops) where id <> -10$q$),    target => 'g_intarr_v10');
call pgmb.reg_ddl('index.intarr_v11_unique_gist_big', 'index', pgmb.ia($q$create index g_intarr_v11 on g_intarr using gist (arr10_unique pgmb_intarray.gist__intbig_ops) where id <> -11$q$), target => 'g_intarr_v11');

call pgmb.reg_ddl('index.intarr_v12_arr100_gist_big_siglen_1',    'index', pgmb.ia($q$create index g_intarr_v12 on g_intarr using gist (arr100 pgmb_intarray.gist__intbig_ops (siglen = 1)) where id <> -12$q$),    target => 'g_intarr_v12');
call pgmb.reg_ddl('index.intarr_v13_arr100_gist_big_siglen_16',   'index', pgmb.ia($q$create index g_intarr_v13 on g_intarr using gist (arr100 pgmb_intarray.gist__intbig_ops (siglen = 16)) where id <> -13$q$),   target => 'g_intarr_v13');
call pgmb.reg_ddl('index.intarr_v14_arr100_gist_big_siglen_32',   'index', pgmb.ia($q$create index g_intarr_v14 on g_intarr using gist (arr100 pgmb_intarray.gist__intbig_ops (siglen = 32)) where id <> -14$q$),   target => 'g_intarr_v14');
call pgmb.reg_ddl('index.intarr_v15_arr100_gist_big_siglen_128',  'index', pgmb.ia($q$create index g_intarr_v15 on g_intarr using gist (arr100 pgmb_intarray.gist__intbig_ops (siglen = 128)) where id <> -15$q$),  target => 'g_intarr_v15');
call pgmb.reg_ddl('index.intarr_v16_arr100_gist_big_siglen_2024', 'index', pgmb.ia($q$create index g_intarr_v16 on g_intarr using gist (arr100 pgmb_intarray.gist__intbig_ops (siglen = 2024)) where id <> -16$q$), target => 'g_intarr_v16');
call pgmb.reg_ddl('index.intarr_v17_arr100_gin',                  'index', pgmb.ia($q$create index g_intarr_v17 on g_intarr using gin (arr100 pgmb_intarray.gin__int_ops) where id <> -17$q$),                    target => 'g_intarr_v17');

-- expression and partial indexes over transformed arrays
call pgmb.reg_ddl('index.intarr_expr_sorted_arr5_btree', 'index', pgmb.ia($q$create index g_intarr_sorted_arr5_btree on g_intarr ((pgmb_intarray.sort(arr5)))$q$), target => 'g_intarr_sorted_arr5_btree');
call pgmb.reg_ddl('index.intarr_expr_arr5_arr10_gin',    'index', pgmb.ia($q$create index g_intarr_arr5_arr10_gin on g_intarr using gin ((arr5 || arr10) pgmb_intarray.gin__int_ops)$q$), target => 'g_intarr_arr5_arr10_gin');
call pgmb.reg_ddl('index.intarr_partial_skew_gin',       'index', pgmb.ia($q$create index g_intarr_skew_part_gin on g_intarr using gin (arr10_skew pgmb_intarray.gin__int_ops) where id % 10 = 0$q$), target => 'g_intarr_skew_part_gin');
\endif
