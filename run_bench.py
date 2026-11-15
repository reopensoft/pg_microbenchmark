#!/usr/bin/env python3
"""pg_microbenchmark runner.

Automates the full workflow:
  1. create the database (if it does not exist),
  2. run bench.sql with the chosen preset/variables,
  3. print the report (summary, or comparison against a baseline run),
  4. optionally clean up afterwards.

Only the standard library is used; `psql` and `createdb` must be on PATH
(or given via --psql/--createdb).

Examples:
  # quick micro run, then summary
  python3 run_bench.py --preset micro-benchmark

  # baseline vs. patch, then comparison report
  python3 run_bench.py --preset mini-benchmark --label baseline
  python3 run_bench.py --preset mini-benchmark --label my-patch --compare

  # run several presets in a row, compare each against the previous
  python3 run_bench.py --preset micro-benchmark --preset mini-benchmark --compare

  # reuse data from a previous run, planner check only
  python3 run_bench.py --skip-ddl --tags planning --topics plan,cte

  # drop everything afterwards
  python3 run_bench.py --preset micro-benchmark --clean
"""

import argparse
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def run(cmd, check=True, quiet=False):
    """Run a command, streaming its output. Returns the exit code."""
    if not quiet:
        print(f"$ {' '.join(str(c) for c in cmd)}", flush=True)
    proc = subprocess.run([str(c) for c in cmd])
    if check and proc.returncode != 0:
        sys.exit(f"command failed with exit code {proc.returncode}: {cmd}")
    return proc.returncode


def psql_args(args, extra_vars=None):
    """Build the psql connection arguments from the parsed CLI options."""
    cmd = [args.psql, "-X"]
    if args.host:
        cmd += ["-h", args.host]
    if args.port:
        cmd += ["-p", str(args.port)]
    if args.user:
        cmd += ["-U", args.user]
    cmd += ["-d", args.db]
    for k, v in (extra_vars or {}).items():
        cmd += [f"-v{k}={v}"]
    return cmd


def ensure_database(args):
    """Create the target database if it does not exist yet."""
    if args.no_createdb:
        return
    probe = subprocess.run(
        [args.psql, "-X"]
        + (["-h", args.host] if args.host else [])
        + (["-p", str(args.port)] if args.port else [])
        + (["-U", args.user] if args.user else [])
        + ["-d", "postgres", "-tAc",
           f"select 1 from pg_database where datname = {args.db!r}"],
        capture_output=True, text=True)
    if probe.returncode != 0:
        sys.exit(f"cannot connect to the server: {probe.stderr.strip()}")
    if probe.stdout.strip() == "1":
        print(f"database {args.db} already exists, reusing it")
        return
    print(f"creating database {args.db}")
    createdb = [args.createdb]
    if args.host:
        createdb += ["-h", args.host]
    if args.port:
        createdb += ["-p", str(args.port)]
    if args.user:
        createdb += ["-U", args.user]
    createdb += [args.db]
    run(createdb)


def ensure_outdir(outdir):
    outdir.mkdir(parents=True, exist_ok=True)


def run_bench(args, label, extra_vars=None):
    """Run one bench.sql invocation. Returns the run id (or None)."""
    ensure_database(args)
    ensure_outdir(args.outdir)

    vars_ = {
        "preset": args.preset,
        "label": label,
        "outdir": str(args.outdir),
    }
    for name, value in (
        ("scope", args.scope),
        ("mode", args.mode),
        ("protocol", args.protocol),
        ("data_scale", args.data_scale),
        ("conn_scale", args.conn_scale),
        ("write_ratio", args.write_ratio),
        ("tags", args.tags),
        ("topics", args.topics),
        ("duration", args.duration),
        ("warmup", args.warmup),
        ("plan_iterations", args.plan_iterations),
        ("stmt_timeout", args.stmt_timeout),
        ("pgbench", args.pgbench),
        ("arr_len", args.arr_len),
        ("arr_distinct", args.arr_distinct),
        ("rls_role", args.rls_role),
        ("intarray", args.intarray),
    ):
        if value is not None:
            vars_[name] = value
    if args.skip_ddl:
        vars_["skip_ddl"] = "1"
    vars_.update(extra_vars or {})

    t0 = datetime.now()
    print(f"\n=== bench: preset={vars_['preset']} label={label!r} "
          f"db={args.db} ===")
    run(psql_args(args, vars_) + ["-f", REPO / "bench.sql"])
    elapsed = (datetime.now() - t0).total_seconds()
    print(f"=== bench finished in {elapsed:.0f}s ===")

    # capture the run id for the report
    probe = subprocess.run(
        psql_args(args) + ["-tAc",
                           "select max(run_id) from pgmb_results.run"],
        capture_output=True, text=True)
    run_id = probe.stdout.strip()
    if run_id:
        print(f"run_id = {run_id}")
    return run_id or None


