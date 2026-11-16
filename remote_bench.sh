#!/usr/bin/env bash
# remote_bench.sh — start two source-built PostgreSQL servers and run the
# pg_microbenchmark sanity preset against both, then compare.
#
# Designed to run on the remote machine where:
#   /application/postgres_master/   — unpatched build (baseline)
#   /application/postgres/          — patched build
#   /application/pg_microbenchmark/ — clone of this repository
#
# Usage:
#   ./remote_bench.sh                 # init (if needed), run sanity on both (exclusively), compare
#   ./remote_bench.sh init            # only initdb (no start)
#   ./remote_bench.sh stop            # stop both servers
#   ./remote_bench.sh bench           # run sanity on both, one server at a time
#   ./remote_bench.sh compare         # print the comparison report (after bench)
#
# Runs are exclusive: while one server is benchmarked the other is stopped,
# so it cannot steal RAM (shared_buffers), CPU (checkpointer, autovacuum)
# or disk I/O. After 'bench' the patched server is left running.
#
# Environment overrides:
#   PG_USER      database user to connect as (default: current OS user)
#   PORT_MASTER  port for the master build   (default: 5440)
#   PORT_PATCH   port for the patched build  (default: 5441)
#   DB           benchmark database name     (default: bench)

set -euo pipefail

# ---------------------------------------------------------------------------
# layout
# ---------------------------------------------------------------------------
MASTER_SRC=/application/postgres_master
PATCH_SRC=/application/postgres
BENCH_DIR=/application/pg_microbenchmark

PORT_MASTER=${PORT_MASTER:-5440}
PORT_PATCH=${PORT_PATCH:-5441}
DB=${DB:-bench}
PG_USER=${PG_USER:-$(id -un)}

# data directories live inside the source trees, as requested
MASTER_DATA="$MASTER_SRC/data"
PATCH_DATA="$PATCH_SRC/data"

master_bin() { echo "$MASTER_SRC/src/bin/$1/$1"; }
patch_bin()  { echo "$PATCH_SRC/src/bin/$1/$1"; }

# ---------------------------------------------------------------------------
# server settings scaled for 10 CPUs / 80 GB RAM
# ---------------------------------------------------------------------------
# shared_buffers: 25% of RAM
# effective_cache_size: ~75% of RAM (shared_buffers + OS cache)
# work_mem: generous per-operator budget (10 cores, few concurrent clients)
# parallelism: sized to 10 CPUs
PG_SETTINGS='''
# --- memory (80 GB RAM) ---
shared_buffers = 20GB
effective_cache_size = 60GB
work_mem = 2GB
maintenance_work_mem = 4GB
huge_pages = try

# --- parallelism (10 CPUs) ---
max_worker_processes = 10
max_parallel_workers = 8
max_parallel_workers_per_gather = 8
max_parallel_maintenance_workers = 4

# --- planner ---
random_page_cost = 1.1
effective_io_concurrency = 200

# --- WAL / checkpoints (large RAM, assume fast disk) ---
wal_buffers = 64MB
checkpoint_completion_target = 0.9
min_wal_size = 2GB
max_wal_size = 8GB

# --- logging (useful while benchmarking) ---
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0
'''

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

