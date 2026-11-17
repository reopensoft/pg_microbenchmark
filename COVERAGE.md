<div align="center">

# Coverage

**What pg_microbenchmark tests — topic by topic, aspect by aspect.**

About 2,800 tests in 21 topics. This file lists the aspects each group of
tests is about, and the nuances that are exercised along the way.

</div>

---

## How to read this

Each table row is one aspect. **Tests** gives the id prefix, so
`-v only='^cte\.graph_'` runs exactly that group.

| Mark | Meaning |
|:---:|---|
| ≡ | the forms are a consistency group: they must return identical rows |
| ⚠️ | includes error tests: the statement must fail with a given SQLSTATE |
| 🧩 | needs `-v intarray=1` |
| 🔐 | needs `-v rls_role=...` |
| ✍️ | writes data |

What is not covered yet is in [TODO.md](TODO.md).

## Contents

- [1. Common table expressions](#1-common-table-expressions)
  - [1.1 Shapes and dependency graphs](#11-shapes-and-dependency-graphs)
  - [1.2 Inlining and materialization](#12-inlining-and-materialization)
  - [1.3 Predicates and pushdown](#13-predicates-and-pushdown)
  - [1.4 Pruning and nesting](#14-pruning-and-nesting)
  - [1.5 Joins](#15-joins)
  - [1.6 How a CTE is read](#16-how-a-cte-is-read)
  - [1.7 Partial reads](#17-partial-reads)
  - [1.8 Recursion](#18-recursion)
  - [1.9 Data-modifying CTEs](#19-data-modifying-ctes)
  - [1.10 Names and scopes](#110-names-and-scopes)
  - [1.11 Locks, transactions, security](#111-locks-transactions-security)
  - [1.12 Estimates, plan cache, join search](#112-estimates-plan-cache-join-search)
  - [1.13 Memory, temporary files, parallelism](#113-memory-temporary-files-parallelism)
  - [1.14 Arrays and intarray inside CTEs](#114-arrays-and-intarray-inside-ctes)
  - [1.15 CTE against its alternatives](#115-cte-against-its-alternatives)
  - [1.16 Side effects: NOTIFY](#116-side-effects-notify)
  - [1.17 Edge cases](#117-edge-cases)
  - [1.18 Other gaps closed](#118-other-gaps-closed)
- [2. Parallel execution of CTEs (`pcte`)](#2-parallel-execution-of-ctes-pcte)
- [3. Arrays](#3-arrays)
- [4. Indexes](#4-indexes)
- [5. Planner](#5-planner)
- [6. Sequential scans](#6-sequential-scans)
- [7. Sorting](#7-sorting)
- [8. DISTINCT](#8-distinct)
- [9. NULL handling](#9-null-handling)
- [10. LATERAL and window functions](#10-lateral-and-window-functions)
- [11. Functions, result size, locking](#11-functions-result-size-locking)
- [12. DDL phase](#12-ddl-phase)
- [13. Cross-cutting measurements](#13-cross-cutting-measurements)
- [14. Interrupted statements](#14-interrupted-statements)
- [15. RAISE NOTICE](#15-raise-notice)
- [16. Executor and planner nodes (`exec`)](#16-executor-and-planner-nodes-exec)
- [17. Storage (`storage`)](#17-storage-storage)
- [18. Data types and DDL (`types`)](#18-data-types-and-ddl-types)
- [19. Access methods over `g_types`](#19-access-methods-over-g_types)
- [20. NOTIFY (`notify`)](#20-notify-notify)

---

## 1. Common table expressions

Topic `cte`, 28 files, about 1,430 tests.

### 1.1 Shapes and dependency graphs

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Single CTE, linear chain, deep chain (26 and 100 levels) | filter of the main query travelling through every level; a fence in the middle of a chain; one condition per level collapsing into one scan; planning time of very long chains ≡ | `cte.graph_single_*`, `graph_linear_*`, `graph_deep_chain_*`, `cte.chain_5` |
| Fan-out, fan-in, diamond, double diamond, five diamonds | shared ancestor computed once or once per branch; work doubling per diamond when every CTE is `NOT MATERIALIZED` (32 base scans) ≡ | `cte.graph_fan_*`, `graph_diamond_*`, `graph_double_diamond_*`, `graph_five_diamonds_*` |
| Tree and inverted tree | only the leaves that are read get planned and run; a leaf chosen at run time by `CASE`; inverted tree against the same joins written flat ≡ | `cte.graph_tree_*`, `graph_inverted_tree_*` |
| Wide DAG (50 and 300 CTEs on one level) | number of relations and references; 20 single-row CTEs cross-joined (a 20-relation join problem); the same work as one scan ≡ | `cte.graph_wide_*` |
| Deep DAG, dense DAG | every node read by two (or all later) nodes; exponential expansion under `NOT MATERIALIZED` (64 copies) ≡ | `cte.graph_deep_dag_*`, `graph_dense_dag_*` |
| Sparse and disconnected DAG | elimination of independent parts; a whole component never planned | `cte.graph_sparse_dag_*`, `graph_disconnected_*` |
| Orphan CTE, dead branch | heavy unread CTE; 20 orphans (parsed and analysed, never planned); a dead chain hanging off a live CTE; whether a dead second reader still prevents inlining ≡ | `cte.graph_orphan*`, `graph_dead_branch*` |
| Shared root, shared intermediate | materialization boundary placed one level too low; selective branches that can each filter early when inlined ≡ | `cte.graph_shared_*` |
| Repeated leaf | 10 readers of one CTE; rescans per outer row; six-way self-join; the same result in one pass with `FILTER` ≡ | `cte.graph_repeated_leaf_*` |
| Nested scopes, shadowed names | `WITH` inside a CTE body; diamond inside a diamond; a local CTE built from the outer CTE it hides ≡ | `cte.graph_nested_scope_*`, `graph_shadowed_*` |
| Mixed materialization | `MATERIALIZED` and `NOT MATERIALIZED` in one diamond and one chain ≡ | `cte.graph_mixed_*` |
| Recursive node, recursion with several readers | recursive node in the middle of a chain; two chained recursive nodes; recursion written three times against one shared; a reader with `LIMIT` beside a reader of everything ≡ | `cte.graph_recursive_*` |

### 1.2 Inlining and materialization

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Default, `MATERIALIZED`, `NOT MATERIALIZED` | for filter pushdown, two readers, join pushdown and `LIMIT`; `NOT MATERIALIZED` ignored for recursive CTEs ≡ ⚠️ | `materialized.*`, `cte.reader_3_*` |
| Function volatility | `STABLE` honours `NOT MATERIALIZED`, `VOLATILE` does not; a stable function as an index condition; `now()` | `cte.stable_*` |
| How often the body is evaluated | expensive body with one and two readers; base table read once or twice | `cte.eval_*` |
| Volatile functions and sequences | `random()` seen identically by two readers; `nextval()` called once for two readers; how many sequence values a `LIMIT`, `OFFSET`, `EXISTS` or sort consumes | `cte.volatile_*`, `nextval_*`, `mix_nextval_*`, `mix_random_*` |
| Partition pruning through a CTE | pruned when inlined, not when materialized, pruned inside a materialized CTE; by a stable function; by a scalar from another CTE; per join row; keys from a recursive CTE ✍️ | `cte.partition_*`, `mix_partition_*` |
| Join reordering across the boundary | blocked by `MATERIALIZED`; two CTE joins interleaved | `cte.reorder_*` |
| Mixed fences in a chain | fence first, last, none; projection and expensive expressions | `cte.mix_chain_*` |

### 1.3 Predicates and pushdown

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Predicate inside against outside | equality, range, split range, two levels; on a group key (becomes `WHERE`) and on an aggregate (stays `HAVING`) | `cte.where_eq_*`, `where_range_*`, `where_group_key_*`, `where_on_aggregate_*` |
| What a predicate can pass through | `DISTINCT`, `UNION ALL`, `UNION`, a window partition key; not a non-partition column | `cte.where_through_*`, `where_window_*` |
| What blocks pushdown | `LIMIT`, `OFFSET 0`, volatile functions, `MATERIALIZED`, recursion | `cte.where_blocked_by_*`, `where_outside_recursive` |
| Kinds of predicates | `IN` list, `= ANY(array)`, `NOT IN`, `LIKE`, `IS NULL`, OR over two indexes, nested AND/OR, ten ANDs, `CASE`, row comparison (keyset pagination), `BETWEEN SYMMETRIC`, timestamp range, a cast that defeats the index and one that does not, contradiction, tautology, aggregate `FILTER` | `cte.where_*` |
| Predicates that depend on another CTE | scalar from a CTE, `EXISTS`, `IN` a CTE of a CTE, correlation, `ALL`/`ANY`, transitive equality, both join sides, nullable side of an outer join, one parameter used by many CTEs ✍️ ⚠️ | `cte.where_*` |

### 1.4 Pruning and nesting

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Whole CTEs | unreferenced (heavy, chain, materialized); a writer still runs; reader with `WHERE false` or `LIMIT 0`; `EXISTS` reading one row; `EXISTS` blocked by a sort | `cte.prune_unreferenced_*`, `prune_reader_*`, `prune_exists_*` |
| Parts of a CTE | unused columns (inlined, materialized, two readers); unused `LEFT JOIN` removed, inner join kept; unused aggregates, window column, `ORDER BY`, `DISTINCT`; a `UNION` branch removed by a constant or a contradiction; duplicate definitions | `cte.prune_unused_*`, `prune_union_*` |
| Nesting depth and position | five levels in the body, in `FROM`, materialized; inside a scalar subquery, `LATERAL`, `EXISTS`, `IN`, `UNION` branches | `cte.nested_*` |
| Nesting with recursion and writes | recursive inside plain, recursive in recursive, plain inside the recursive term, nested `WITH` as an `UPDATE` source ✍️ | `cte.nested_recursive_*`, `nested_in_update_source` |

### 1.5 Joins

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Join types | inner, left with missing rows, right, full with partial overlap, cross, natural, `USING` two columns | `cte.join_*` |
| Semi and anti joins, each written several ways | `EXISTS` / `IN` / distinct join; `NOT EXISTS` / `NOT IN` / `LEFT ... IS NULL` / `EXCEPT` ≡ | `cte.join_semi_*`, `join_anti_*` |
| Join conditions | expression, range band, inequality, OR, NULL-safe, row equality, type mismatch | `cte.join_on_*` |
| Join shapes | self-join with two readers, chain of 4, star of 5, triangle, outer chain, outer join reduced to inner, removed left join, aggregate to detail, two aggregates, `VALUES` lookup, unnest, `LATERAL` over a CTE, `UNION` branches, recursive result joined to tables ✍️ | `cte.join_*` |
| Join algorithms | Nested Loop (index inner, materialized outer, rescanned materialized inner, inequality only, three levels); Hash Join (build on the CTE, two keys, semi/anti, full); Merge Join (index order, sorted CTEs, many duplicates); one statement forced to each algorithm, inlined and materialized | `cte.joinalgo_*` |

### 1.6 How a CTE is read

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Access paths inside the CTE | sequential, index range, index-only, ordered with `LIMIT`, backward, min/max, bitmap OR and AND, BRIN, GIN, hash, skip scan, partial and expression indexes, `LIKE` prefix, function scan, `VALUES`, `unnest` of a parameter, subquery layers, `UNION ALL` of mixed paths; every path joined in one statement | `cte.scan_*` |
| Kinds of readers | aggregate, `LIMIT`, sort, `EXISTS`, scalar subqueries, window, self-join, `IN` source, correlated per row | `cte.reader_*` |
| Many readers | 3 filters, 5 `UNION` branches, 10 scalar subqueries, fan-out over 3 levels, a recursive CTE reading a plain one, two recursive readers, main statement that updates or deletes ✍️ ≡ | `cte.reader_*` |

### 1.7 Partial reads

Each mechanism is checked with a CTE whose row 500 (or row 1) would fail with
a division by zero: a reader that stops in time gets its answer.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| `LIMIT`, `OFFSET` | one row before the failing row; `OFFSET` rows count as read; `LIMIT 0` pulls nothing; a sort, aggregate, `DISTINCT` or window in between reads everything; pushdown into an inlined CTE skips the failing row ⚠️ | `cte.partial_limit_*` |
| `FETCH FIRST`, `WITH TIES` | `WITH TIES` needs `ORDER BY`, so an unordered source is sorted completely; over an index it reads one row past the limit ⚠️ | `cte.partial_fetch_first_*` |
| `EXISTS`, `NOT EXISTS` | first match; no match before the failing row; `EXISTS` over an aggregate ⚠️ | `cte.partial_exists_*`, `partial_not_exists_*` |
| `IN`, `= ANY`, `NOT IN`, `<> ALL`, `> ALL`, `< ALL` | hashed subplans read everything although the answer is known early; `<> ALL` is not hashed and stops at the first equal value, unlike the equivalent `NOT IN`; inequalities stop at the first counterexample ⚠️ | `cte.partial_in_*`, `partial_any_*`, `partial_not_*`, `partial_*_all_*` |
| Semi and anti join | nested loop stops per outer row; a correlated subplan that cannot become a join (`OFFSET 0`) ⚠️ | `cte.partial_semi_*`, `partial_anti_*` |
| Empty join side | nested loop and merge join never open the CTE; a hash join that probes with the CTE fetches one row from it first; `LEFT JOIN`, cross join, `LATERAL` ⚠️ | `cte.partial_join_*`, `partial_left_join_*`, `partial_lateral_*` |
| `WHERE false`, `CASE`, `COALESCE`, `AND` | constant and run-time false; untaken branch never started; short circuit in the select list ⚠️ | `cte.partial_where_*`, `partial_case_*`, `partial_coalesce_*`, `partial_and_*` |
| `UNION ALL` | later branches not started; empty first branch; ordered output needs every branch; `UNION` reads all ⚠️ | `cte.partial_union_*` |
| Cursors | `FETCH` in steps, `MOVE`, `SCROLL` back and forth, commit without `CLOSE`, rollback, declared and never fetched, `WITH HOLD` (reads everything at commit) | `cte.partial_cursor_*` |
| Several readers | the producer runs as far as the greediest reader; `NOT MATERIALIZED` gives each reader its own stopping point ⚠️ | `cte.partial_two_readers_*`, `partial_three_readers_*` |
| Work saved, on real tables | streaming producer; sort (top-N when inlined, full sort when materialized); hash aggregate against aggregate in index order; windows; `EXISTS` found at once, halfway, never; recursion | `cte.partial_cost_*` |
| Laziness with other features | `LIMIT` over a cross join; `ORDER BY` forcing a full read; errors and sequences behind `LIMIT`/`EXISTS`/`CASE` ⚠️ | `cte.limit_*`, `offset_*`, `error_function_*`, `mix_error_*` |

### 1.8 Recursion

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| `UNION` against `UNION ALL` | deduplication across and within iterations; a depth column that defeats deduplication | `cte.rec_union_*`, `rec_dedup_*` |
| Shapes | one or many start rows; deep with one row per level; shallow with many rows; whole tree; empty base; no new rows; many paths to one node | `cte.rec_*` |
| NULLs and types | NULL keys in deduplication and joins; int, bigint, numeric, growing text; cast in the recursive term; typed NULL and unknown literal in the base; domains; composite rows; explicit collation ⚠️ | `cte.rec_null_*`, `rec_type_*` |
| `SEARCH` | depth first, breadth first, two key columns, unused search column, hidden columns returned by `select *` | `cte.rec_search_*` |
| `CYCLE` | closing row, two columns, NULL key, custom marker values, with `SEARCH`, path as plain and as record array | `cte.rec_cycle_*`, `rec_path_*` |
| Readers of a recursive CTE | three readers; outer `LIMIT` stopping an infinite recursion; `ORDER BY`, `DISTINCT`, `GROUP BY` outside; window in the recursive term | `cte.rec_three_readers`, `rec_outer_*` |
| What the parser rejects | reference in the base term, two references, mutual recursion, reference in a subquery, nullable side of an outer join, `ORDER BY`/`LIMIT` in the recursive term, untyped NULL, lost domain, collation mismatch, `INTERSECT`, `SEARCH` on a non-recursive CTE ⚠️ | `cte.err_rec_*` |
| Recursion mixed with laziness | `SEARCH` + `ORDER BY` + `LIMIT`; `CYCLE` + `LIMIT`; `UNION` + `EXISTS`; filter inside against outside | `cte.mix_rec_*` |

### 1.9 Data-modifying CTEs

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| `INSERT`/`UPDATE`/`DELETE ... RETURNING` | delete and re-insert in one statement; two writers ✍️ | `cte.dml_*_returning`, `dml_delete_reinsert`, `dml_two_writers` |
| `MERGE` in a CTE | `merge_action()` telling insert, update and delete apart; `RETURNING old/new`; a writer as the `MERGE` source; per-client keys because `MERGE` has no speculative insertion ✍️ | `cte.dml_merge_*` |
| Without `RETURNING`, unreferenced, `LIMIT 0` | the writer always runs to completion; outer `WHERE false`; three readers, one execution ✍️ ⚠️ | `cte.dml_no_returning_*`, `dml_unreferenced_*`, `dml_outer_*`, `dml_three_readers_*` |
| Snapshot | `RETURNING` shows new values, a scan in the same statement the old ones; deleted rows still visible; rows of an `AFTER` trigger not visible ✍️ | `cte.dml_returning_*`, `mix_dml_*`, `dml_trigger_output_not_visible` |
| Several writers | three tables; two updates of one row (one takes effect); update in the CTE then delete in the main statement (skipped) and the reverse ✍️ | `cte.dml_three_tables`, `dml_same_row*`, `dml_*_then_main_*` |
| Constraints | FOREIGN KEY, UNIQUE, CHECK re-verified on re-insert; violations raised even when nothing reads the CTE ✍️ ⚠️ | `cte.dml_constraints_*`, `err_dml_*_violation*` |
| Deferrable constraints | swapping unique values needs a deferrable constraint even when checked immediately; two writers consistent only together; checked at commit; child inserted before its parent in one statement ✍️ ⚠️ | `cte.defer_*` |
| Triggers | `BEFORE` and `AFTER` row triggers against the same table without them, single row and 100 rows ✍️ | `cte.dml_trigger_*` |
| Chains through `RETURNING` | update → insert → update; delete → archive; four writers; a writer feeding the main `INSERT` ✍️ | `cte.dml_chain_*`, `dml_writer_feeds_main_insert` |
| Recursive source | subtree and ancestors as the source of `UPDATE`; delete and re-insert ✍️ ⚠️ | `cte.dml_recursive_source_*`, `err_dml_recursive_*` |
| `ON CONFLICT` | `DO NOTHING`, `DO UPDATE`, batch, `DO UPDATE ... WHERE`, conflict on a unique constraint instead of the primary key ✍️ | `cte.dml_on_conflict_*` |
| Partitioned tables | row movement against in-place update; the move written by hand as delete + insert; routed batch insert ✍️ | `cte.dml_partition_*` |
| Empty `RETURNING`; top-level rule | downstream writers with nothing to do; writers in a subquery or nested `WITH` rejected ✍️ ⚠️ | `cte.dml_empty_returning_*`, `err_dml_in_*` |

### 1.10 Names and scopes

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| A CTE named like a table | inside its own body the name still means the table; the table reached by schema; a later CTE sees the CTE ≡ | `cte.scope_cte_named_*`, `scope_hidden_table_*`, `scope_later_cte_*` |
| Forward references | allowed with `RECURSIVE`; five CTEs written backwards; `RECURSIVE` on a `WITH` without recursion ≡ ⚠️ | `cte.scope_forward_*`, `scope_recursive_keyword_*` |
| Column lists and ambiguity | full and partial alias lists; too many aliases; duplicate column names fine until referenced; a reader alias hiding the CTE name ⚠️ | `cte.scope_column_list_*`, `scope_aliases_*`, `scope_duplicate_*` |
| `VALUES`, `TABLE`, scalar subqueries | mixed in one `WITH`; `TABLE c`; `VALUES` as the main statement | `cte.scope_values_*`, `scope_table_*`, `scope_cte_as_scalar_*` |
| Correlation with the outer query | nested `WITH` in the select list, in `LATERAL`, in `WHERE`, two levels up ≡ | `cte.scope_correlated_*` |
| `UNION` branches | each branch its own `WITH`; a shared `WITH` in front; trailing `ORDER BY`/`LIMIT` ⚠️ | `cte.scope_union_*` |
| `SEARCH`/`CYCLE` column names | collisions with existing columns and with each other ⚠️ | `cte.err_scope_*`, `scope_search_cycle_*` |

### 1.11 Locks, transactions, security

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Locking clause on the main query | does not reach into a referenced CTE, does reach into a derived table; `FOR UPDATE OF cte` rejected ✍️ ⚠️ | `cte.lock_main_*`, `lock_derived_table_*` |
| Locking clause inside a CTE | `FOR UPDATE`, `NO KEY UPDATE`, `SHARE`, `KEY SHARE`; share on one table and update on another; lock then update ✍️ | `cte.lock_inside_*` |
| `SKIP LOCKED`, `NOWAIT` | queue pattern (claim, then work); `NOWAIT` on a per-client row so that pgbench clients survive ✍️ | `cte.lock_skip_locked_*`, `lock_nowait_*` |
| Readers and `LIMIT` | rows locked once for three readers; outer `LIMIT 1` locks only the row fetched; an unreferenced locking CTE locks nothing ✍️ | `cte.lock_inside_*` |
| Isolation levels | two reads under READ COMMITTED and REPEATABLE READ; writers with serialization failures retried; read-then-write ✍️ | `cte.iso_*` |
| Snapshots inside one statement | a `STABLE` function sees the statement's snapshot, a `VOLATILE` one the statement's own changes ✍️ | `cte.snapshot_*` |
| Parallel safety of functions | safe, restricted (runs in the leader), unsafe (whole statement serial), unsafe in an unrelated CTE | `cte.parallel_function_*` |
| Security barrier views | leakproof filter crosses the barrier, a user function does not; update through the view ≡ ✍️ | `cte.barrier_*` |
| Row level security 🔐 | policy against a hand-written tenant filter; other tenant's row invisible; user function after the policy; joins; recursive walk; updates; `WITH CHECK` violation ✍️ | `cte.rls_*` |
| `statement_timeout` | cancelling a long recursion, caught in a `DO` block | `cte.timeout_*` |

### 1.12 Estimates, plan cache, join search

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Row estimates above a CTE | equality, skew (frequent and rare value), range, `IS NULL`, `LIKE`, correlated columns; a column that is an expression has no statistics ≡ | `cte.est_filter_*` |
| Estimates of the CTE's output | `GROUP BY`, `DISTINCT`, `UNION`, join, set-returning functions, recursion, `LIMIT`, window rank filter | `cte.est_output_*` |
| Estimates feeding joins | join method after a selective or unselective filter; join key cardinality; two aggregated CTEs; error growing over three levels; join order among three inputs ≡ | `cte.est_join_*`, `est_chain_*` |
| Sort order carried out of a CTE | reused by `ORDER BY`, by an incremental sort, by a merge join, by `GROUP BY`; uniqueness after `DISTINCT` | `cte.est_order_*`, `est_unique_*` |
| Prepared statements | simple, extended, prepared; forced generic and custom plans; parameter inside a materialized CTE; skewed parameter; partition pruning at plan time or at execution start | `cte.plancache_pushdown_*`, `plancache_skew_*`, `plancache_partition_*` |
| Functions | static and dynamic SQL in PL/pgSQL; SQL functions with a CTE (scalar, set-returning in `FROM`); 100 calls per statement; `ANALYZE` invalidating cached plans ≡ ✍️ | `cte.plancache_plpgsql_*`, `plancache_sql_function_*`, `plancache_invalid*` |
| Size of the join problem | 4 to 16 single-table CTEs; CTEs that are joins (2×4, 2×5, 3×4, 4×4); `from_collapse_limit` and `join_collapse_limit` at 1 and 20; exhaustive search against GEQO; a star where the fence costs more than planning saves ≡ | `cte.collapse_*` |

### 1.13 Memory, temporary files, parallelism

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| One CTE below and above `work_mem` | in memory, spilled, not stored at all when inlined; a small CTE that just fits | `cte.mem_one_cte_*`, `mem_small_cte_*` |
| Several CTEs at once | 2, 4, 8, 16 stores; 50 tiny CTEs; the same rows in one CTE | `cte.mem_*_ctes_at_once_*`, `mem_50_tiny_ctes` |
| What is stored | narrow against wide rows; `select *` with one column used; out-of-line values stored as pointers until an expression recomputes them | `cte.mem_narrow_*`, `mem_wide_*`, `mem_select_star_*`, `mem_toasted_*` |
| Reading a store again | three readers; rescan per outer row from a file; early stop writing only a prefix | `cte.mem_three_readers_*`, `mem_rescan_*`, `mem_early_stop_*` |
| Memory inside the CTE | sort and hash aggregate with their own `work_mem`; `hash_mem_multiplier`; chain of three copies; recursive result; `RETURNING` rows ✍️ | `cte.mem_sort_*`, `mem_hash_*`, `mem_chain_*`, `mem_recursive_*` |
| Parallel aggregation and joins | partial aggregate below Gather; Parallel Hash Join with shared and private hash tables; two CTEs joined in workers or in the leader ≡ | `cte.par_aggregate_*`, `par_hash_join_*`, `par_join_of_two_ctes_*` |
| Gather Merge, Parallel Append | sorted output with `LIMIT` and read in full; `UNION ALL` branches; three CTEs appended; 16 partitions; partitionwise aggregate ≡ | `cte.par_gather_merge_*`, `par_append_*` |
| Parallel index paths, workers, leader | parallel index scan and bitmap heap scan; 1 to 8 workers; leader not participating; three Gathers in one statement ≡ | `cte.par_index_*`, `par_bitmap_*`, `par_workers_*`, `par_three_gathers_*` |
| What a CTE Scan does to the plan above | small CTE joined to a parallel scan; CTE as a scalar parameter; recursion over a parallel scan; `LIMIT` and window above Gather ≡ | `cte.par_cte_scan_*`, `par_cte_as_scalar_*`, `par_limit_*`, `par_window_*` |

### 1.14 Arrays and intarray inside CTEs

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| CTEs returning `integer[]` | literal as a search key (constant visible to the planner or not); empty array; NULL array; NULL elements ≡ | `cte.array_literal*`, `array_empty*`, `array_null*` |
| Dimensions and lower bounds | 2-D and 3-D literals; a matrix built by `array_agg` over arrays; lower bound 0; the same elements in four shapes compared ≡ | `cte.array_two_dimensional_*`, `array_lower_bound_*`, `array_same_elements_*`, `array_shape_*` |
| Element types | `bigint = ANY(integer[])` keeps the index, a cast on the column does not; `integer[]` against `bigint[]` and `smallint[]`; typing in `VALUES`, `UNION`, `CASE`, `COALESCE` ≡ ⚠️ | `cte.array_int_keys_*`, `array_smallint_*`, `array_typing_*` |
| `array_agg`, `unnest`, ordinality | aggregate as a CTE source and as lookup keys; `DISTINCT ... ORDER BY` inside against sorting outside; round trip through `unnest` with and without `WITH ORDINALITY`; two arrays zipped ≡ | `cte.array_agg_*`, `array_unnest_*`, `array_ordinality_*` |
| Large and wide arrays | TOAST pointer stored, detoasted on use; many wide columns through a materialized CTE | `cte.array_toast_*`, `array_wide_*` |
| Whole arrays as values | `UNION` keeps reordered arrays; `DISTINCT` and `GROUP BY` as is, sorted, and as sets ≡ | `cte.array_union_*`, `array_distinct_*`, `array_group_by_*` |
| intarray `sort()`/`uniq()` in CTEs 🧩 | materialized against inlined (expression copied to each use); five readers and five branches; predicates on a sorted column; unused arrays; `LIMIT` over `unnest` and `array_agg`; `work_mem`; sort before or after a join; sort → uniq → filter chains ≡ | `cte.intarray_*` |
| Array writes with intarray 🧩 | append, remove, normalize; delete by `query_int`; `ON CONFLICT` set union; `RETURNING` large arrays; HOT against indexed-array updates under GIN and GiST ✍️ | `cte.intarray_dml_*` |
| NULLs and errors with intarray 🧩 | NULL array (strict, returns NULL) against NULL element (refused, except by `icount()`); guarding with `CASE`, a materialized filter, `OFFSET 0`, `array_remove`; a constant branch evaluated at planning time; errors that depend on materialization; errors inside recursion; a failing writer undoing the whole statement ≡ ⚠️ | `cte.intarray_null_*`, `intarray_error_*`, `err_intarray_*` |

### 1.15 CTE against its alternatives

| Task | Forms compared | Tests |
|---|---|---|
| An intermediate result used twice | CTE, `NOT MATERIALIZED`, subquery written twice, one pass with a window, view, materialized view, temporary table with and without `ANALYZE` ≡ | `cte.alt_reuse_*` |
| Top 3 per group | `row_number()` in a CTE, subquery and view; `LATERAL` with `LIMIT`; correlated subquery; temporary table ≡ | `cte.alt_top3_*` |
| One row behind an abstraction | direct, CTE, materialized CTE, subquery, view, materialized view, `LATERAL` ≡ | `cte.alt_lookup_*` |
| Pipeline of three steps | CTE chain, nested subqueries, stacked views, three temporary tables ≡ | `cte.alt_pipeline_*` |
| Large intermediate result | inlined, materialized, subquery, temporary table; joined afterwards, where its statistics matter ≡ | `cte.alt_large_*` |
| Tree of known depth | recursive CTE, union of joins, one CTE per level, computed id ranges ≡ | `cte.alt_tree_*` |
| Cost of keeping the alternative | `REFRESH MATERIALIZED VIEW` plain and `CONCURRENTLY`; an empty temporary table against an empty CTE ✍️ | `cte.alt_cost_*` |

### 1.16 Side effects: NOTIFY

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| `pg_notify()` from CTEs | after `UPDATE`/`INSERT`/`DELETE ... RETURNING`; JSON payload; 100 and 1000 distinct payloads against identical ones (deduplicated); 100 channels; large payload; per row against one summary ✍️ | `cte.notify_*` |
| Where the call sits | inside the CTE body; in an unreferenced CTE (not sent); cut by `LIMIT`; in `RETURNING`; only when the row changed; the `NOTIFY` command beside a CTE; rolled back ✍️ ⚠️ | `cte.notify_*` |

### 1.17 Edge cases

Every case as an inlined and as a `MATERIALIZED` CTE, with the results compared.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Zero rows | aggregates over nothing (one row of zero and NULLs) against `GROUP BY` (no rows); empty at run time against empty by a constant; inner, cross, outer and full joins; `IN` false, `NOT IN` true (and keeping NULL rows), `ALL` true, `ANY` false, scalar subquery NULL; set operations and windows; recursion from an empty start; a chain that becomes empty in the middle; writers fed by nothing ≡ ✍️ | `cte.edge_zero_*` |
| One row | as a scalar; the "parameters" pattern against literals; driving an index join; an aggregate without `GROUP BY` over nothing; one row from `VALUES`, a function, `LIMIT 1`; a scalar subquery over two rows fails, unless it is never evaluated ≡ ⚠️ | `cte.edge_one_row_*`, `err_edge_scalar_*` |
| Millions of rows | `generate_series` in `FROM` (stored first) against in the select list (streamed); `GROUP BY`; join to a table; top 10; two readers; `LIMIT 10`; a whole table joined to itself ≡ | `cte.edge_millions_*`, `edge_whole_table_*` |
| Content of the rows | nothing but NULLs (joins on NULL, NULL-safe joins, one distinct row, one group); nothing but duplicates (`UNION`, `DISTINCT`, join fan-out, `INTERSECT ALL`, `EXCEPT ALL`); arrays; JSONB documents built per row (`->>`, `@>`, `?`, array length, as a `DISTINCT` and `GROUP BY` key, as a join key); one large document aggregated and taken apart again (`jsonb_array_elements`, `jsonb_path_query`); 10 kB text (length, comparison, `LIKE`, sort); all of them in one row ≡ | `cte.edge_content_*` |
| Many references | 100 scalar subqueries over an empty, a one-row and a 100-row CTE; default, materialized, not materialized (100 copies); the same answer in one pass ≡ | `cte.edge_refs_100_*` |
| Rescans in a nested loop | 10, 100, 1000 outer rows with the CTE forced onto the inner side; store in memory against in a temporary file; the planner's own choice; empty and one-row inner side; the CTE on the outer side; a correlated subplan against a window; three levels ≡ | `cte.edge_rescan_*` |
| Unread CTEs | expensive, failing, endlessly recursive, empty; read only by another unread CTE; ten of them; an unread `nextval()` consumes nothing, an unread writer still writes; unread only at run time ≡ ✍️ | `cte.edge_unused_*` |
| `LIMIT`, `EXISTS`, conditional subplans | over an empty CTE (the whole source is read to say "nothing") against a first-row match; `LIMIT` larger than the CTE, `LIMIT NULL`, `LIMIT ALL`, `OFFSET` past the end; a subplan that runs for about half of the statements, always, never; needed by some of 100 rows; `EXISTS` deciding whether a second CTE is read ≡ | `cte.edge_limit_*`, `edge_exists_*`, `edge_conditional_*` |
| Final `ORDER BY` | results returned as an ordered array, so a wrong order fails the comparison; CTE unsorted, sorted differently, sorted the same; through a chain, a join and a `UNION ALL` of CTEs; two readers asking for opposite orders; `NULLS FIRST`/`LAST` and expression keys; top-N with `OFFSET`; order named inside an aggregate and a window; over a recursive CTE, with and without `SEARCH`; with no outer `ORDER BY` only the set of rows is compared ≡ | `cte.edge_order_*` |

### 1.18 Other gaps closed

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| `LATERAL` inside a CTE body | top child per parent, inlined, materialized and without a CTE; `LEFT JOIN LATERAL` with the filter outside; a set-returning function in `LATERAL` and in the select list; `LATERAL` over another CTE against a `GROUP BY` ≡ | `cte.lateral_in_body_*` |
| Row-valued subqueries | `(a, b) IN`, `EXISTS`, a record `= ANY` an array of records; `NOT IN` against `NOT EXISTS`; a row compared with one row of the CTE; NULL inside a row; too many rows, too many columns ≡ ⚠️ | `cte.row_subquery_*`, `cte.err_row_subquery_*` |
| How often a CTE calls a function | one reader; two readers default, `NOT MATERIALIZED` (twice the calls) and volatile (never inlined); a column nobody reads; constant arguments folded for `IMMUTABLE`, not for `STABLE`; the cost of 100,000 calls ≡ | `cte.immutable_*`, `cte.stable_*_arg_*`, `cte.volatile_*_arg_*`, `cte.volatile_unread_*`, `cte.no_function_*` |
| JIT | an aggregate over a million rows inlined and materialized, compiled and not; a point lookup ≡ | `cte.jit_*` |
| Extended statistics | dependent columns filtered inside and outside the CTE, inlined and materialized; number of groups; a join after the filter; each with and without `CREATE STATISTICS` ≡ | `cte.extstats_*` |
| Equivalence classes | a constant reaching the other CTE when both are inlined, neither, one; a chain of three; the equality inside the CTE and the constant outside ≡ | `cte.eqclass_*` |
| Memoize | an inlined CTE as the cached inner side against a CTE Scan; a `LATERAL` aggregate over a CTE; many distinct keys; each with the cache and without ≡ | `cte.memoize_*` |

---

## 2. Parallel execution of CTEs (`pcte`)

Plain SQL with top-level `MATERIALIZED` CTEs, meant to be run twice under
different server settings and compared. 77 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Graph shapes with a gain | 2, 3, 4, 8 independent CTEs of equal cost; unequal CTEs 1:4, 1:10, 1:100; the long CTE written last; diamond; one source with many readers; mixed DAG of 8 ≡ | `pcte.shape_*` |
| Shapes without a gain | pure chain; second CTE under `LIMIT`, `EXISTS` or unreferenced; cheap CTEs from 10k rows up | `pcte.decline_*`, `pcte.threshold_rows_*` |
| Parallel restricted and unsafe parts | `random()` (written so that the result stays deterministic), a temporary table, both CTEs restricted, an unsafe function, a writer; two read orders ✍️ | `pcte.restricted_*`, `pcte.unsafe_*`, `pcte.writer_*` |
| Together with Gather | Gather inside one CTE, inside every CTE, in the main query, forced in both | `pcte.gather_*` |
| What the main query does | reads the long CTE first or the short one first; heavy join or sort of its own; joins the results into a large scan | `pcte.main_*` |
| Early stop | outer `LIMIT`, `EXISTS`, cursor with `FETCH 10`, in steps, rolled back | `pcte.early_stop_*` |
| Short indexed queries | two key lookups, three small ranges, small diamond, one CTE, no CTE | `pcte.oltp_*` |
| Kind of work | scan-bound, CPU-bound (hash aggregate, sort, expensive expressions), spilling sort and hash aggregate | `pcte.work_*` |
| Result size | 10k / 1M / 10M rows × 16 / 100 / 1000 bytes; one row; wide result read twice. The three largest are opt-in (`optin_bigtransfer`) | `pcte.transfer_*` |

---

## 3. Arrays

Topic `array`, about 300 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Operators with GIN support | `@>`, `&&`, `<@`, `=`; integer and text arrays; `= ANY` against a column (no index) ≡ | `array.gin_*`, `array.any_*` |
| Construction, access, big arrays | subscripts, slices, `unnest`, sort and distinct of elements, empty and NULL; 2000-element TOASTed arrays ✍️ ⚠️ | `array.scalar_ops`, `array.big_*`, `array.update_*` |
| Large `array_agg` passed to functions | 50k elements into PL/pgSQL (`FOREACH`, subscript loop), SQL (`unnest`), built-in chains; append in a loop; keys to `= ANY` against an `unnest` join; per-group arrays; 2-D from arrays ≡ | `array.agg_*` |
| One element per array | equality by btree, containment by GIN, `= ANY` and subscript as filters; unique values; `IN` list of arrays ≡ | `array.int_one_*`, `array.int_unique_*` |
| 5, 10, 100 and `arr_len` elements | containment and overlap; rows similar to a given row, ranked; low-cardinality and skewed values (hot against rare); a number that occurs once in the table found three ways ≡ | `array.int_arr*`, `array.int_lowcard_*`, `array.int_skew_*`, `array.int_unique10_*`, `array.int_n_*` |
| One row by primary key | fetching all array columns; slices; scalar functions; `array_sort`, `array_reverse`; intersection of two rows | `array.int_pk_*` |
| `unnest` cost per element | 5, 10, 100 elements; per-row subquery; in the select list; two columns in step; `WITH ORDINALITY`; sorting each array two ways ≡ | `array.int_unnest_*`, `array.int_sort_each_*` |
| Empty arrays, NULLs | three ways to detect an empty array; `unnest` dropping empty rows against `LEFT JOIN LATERAL`; three-valued `= ANY` ≡ | `array.int_var_*`, `array.int_nulls_*` |
| Arrays as values | `ORDER BY`, `GROUP BY`, `DISTINCT`, joins on array equality; elements as keys of another table | `array.int_order_by_*`, `array.int_group_by_*`, `array.int_join_*`, `array.int_elements_*` |
| Element updates | with GIN, without an index, on 100 elements; rotation (same keys, new value) ✍️ | `array.int_update_*` |
| intarray against built-in operators 🧩 | `@>` `&&` `<@` with GIN and GiST classes and without an index; two columns of one row ≡ | `array.intarray_contains_*`, `intarray_overlap_*`, `intarray_contained_by_*` |
| Operator name resolution 🧩 | with the extension on the `search_path` the same text uses another index or loses it; explicit `OPERATOR(pg_catalog.@>)`; `bigint[]` falls back to the built-in; `smallint[]` becomes ambiguous ≡ ⚠️ | `array.intarray_resolution_*` |
| Edge cases 🧩 | NULL array against NULL element; empty arrays on either side; repeated elements; negative values; integer limits; several dimensions; lower bounds; equality against mutual containment ≡ ⚠️ | `array.intarray_null_*`, `intarray_empty_*`, `intarray_duplicates_*`, `intarray_negative_*`, `intarray_integer_limits_*`, `intarray_dimensions_*`, `intarray_lower_bound_*`, `intarray_equality_*` |
| Selectivity 🧩 | hot and rare values under each operator, with the join method above showing the estimate ≡ | `array.intarray_estimate_*` |
| Other intarray functions 🧩 | `sort_asc`, `sort_desc` and `sort` with a direction; `idx` (0 when absent, integer limits); `subarray` with positive and negative position and length; `icount` and `#`; `intset`; `\|`, `&`, `+`, `-` against their built-in equivalents ≡ | `array.intarray_sort_*`, `intarray_idx_*`, `intarray_subarray_*`, `intarray_count_*`, `intarray_intset_*`, `intarray_set_operator_*`, `intarray_union_*` |
| Integer paths in recursion 🧩 | built-in `\|\|` against intarray `+` and `array_append`; a cycle detected by `<> ALL`, `idx() = 0`, `NOT @>` (both operators) and the `CYCLE` clause; a path against the set of visited nodes; paths of 1 to 10,000 elements (the longest opt-in, `optin_long_path`) ≡ | `array.intarray_path_*`, `intarray_cycle_*`, `intarray_walk_*` |
| `query_int` and `@@` 🧩 | single value, AND, OR, NOT, nesting; six levels, 200 redundant parentheses, 50 levels to the right; repeated and absent values; built in a CTE, shared by three CTEs, joined as a table, one query per row; as a prepared-statement parameter; 200 and 2000 terms; the `~~` commutator; double negation, tautology, contradiction, De Morgan, distribution; negation and estimates ≡ ⚠️ | `array.queryint_*` |

## 4. Indexes

Topic `index`, about 140 tests, plus build times in the DDL phase.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| B-tree basics | primary key and unique lookups, range, `IN` list, multi-column (both columns, order with `LIMIT`, range on the second), `INCLUDE` index-only scan, partial, expression, `LIKE` prefix, `DESC NULLS LAST` ⚠️ | `index.pk_point` … `index.desc_nulls_last` |
| Skip scan | two leading columns skipped, range on the second, gap in the middle, `IN` list, with `ORDER BY`, count, defeated by an expression | `index.skip_scan*` |
| Other B-tree uses | backward scans, min/max endpoints, two `IN` lists, `IN` with a range, OR on one column, row comparison, `IS NULL`, index-only count, filter on an `INCLUDE` column, implied partial predicate, cross-type comparison, merge join without sort, `GROUP BY` removed by uniqueness | `index.btree_*` |
| Hash, BRIN, bitmap | hash equality; BRIN on time and on a correlated column; bitmap OR and AND | `index.hash_*`, `index.brin_*`, `index.bitmap_*` |
| Updates and indexes | indexed column, HOT update, GIN column ✍️ | `index.update_*` |
| intarray classes behind CTEs 🧩 | inlined CTE using GIN and GiST; materialized CTE with the filter outside (no index) and inside; two readers ≡ | `index.intarray_cte_*` |
| GiST options 🧩 | `numranges` 1, 10, 100, 252 (a key holds at most 2·numranges − 1 elements); `siglen` 1, 16, 32, 128, 2024 and false positives; what the options refuse ≡ ⚠️ | `index.intarray_gist_numranges_*`, `index.intarray_gist_siglen_*` |
| GIN against GiST 🧩 | small arrays, 100-element arrays, duplicate-heavy data, correlated data (ten consecutive numbers per row) ≡ | `index.intarray_gin_*`, `intarray_duplicates_*`, `intarray_correlated_*` |
| Operators per class 🧩 | `<@` indexable by GIN only; `@@` under each class; whole-array equality by btree, GIN and GiST ≡ | `index.intarray_operator_*`, `intarray_equality_*` |
| Bitmaps and recheck 🧩 | exact against lossy bitmap; GiST signature recheck; BitmapAnd and BitmapOr of two indexes | `index.intarray_bitmap_*` |
| Expression and partial indexes 🧩 | btree on `sort(arr)`; GIN on a concatenation; partial index usable only when the CTE carries its predicate ≡ | `index.intarray_expression_*`, `intarray_partial_*` |

## 5. Planner

Topic `plan`, 80 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Join search | chains of 2, 4, 8, 12 relations and 16 with GEQO; star of 5; self-join elimination; semi join from `EXISTS`; subquery pull-up | `plan.join_*`, `plan.exists_semi_join`, `plan.subquery_pullup_4` |
| Long lists | `IN` with 1000 and 10000 items, hashed and by index, `NOT IN`, text items, row pairs, two lists; 5000 keys as `IN`, as an array literal, as `VALUES` semi join and join; 100 ORs; 200 `CASE` branches; 20 `UNION ALL` branches | `plan.in_list_*`, `plan.keys_5000_*`, `plan.or_chain_100`, `plan.case_200_branches` |
| Large `VALUES` | 1000 and 10000 rows scanned, grouped and sorted, returned, joined, anti-joined; 10 columns; mixed types; batch update ✍️ | `plan.values_*` |
| Row count misestimates | correlated ranges, redundant columns, overlapping OR, expression defaults, function predicates, `LIKE` infix, set-returning functions, CTE scans, recursion, skewed fan-out, group counts, `LIMIT` on correlated data, anti join | `plan.misestimate_*` |
| Predicate pushdown | into grouped subqueries and views; through `UNION ALL`, `UNION`, `INTERSECT`, `EXCEPT`, `DISTINCT`, `DISTINCT ON`, window partition keys; outer joins (`WHERE` against `ON`); into `LATERAL`; `HAVING` to `WHERE`; blocked by `LIMIT`, volatile and set-returning functions; security barrier views | `plan.pushdown_*` |
| Parameter-dependent plans | skewed value, range width, join order ⚠️ | `plan.unstable_*` |

## 6. Sequential scans

Topic `seqscan`, 31 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Reading everything | narrow and wide rows, small table, one column against all columns, few groups | `seqscan.count_*`, `seqscan.aggregate_*`, `seqscan.group_by_*` |
| Filters | 1%, half, nothing; first against last column of the row; text infix; regular expression; eight quals; parameter | `seqscan.filter_*` |
| Stopping early | first rows, common and rare match, `EXISTS` | `seqscan.limit_*`, `seqscan.exists_any_row` |
| Serial against parallel; TOAST | the same statement under two settings; out-of-line values read only when used | `seqscan.aggregate_serial`, `aggregate_parallel_4`, `seqscan.toast_*` |
| Parts of a table | TID ranges; `TABLESAMPLE SYSTEM` and `BERNOULLI`, `REPEATABLE` ⚠️ | `seqscan.tid_range_*`, `seqscan.sample_*` |

## 7. Sorting

Topic `sort`, 69 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Whether a sort is needed | order from an index, top-N heapsort, full sort, deep `OFFSET` | `sort.query_order_*`, `query_top_n_*`, `query_full_sort_*` |
| Sort keys | integer, numeric, float, text with and without `COLLATE "C"`, expression, long common prefix, mixed directions, five keys, NULL placement, alias and position | `sort.query_key_*`, `query_mixed_*`, `query_nulls_*` |
| Input shape | already sorted, reversed, few distinct values, skewed, wide rows, after a join, `UNION ALL` merged, whole table; top 20 by sort against by index | `sort.query_input_*`, `query_whole_table_*`, `query_top20_*` |
| Incremental Sort | tiny to huge groups, with `LIMIT`, backward prefix, two-column prefix, for windows, `GROUP BY`, `DISTINCT`, after a join; setting on and off | `sort.incremental_*` |
| `ORDER BY` inside aggregates | `array_agg`, `string_agg`, JSON; presorted by index; three aggregates with the same and with different orders; with `DISTINCT` and `FILTER`; order in the call, in a subquery, in an array constructor | `sort.agg_*` |
| Ordered-set aggregates | median, percentile arrays, mode, hypothetical rank; median by `OFFSET` for comparison ⚠️ | `sort.agg_median*`, `agg_percentile_*`, `agg_mode`, `agg_hypothetical_rank` |

## 8. DISTINCT

Topic `distinct`, 64 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| The same distinct values eight ways | `SELECT DISTINCT`, `GROUP BY`, `DISTINCT ON`, `UNION` and `INTERSECT` with itself, `row_number()`, `unnest(array_agg(DISTINCT))`, `NOT EXISTS` an earlier row ≡ | `distinct.form_*` |
| Whole table | hash or sort against walking the index; loose index scan emulated with recursion ≡ | `distinct.table_*` |
| `SELECT DISTINCT` | high cardinality, already unique, two columns in and out of index order, expression, NULLs, text prefix, whole wide rows, with `LIMIT` and `ORDER BY`, set-returning function, after a join fan-out, with a window, redundant in a subquery | `distinct.*` |
| `DISTINCT ON` and `GROUP BY` | first per group, two keys, latest event, expression; functional dependency; `GROUP BY DISTINCT` with `ROLLUP` | `distinct.on_*`, `distinct.group_by_*` |
| `DISTINCT` inside aggregates | `count` (also over a subquery and over `GROUP BY`), three columns, grouped, with `FILTER`, row value, presorted by index; `sum`, `avg`, `array_agg`, `string_agg`, `jsonb_agg`; deduplicating array elements ✍️ ⚠️ | `distinct.count_*`, `distinct.array_*`, `distinct.sum_avg`, `distinct.string_agg` |

## 9. NULL handling

Topic `nulls`, 44 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| `COALESCE` | in a filter (index not used) against plain equality and `IS NOT DISTINCT FROM`; ten arguments; in aggregates; after an outer join; subquery fallback evaluated only when needed; defaults by `COALESCE`, `CASE`, `UNION` | `nulls.coalesce_*`, `nulls.default_by_*` |
| `NULLIF` | division guard, in a filter, empty text, round trip with `COALESCE` | `nulls.nullif_*` |
| `IS [NOT] DISTINCT FROM` | against a value, spelled out, two columns; NULL-safe joins three ways; changed-row detection | `nulls.distinct_from_*`, `nulls.join_*`, `nulls.row_changed_detection` |
| `IS NULL`, ordering, three-valued logic | by index; `NULLS FIRST`/`LAST`; row `IS NULL`; `NOT IN` against `NOT EXISTS` with NULLs in the set | `nulls.is_null_*`, `nulls.order_nulls_*`, `nulls.three_valued_logic`, `nulls.not_*` |
| NULLs elsewhere | aggregates, `GROUP BY`, arrays, string concatenation, `greatest`/`least`, strict functions ✍️ ⚠️ | `nulls.*` |

## 10. LATERAL and window functions

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| `LATERAL` | top 3 per parent; left join to an aggregate and to nothing; set-returning functions; `unnest` with ordinality; unpivot with `VALUES`; dependent chains; previous event; top 1 three ways ⚠️ | `lateral.*` |
| Window functions | `row_number`, running sum, `lag`/`lead`, moving average, `RANGE` with an interval, `GROUPS` with `EXCLUDE`, `first`/`last`/`nth_value`, rank distribution, two sort orders, run condition for top 3, aggregate then window, no partition, whole table ⚠️ | `window.*` |

## 11. Functions, result size, locking

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Function call overhead | 10,000 calls of functions that do nothing: built-in, SQL inlined, SQL volatile, SQL not inlinable, PL/pgSQL plain, immutable with a constant, strict, security definer, with a `SET` clause, returning void, nested, with an exception block, set-returning in `LATERAL`; single calls of a function, a procedure and a `DO` block ⚠️ | `funcall.*` |
| Result size | 0 to 100k rows; one column; wide rows; one 100 kB value; one row out of many; deep `OFFSET`; generated rows; `RETURNING` 100 rows ✍️ | `resultsize.*` |
| Row locks | `FOR UPDATE`, `NO KEY UPDATE`, `SHARE`, `KEY SHARE`; update of a non-key column; foreign key insert under each lock; ordered multi-row locking; `SKIP LOCKED` queue; `FOR UPDATE OF` in a join ✍️ ⚠️ | `locking.*` |

## 12. DDL phase

Every step is timed, with WAL volume and resulting size.

| Aspect | Nuances also exercised |
|---|---|
| Data generation | `INSERT ... SELECT` from `generate_series` with hash functions; uniform, skewed, correlated, unique and half-NULL columns; arrays of 1 to 2000 elements; a 4-ary tree; a cyclic graph; 16 range partitions |
| Index builds | btree unique, multi-column, `INCLUDE`, partial, expression, pattern, descending; hash; BRIN; GIN on integer and text arrays; with intarray: GIN and GiST with `numranges` and `siglen` variants |
| Constraints | primary keys, foreign keys (including a self-reference), unique, check, deferrable variants; row level security policies; triggers |
| Other | a materialized view and its index; `VACUUM (ANALYZE)` per table; table and column comments |

## 13. Cross-cutting measurements

| Measurement | What it adds to every test that carries the tag |
|---|---|
| `perf` | tps, failures, latency average, p50, p95, p99, maximum, histogram; temporary files and WAL written |
| `planning` | planning time and memory; whether the plan shape is the same for different parameter values |
| `consistency` | equivalent formulations return identical rows (more than 200 groups) |
| `checksum` | the result of one test is the same in two runs, for example with a server setting on and off |
| `analyze` | worst ratio between estimated and actual rows; memory and disk use of sorts, hashes and stores |
| `errors` | the expected SQLSTATE, for about 150 statements that must fail |

## 14. Interrupted statements

Topic `cancel`, 267 tests in four files. A function that calls `pg_cancel_backend()` on its
own backend puts the cancel at an exact point of the statement; those tests
must end with `57014`. Phases that run no user code are reached with a short
`statement_timeout`, caught in a `DO` block, each next to a twin without the
timeout.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Planner | constant folding of an immutable function, in the main query, a CTE and a subquery; a stable function evaluated for a row estimate ⚠️ | `cancel.err_planner_*` |
| Executor startup | partition pruning with a stable function, on a cached plan so that planning is not what gets cancelled ⚠️ | `cancel.err_executor_start_*` |
| First row | before any row (scalar subquery), on the first row, after it ⚠️ | `cancel.err_first_row_*` |
| Halfway through a scan | sequential, index and bitmap heap scans; the second partition of an Append; an expensive filter; a recursive CTE; the second reader of a materialized CTE ⚠️ | `cancel.err_scan_*` |
| Sort | while rows are loaded and while sorted rows are returned; in memory and with runs in temporary files ⚠️ | `cancel.err_sort_*` |
| Hash join, hash aggregate | while the table is built and while it is probed, in memory and in batches; groups being collected, spilled, returned ⚠️ | `cancel.err_hash_join_*`, `cancel.err_hash_aggregate_*` |
| `RETURNING` | update, insert and delete cancelled on row 50 of 100; a writer nobody reads; the second of two writers ✍️ ⚠️ | `cancel.err_returning_*` |
| Triggers | at the end of the statement; deferred, fired by `SET CONSTRAINTS` ✍️ ⚠️ | `cancel.err_trigger_*` |
| Parallel query: where an error comes from | a parallel safe function fails in a worker, a restricted and an unsafe one in the leader, told apart by SQLSTATE; division by zero in a worker; a worker process that is terminated ⚠️ | `cancel.err_parallel_*_function_fails_*`, `cancel.err_parallel_worker_*` |
| Parallel query: leader cancelled | above Gather on the first row and halfway; in the middle of a Gather Merge ⚠️ | `cancel.err_parallel_leader_*` |
| Parallel query: worker cancelled | Parallel Seq Scan; partial aggregate; hash join on the build and on the probe side, also with 64 kB; one partition of a Parallel Append and of a partitionwise aggregate; a sort in memory and on disk ⚠️ | `cancel.err_parallel_seq_scan_*`, `err_parallel_aggregate_*`, `err_parallel_hash_join_*`, `err_parallel_append_*`, `err_parallel_partitionwise_*`, `err_parallel_sort_*` |
| Parallel query: number of workers | the same failing statement with 0, 1, 2 and 4 workers ⚠️ | `cancel.err_parallel_same_error_*` |
| Causes other than a cancel | `lock_timeout` and `NOWAIT`; `temp_file_limit` for a sort, hash aggregate, hash join, materialized and recursive CTE (superuser only); stack depth; values too large to allocate ⚠️ | `cancel.lock_timeout_*`, `cancel.nowait_*`, `cancel.err_temp_file_limit_*`, `cancel.err_stack_depth_*`, `cancel.err_*_larger_than_allowed` |
| `RAISE EXCEPTION` | custom SQLSTATE, three functions deep, through an SQL function, by condition name, in a `DO` block, a loop, a procedure, a trigger, before and after a write; a handler that re-raises or translates; a handler that undoes its block and goes on ≡ ⚠️ | `cancel.err_raise_*`, `cancel.err_handler_*`, `cancel.handler_*`, `cancel.nested_blocks_*` |
| CTEs cut short | chain cancelled in the root, the middle and the reader; diamond; three readers; a store being filled, rescanned, partly filled; two inlined copies; an unread CTE never started; volatile calls made before the cancel; a writer undone ≡ ⚠️ | `cancel.err_cte_*`, `cancel.cte_*` |
| Recursion cut short | in the anchor, the recursive term, with `UNION`, with a join, with `SEARCH` and `CYCLE`, with a growing array ⚠️ | `cancel.err_recursive_*` |
| Temporary files | spilled store, sort and hash aggregate inside a CTE; no file left behind afterwards ≡ ⚠️ | `cancel.err_cte_spilled_*`, `cancel.temp_files_removed_after_cancel` |
| Functions | set-returning in `FROM`, in the select list, per outer row; dynamic SQL four levels deep; a statement reused after two cancels; a sequence value lost; invalid regular expressions ≡ ⚠️ | `cancel.err_srf_*`, `cancel.err_dynamic_*`, `cancel.statement_reused_*`, `cancel.sequence_*`, `cancel.err_regex_*` |
| Locks | what a cancelled block keeps: a lock taken before it, inside it, at session level; a timeout while waiting for a row, a table, a DDL lock; `lock_timeout` against `statement_timeout` ≡ ✍️ | `cancel.locks_*`, `cancel.timeout_100ms_waiting_for_*`, `cancel.*_timeout_before_*` |
| What is left after an error | a cursor opened before a cancelled block goes on, one opened inside it is gone; insert, update, delete, `MERGE` and a writing CTE failing on row 50 leave nothing; a table lock taken in the failed block is released; an expression index whose function fails; a trigger's rows undone, its sequence values kept; a prepared statement and a cached plan used after they failed; backend memory after 50 cancels ≡ ⚠️ | `cancel.cursor_*`, `cancel.atomic_*`, `cancel.table_lock_*`, `cancel.expression_index_*`, `cancel.trigger_side_effects_*`, `cancel.reuse_*`, `cancel.memory_*` |
| What an error costs | cancel after 1 to 1,000,000 rows against no cancel; 1 to 1,000,000 inserted rows rolled back (the largest opt-in, `optin_large_rollback`); an error through 1, 10, 100 exception blocks; 1, 10, 100 locks released by an error and by a commit; a parallel scan failing with 0 to 8 workers against one that does not ✍️ | `cancel.cost_*` |
| Writes interrupted halfway | multi-row `VALUES`; `INSERT ... SELECT` in the source, the select list, a `BEFORE` trigger; `ON CONFLICT` on new keys, in `DO UPDATE` and its `WHERE`; `UPDATE` (rows keep their place); `DELETE` while scanning and in `RETURNING`; `MERGE` in each action, a `WHEN` condition and `NOT MATCHED BY SOURCE`; nothing is left of any of them ≡ ✍️ ⚠️ | `cancel.dml_*`, `cancel.err_dml_*` |
| Around the write | `ON DELETE CASCADE`, `SET NULL` and a cascade down a chain; a deferred foreign key raising at `SET CONSTRAINTS`; `BEFORE` trigger, a trigger of the table an `AFTER` trigger writes to, a transition table; routing and row movement between partitions; btree, GIN, GiST and expression indexes after an insert cancelled in index maintenance ≡ ✍️ ⚠️ | `cancel.dml_fk_*`, `cancel.dml_deferred_*`, `cancel.dml_triggers_*`, `cancel.dml_partitions_*`, `cancel.dml_indexes_*` |
| Builds and maintenance | `CREATE TABLE AS`, a materialized view, `CREATE INDEX`, `ANALYZE`, `REINDEX`, `CLUSTER` cancelled while they evaluate an index expression; a unique index over duplicates; HOT and non-HOT updates cancelled halfway, then `VACUUM` (timed in the DDL phase) ≡ ⚠️ | `cancel.dml_builds_*`, `cancel.err_dml_create_*`, `cancel.err_dml_analyze`, `cancel.err_dml_reindex`, `cancel.err_dml_cluster`, `cancel.hot_*` |
| An upsert waiting for another backend | every client inserts key 1, the first keeps it uncommitted for 150 ms, the others are cancelled after 100 ms ✍️ | `cancel.timeout_100ms_upsert_waiting_for_other_insert` |
| intarray errors 🧩 | a NULL element in a filter, join condition, sort key, aggregate and index build; 100 errors in a row, then a call that works; recursion over sorted growing arrays ≡ ⚠️ | `cancel.err_intarray_*`, `cancel.intarray_*` |
| A cancel pending during parsing, analysis, rewriting | a list of 50,000 constants; 200 references to a view over two views; with the cancel already requested and without | `cancel.*_cancel_long_in_list`, `cancel.*_cancel_view_expansion_200` |
| Timeout inside the planner | exhaustive search of a 15-relation star (about 0.4 s), 100 ms against none | `cancel.timeout_*_planner_star_join_15` |
| Timeout in the executor and in waits | expensive filter, external sort, spilled hash aggregate; `pg_sleep()`; the queue of an advisory lock | `cancel.timeout_100ms_*` |

## 15. RAISE NOTICE

Topic `raise`, 103 tests. Nothing in the benchmark reads the messages a
statement sends, so every test filters them out with `client_min_messages`.
Text and diagnostic fields are checked by raising the same thing as an
exception and catching it; how often `RAISE` runs is counted with a sequence.
`RAISE INFO`, the order and arrival of messages and the server log are not
covered.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| What is rejected | too few and too many parameters; a format that is an expression, a variable, a bare word; `MESSAGE` given twice; a NULL option; an unknown condition name; a notice followed by an error ⚠️ | `raise.err_*` |
| Text of the message | `%` and `%%`, ten parameters; NULL, boolean, integers, numeric, timestamps, UUID; array, JSONB, record, range, multirange, bytea; 0 to 100,000 characters; Polish letters, a four-byte character, a tab ≡ | `raise.format_*` |
| Diagnostic fields | `USING MESSAGE` from an expression; `DETAIL`, `HINT`, `ERRCODE`, `COLUMN`, `CONSTRAINT`, `DATATYPE`, `TABLE`, `SCHEMA`; empty values and odd identifiers; the call stack three functions deep; every form once at `NOTICE` level ≡ | `raise.using_*`, `raise.context_*`, `raise.notice_all_forms_run` |
| Control flow in PL/pgSQL | `IF` and `CASE` branches; a loop never entered; `FOR ... IN SELECT` over nothing, with `LIMIT`, `EXIT`, `CONTINUE`; nested calls; `RETURN` inside a loop; an exception block that raised before failing ≡ | `raise.flow_*` |
| A raising function in SQL | all rows, `LIMIT`, `EXISTS` (select list not evaluated); CTE unread, one reader, two readers default / materialized / not materialized; correlated subquery; `LATERAL`, also without outer rows; recursion, also endless under `LIMIT`; `RETURNING`, also unread ≡ ✍️ | `raise.sql_*`, `raise.cte_*`, `raise.recursive_*`, `raise.returning_*` |
| Triggers | per row and per statement, for insert, update, update of nothing, delete, `ON CONFLICT DO UPDATE` and `MERGE` ≡ ✍️ | `raise.trigger_row_*`, `raise.trigger_statement_*` |
| Cost of a filtered message | loop of 1 to 100,000 against an empty loop; constant, one and five parameters, `USING`; array and JSONB arguments; one megabyte as 10,000, 1,000 or 10 messages | `raise.loop_*` |
| Cost by caller | 1000 calls from SQL against a silent function; a trigger per row against per statement against none ✍️ | `raise.sql_calls_*`, `raise.trigger_cost_*` |

## 16. Executor and planner nodes (`exec`)

Topic `exec`, 61 tests.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Memoize | few keys (hits), many keys (misses), 64 kB (evictions), NULL keys, a cached `LATERAL` aggregate; each with the cache and without ≡ | `exec.memoize_*` |
| Materialize | inner side of a nested loop stored and rescanned, re-executed without it, spilled to a file, a materialized CTE as the inner side ≡ | `exec.material_*` |
| Grouping sets | `GROUPING SETS` hashed and sorted and as `UNION ALL`; `ROLLUP` and `CUBE` against their grouping sets; three-column cube ≡ | `exec.grouping_sets_*`, `exec.rollup_*`, `exec.cube_*` |
| JIT | expressions off, compiled, optimized and inlined, default thresholds; tuple deforming on and off; forced on a point lookup ≡ | `exec.jit_*` |
| Cached plans and the schema | a cached statement follows `search_path`; survives a dropped index; `select *` after `ADD COLUMN` is refused ≡ ⚠️ | `exec.plancache_*`, `exec.err_plancache_*` |
| EvalPlanQual | every client updates the same row: recheck passes, recheck fails, with a join, `FOR UPDATE`, delete and re-insert ✍️ | `exec.epq_*` |
| Short circuits | `OR` and `AND` on constants and per row, both orders; `CASE` protecting a row expression but not a constant one ≡ ⚠️ | `exec.shortcircuit_*`, `exec.err_shortcircuit_*` |
| `ROWS FROM` | functions of unequal length, `WITH ORDINALITY`, `unnest` of two arrays, 10,000 rows against a join on the row number ≡ | `exec.srf_*` |

## 17. Storage (`storage`)

Topic `storage`, 63 tests, plus timed steps in the DDL phase.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Row versions | own insert visible, update on the same page, failed block undone; one row updated 20 times; a scan after rolled back and after committed updates ≡ ✍️ | `storage.mvcc_*` |
| Savepoints | none, one released, one rolled back, 10 nested, 100 in sequence with and without writes; only the failed block is undone ≡ ✍️ | `storage.savepoint_*` |
| Advisory locks, deadlock | own key, one key for all, shared mode, try-lock, session level; two rows locked in opposite order (opt-in `optin_deadlock`) ✍️ | `storage.advisory_*`, `storage.deadlock_*` |
| Foreign key actions | `ON DELETE CASCADE`, `SET NULL`, children deleted by hand, a five-level cascade; what is left afterwards; violations ≡ ✍️ ⚠️ | `storage.fk_*`, `storage.err_fk_*` |
| Triggers | `INSTEAD OF` on a view, two `BEFORE` triggers in name order, a transition table, `TRUNCATE` ≡ ✍️ | `storage.trigger_*` |
| TOAST | compressed, `EXTERNAL` and incompressible values: whole value, a slice, the size only; updates that keep or rewrite the value ≡ ✍️ | `storage.toast_*` |
| Bloat (DDL phase) | every row rewritten, `VACUUM`, `REINDEX INDEX` and `TABLE`, `VACUUM FULL`, with time, WAL and size per step; index-only scan over visible and not visible pages; scan of a compact and of a bloated table ≡ | `storage.bloat_*`, `storage.index_only_scan_*`, `storage.seq_scan_*` |
| Logged, unlogged, temporary | the same load and index build (DDL phase); insert and delete of 100 rows and of one row; a temporary table created and dropped per transaction ✍️ | `storage.load_*`, `storage.wal_*`, `storage.temp_table_*` |
| Sequences | a value taken in a failed block is lost, `currval`, `setval`; one sequence for all clients, `CACHE 100`, 100 values per statement, rollback ≡ ⚠️ | `storage.sequence_*`, `storage.err_sequence_*` |

## 18. Data types and DDL (`types`)

Topic `types`, 104 tests, plus timed steps in the DDL phase.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Numbers | the same sum as smallint, integer, bigint, numeric, float8; overflow of each type; NaN and Infinity in comparisons and sorts ≡ ⚠️ | `types.sum_*`, `types.err_*_overflow`, `types.nan_*` |
| UUID | generation, sorting, comparison as value and as text, malformed input ≡ ⚠️ | `types.uuid_*` |
| Pattern matching | a prefix by `LIKE`, regex, `starts_with`, `left`; the same in any case by `ILIKE`, `~*`, `lower`; infix, alternation, `SIMILAR TO`, `regexp_replace` ≡ | `types.match_*` |
| Unicode, ICU | characters against bytes, NFC and NFD; a nondeterministic collation in equality, grouping and sorting, against `"C"` ≡ | `types.unicode_*`, `types.collation_*` |
| JSON | `JSON_TABLE` against `jsonb_to_recordset` and `jsonb_array_elements`; one field by `->`, `#>>`, jsonpath, `JSON_VALUE`, `JSON_TABLE`; parsing as json and jsonb; `JSON_EXISTS`, `JSON_QUERY` ≡ ⚠️ | `types.json_*` |
| Ranges | union, intersection, difference, multirange, containment, empty; `range_agg`; errors of a non-contiguous result ≡ ⚠️ | `types.range_*`, `types.multirange_*` |
| Enum, domain, composite, polymorphic | declaration order; domain checks on cast; field access and row comparison; `anyelement` against `anycompatible` ≡ ⚠️ | `types.enum_*`, `types.domain_*`, `types.composite_*`, `types.polymorphic_*` |
| Generated columns | stored and virtual: computed, not writable, cost on insert and on read ≡ ✍️ ⚠️ | `types.generated_*` |
| `ALTER TABLE` (DDL phase) | add column without, with a constant and with a volatile default; `int` to `bigint`; a wider `varchar`; `SET NOT NULL`; drop column; attach a partition with and without a matching constraint; 1000 columns; a view with a rule ✍️ | `types.ddl_*`, `types.wide_table_*`, `types.rule_*` |

## 19. Access methods over `g_types`

Part of topic `index`, 45 tests, plus index builds and rebuilds in the DDL phase.

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| JSONB | containment through `jsonb_ops`, `jsonb_path_ops`, an expression index, no index; nested values; jsonpath; key existence ≡ | `index.jsonb_*` |
| Full text | one term through GIN, `to_tsvector` without an index, `LIKE`; AND, OR, negation, prefix, phrase, a term in every row, ranking ≡ | `index.fts_*` |
| Ranges | element containment, overlap and containment by GiST, SP-GiST, no index, plain comparisons; multirange by GiST ≡ | `index.range_*`, `index.multirange_*` |
| SP-GiST on text, btree on uuid | equality and prefix against no index; point lookup and ordered range ≡ | `index.spgist_*`, `index.uuid_*` |
| Deduplication, page splits, rebuilds | index size with and without deduplication; random against ascending keys, `fillfactor` 70; `REINDEX` of GIN, btree and GiST ≡ ✍️ | `index.dedup_*`, `index.split_*`, `index.reindex_*` |

## 20. NOTIFY (`notify`)

Topic `notify`, 80 tests. Nothing listens, so delivery, deduplication as a
listener sees it and the order of arrival are not tested. Calls of
`pg_notify()` are counted with a sequence. CTE-specific cases are in
[1.16](#116-side-effects-notify).

| Aspect | Nuances also exercised | Tests |
|---|---|---|
| Ways of sending | the command with and without payload; the function with constants and computed values; a command built with `format()`; the payload as a parameter under each protocol ✍️ | `notify.command_*`, `notify.function_*`, `notify.dynamic_*` |
| Payload types | JSONB, a row as JSON, an integer array, UUID, timestamp ✍️ | `notify.payload_*` |
| Transactions | savepoint released, rolled back, three levels; a PL/pgSQL exception block; `LISTEN` and `UNLISTEN` in one transaction; `LISTEN` not registered before commit ≡ ✍️ | `notify.savepoint_*`, `notify.exception_block`, `notify.listen_*` |
| Repeated notifications | A,A,A; A,B,A; A,B,C,A,B,C; one payload on two channels; 10,000 distinct against 10,000 identical ✍️ | `notify.pattern_*`, `notify.many_*` |
| How often the function is called | identical payloads (100 calls, one notification); from `VALUES`, a table, a scalar subquery, `CASE`, an SQL function, `LATERAL`, `RETURNING`, a failed block; under `LIMIT`, `EXISTS`, `count(*)`; CTE with two readers, in a diamond, unreferenced ≡ | `notify.calls_*` |
| Triggers | `AFTER` and `BEFORE` row, statement, `TRUNCATE`, transition table; insert, update, delete, `ON CONFLICT`, `MERGE`; cost per row against per statement ≡ ✍️ | `notify.trigger_*` |
| Limits and the queue | 7999 bytes accepted, 8000 refused, counted in bytes not characters; channel name of 64 characters; an unquoted dynamic command; `pg_notification_queue_usage()` ≡ ⚠️ | `notify.payload_*`, `notify.err_*`, `notify.queue_usage_*` |