def print_report(args, run_id=None, compare=False, baseline_id=None):
    """Print the summary or the comparison report."""
    if compare:
        vars_ = {}
        if baseline_id is not None:
            vars_["a"] = str(baseline_id)
        if run_id is not None:
            vars_["b"] = str(run_id)
        script = REPO / "report" / "compare.sql"
        title = "comparison report"
    else:
        vars_ = {}
        if run_id is not None:
            vars_["run_id"] = str(run_id)
        script = REPO / "report" / "summary.sql"
        title = "summary report"
    print(f"\n=== {title} ===")
    run(psql_args(args, vars_) + ["-f", script])


def clean(args, drop_results=False, run_id=None):
    vars_ = {}
    if drop_results:
        vars_["results"] = "1"
    if run_id is not None:
        vars_["run_id"] = str(run_id)
    print(f"\n=== clean {'(including results)' if drop_results else ''} ===")
    run(psql_args(args, vars_) + ["-f", REPO / "clean.sql"])


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)

    conn = p.add_argument_group("connection")
    conn.add_argument("--db", default="bench",
                      help="target database (default: bench)")
    conn.add_argument("--host", help="server host (default: local socket)")
    conn.add_argument("--port", type=int, help="server port")
    conn.add_argument("--user", help="database user")
    conn.add_argument("--psql", default="psql", help="psql binary")
    conn.add_argument("--createdb", default="createdb", help="createdb binary")
    conn.add_argument("--no-createdb", action="store_true",
                      help="do not create the database, it must exist")

    bench = p.add_argument_group("bench variables (see README.md)")
    bench.add_argument("--preset", action="append", required=True,
                       choices=["micro-benchmark", "mini-benchmark",
                                "mini-oltp", "mini-olap"],
                       help="preset; may be given several times to run a "
                            "sequence of presets")
    bench.add_argument("--label", help="label for a single preset run; "
                                       "with several presets, labels are "
                                       "preset-<n>")
    bench.add_argument("--data-scale", help="data volume multiplier")
    bench.add_argument("--conn-scale", help="connection multiplier")
    bench.add_argument("--write-ratio", help="share of write transactions, "
                                             "0..1")
    bench.add_argument("--scope", choices=["rw", "readonly", "writeonly",
                                           "createonly"],
                       help="phase scope (default: rw)")
    bench.add_argument("--tags", help="tag filter, e.g. 'oltp,perf' or 'all'")
    bench.add_argument("--topics", help="topic filter, e.g. 'cte,window'")
    bench.add_argument("--mode", choices=["isolated", "mixed"],
                       help="pgbench mode (default: preset)")
    bench.add_argument("--protocol", choices=["simple", "extended",
                                              "prepared"],
                       help="pgbench query mode (default: simple)")
    bench.add_argument("--duration", help="seconds per pgbench run")
    bench.add_argument("--warmup", help="seconds of unmeasured warm-up")
    bench.add_argument("--plan-iterations", type=int,
                       help="EXPLAIN repetitions in the planning check")
    bench.add_argument("--stmt-timeout", help="statement_timeout, e.g. 120s")
    bench.add_argument("--pgbench", default="pgbench",
                       help="pgbench binary (e.g. from your own build)")
    bench.add_argument("--arr-len", type=int, help="g_intarr.arr_n length")
    bench.add_argument("--arr-distinct", type=int,
                       help="distinct values in g_intarr.arr_n")
    bench.add_argument("--rls-role", help="role for the RLS tests")
    bench.add_argument("--intarray", type=int, choices=[0, 1],
                       help="1 installs the intarray extension")
    bench.add_argument("--skip-ddl", action="store_true",
                       help="reuse data from a previous run with the same "
                            "data_scale/arr_len/arr_distinct")
    bench.add_argument("--outdir", type=Path, default=REPO / "out",
                       help="directory for scripts, logs and CSV files")

    report = p.add_argument_group("report")
    report.add_argument("--compare", action="store_true",
                        help="print report/compare.sql instead of the "
                             "summary; with --baseline, compare against "
                             "that run id")
    report.add_argument("--baseline", type=int,
                        help="run id used as 'a' in the comparison "
                             "(default: the run before the candidate)")
    report.add_argument("--no-report", action="store_true",
                        help="do not print any report")

    p.add_argument("--clean", action="store_true",
                   help="run clean.sql after the report")
    p.add_argument("--clean-results", action="store_true",
                   help="with --clean, also drop the stored results")
    p.add_argument("--clean-run", type=int,
                   help="with --clean, delete only this run id")
    return p


def main():
    args = build_parser().parse_args()

    if len(args.preset) == 1:
        labels = [args.label or args.preset[0]]
    else:
        labels = [f"{p}-{i}" for i, p in enumerate(args.preset)]

    last_id = None
    for preset, label in zip(args.preset, labels):
        args.preset = preset  # bench.sql takes a single preset
        run_id = run_bench(args, label)
        if not args.no_report:
            print_report(args, run_id=run_id, compare=args.compare,
                         baseline_id=args.baseline)
        last_id = run_id

    if args.clean:
        clean(args, drop_results=args.clean_results,
              run_id=args.clean_run)


if __name__ == "__main__":
    main()