# initdb/psql/pgbench from a source tree link against the build's own
# libpq.so.5, which is not on the system library path
use_libpq() {
    export LD_LIBRARY_PATH="$1/src/interfaces/libpq${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

init_cluster() {
    local src=$1 data=$2
    local initdb="$src/src/bin/initdb/initdb"
    use_libpq "$src"
    local postgres="$src/src/backend/postgres"

    if [ -s "$data/PG_VERSION" ]; then
        log "initdb: $data already initialized, skipping"
        return
    fi
    log "initdb: $data"
    "$initdb" -D "$data" -U "$PG_USER" -E UTF8 --locale=C.UTF-8

    log "appending tuned settings to $data/postgresql.conf"
    printf '%s\n' "$PG_SETTINGS" >> "$data/postgresql.conf"
}

start_server() {
    local src=$1 data=$2 port=$3
    local postgres="$src/src/backend/postgres"
    use_libpq "$src"

    if [ -s "$data/postmaster.pid" ]; then
        log "server on port $port already running (pid $(head -1 "$data/postmaster.pid"))"
        return
    fi
    log "starting postgres from $src on port $port"
    "$postgres" -D "$data" -p "$port" -c listen_addresses='' \
        > "$data/server.log" 2>&1 &
    # wait until it accepts connections
    local psql="$src/src/bin/psql/psql"
    for _ in $(seq 1 30); do
        if "$psql" -X -p "$port" -U "$PG_USER" -d postgres -tAc "select 1" >/dev/null 2>&1; then
            log "server on port $port is up"
            return
        fi
        sleep 0.5
    done
    echo "server on port $port did not come up; see $data/server.log" >&2
    tail -20 "$data/server.log" >&2
    exit 1
}

stop_server() {
    local src=$1 data=$2
    local postgres="$src/src/backend/postgres"
    if [ -s "$data/postmaster.pid" ]; then
        log "stopping server with data dir $data"
        "$postgres" -D "$data" --stop
    else
        log "no server running for $data"
    fi
}

# ---------------------------------------------------------------------------
# benchmark
# ---------------------------------------------------------------------------
run_sanity() {
    local src=$1 port=$2 label=$3
    local psql="$src/src/bin/psql/psql"
    local pgbench="$src/src/bin/pgbench/pgbench"
    use_libpq "$src"

    log "sanity run: label=$label port=$port"
    # create the database if it does not exist (createdb is not built in a
    # plain source tree, so use psql)
    "$psql" -X -p "$port" -U "$PG_USER" -d postgres -tAc \
        "select 1 from pg_database where datname = '$DB'" | grep -q 1 \
        || "$psql" -X -p "$port" -U "$PG_USER" -d postgres -c "create database $DB"

    (cd "$BENCH_DIR" &&
        "$psql" -X -p "$port" -U "$PG_USER" -d "$DB" \
            -f bench.sql \
            -v preset=sanity \
            -v label="$label" \
            -v outdir="$BENCH_DIR/out/$label" \
            -v pgbench="$pgbench")
}

compare_runs() {
    # The two servers have separate databases, so the master's run is
    # exported to CSV and imported into the patched server's database;
    # compare.sql then shows master (a) vs patched (b).
    local master_psql="$MASTER_SRC/src/bin/psql/psql"
    local patch_psql="$PATCH_SRC/src/bin/psql/psql"
    local export_dir="$BENCH_DIR/out/export_master"
    use_libpq "$MASTER_SRC"
    use_libpq "$PATCH_SRC"

    # the import and the report need the patched server; start it if needed
    start_server "$PATCH_SRC" "$PATCH_DATA" "$PORT_PATCH"

    # the export needs the master server; start it just for that, then stop it
    start_server "$MASTER_SRC" "$MASTER_DATA" "$PORT_MASTER"

    log "exporting the master run to $export_dir"
    mkdir -p "$export_dir"
    (cd "$BENCH_DIR" &&
        "$master_psql" -X -p "$PORT_MASTER" -U "$PG_USER" -d "$DB" \
            -f report/export.sql -v outdir="$export_dir")

    log "importing the master run into the patched server's database"
    local import_out
    import_out=$(cd "$BENCH_DIR" &&
        "$patch_psql" -X -p "$PORT_PATCH" -U "$PG_USER" -d "$DB" \
            -f report/import.sql -v dir="$export_dir")
    local master_run_id
    master_run_id=$(printf '%s\n' "$import_out" | sed -n 's/^imported as run \([0-9]*\)$/\1/p')

    local patch_run_id
    patch_run_id=$("$patch_psql" -X -p "$PORT_PATCH" -U "$PG_USER" -d "$DB" \
        -tAc "select max(run_id) from pgmb_results.run where label = 'patched'")

    log "comparison report: a=master($master_run_id) b=patched($patch_run_id)"
    (cd "$BENCH_DIR" &&
        "$patch_psql" -X -p "$PORT_PATCH" -U "$PG_USER" -d "$DB" \
            -f report/compare.sql -v a="$master_run_id" -v b="$patch_run_id")

    stop_server "$MASTER_SRC" "$MASTER_DATA"
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
cmd=${1:-all}

case "$cmd" in
    init)
        init_cluster "$MASTER_SRC" "$MASTER_DATA"
        init_cluster "$PATCH_SRC"  "$PATCH_DATA"
        ;;
    stop)
        stop_server "$MASTER_SRC" "$MASTER_DATA"
        stop_server "$PATCH_SRC"  "$PATCH_DATA"
        ;;
    bench)
        # exclusive runs: only one server active at a time
        log "exclusive run: master (patched stopped)"
        stop_server "$PATCH_SRC" "$PATCH_DATA"
        start_server "$MASTER_SRC" "$MASTER_DATA" "$PORT_MASTER"
        run_sanity "$MASTER_SRC" "$PORT_MASTER" "master"

        log "exclusive run: patched (master stopped)"
        stop_server "$MASTER_SRC" "$MASTER_DATA"
        start_server "$PATCH_SRC" "$PATCH_DATA" "$PORT_PATCH"
        run_sanity "$PATCH_SRC" "$PORT_PATCH" "patched"
        ;;
    compare)
        compare_runs "$PORT_PATCH"
        ;;
    all)
        init_cluster "$MASTER_SRC" "$MASTER_DATA"
        init_cluster "$PATCH_SRC"  "$PATCH_DATA"
        log "exclusive run: master (patched stopped)"
        stop_server "$PATCH_SRC" "$PATCH_DATA"
        start_server "$MASTER_SRC" "$MASTER_DATA" "$PORT_MASTER"
        run_sanity "$MASTER_SRC" "$PORT_MASTER" "master"

        log "exclusive run: patched (master stopped)"
        stop_server "$MASTER_SRC" "$MASTER_DATA"
        start_server "$PATCH_SRC" "$PATCH_DATA" "$PORT_PATCH"
        run_sanity "$PATCH_SRC" "$PORT_PATCH" "patched"

        compare_runs "$PORT_PATCH"
        ;;
    *)
        echo "unknown command: $cmd (use: init | stop | bench | compare | all)" >&2
        exit 2
        ;;
esac
