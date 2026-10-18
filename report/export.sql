-- Export one run to CSV files, to compare it with runs of another server.
--   psql -X -d <db> -f report/export.sql [-v run_id=N] [-v outdir=out]
-- Writes <outdir>/export_<table>.csv for every result table (default: the last
-- run). Copy the files to the other machine and load them with report/import.sql.
\set ON_ERROR_STOP on
\set QUIET on
\if :{?run_id}
\else
    select max(run_id) as run_id from pgmb_results.run \gset
\endif
\if :{?outdir}
\else
    \set outdir out
\endif
\set pgmb_f :outdir /export_run.csv
copy (select * from pgmb_results.run where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_ddl_step.csv
copy (select * from pgmb_results.ddl_step where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_pgbench_raw.csv
copy (select run_id, test_id, clients, cmd, output from pgmb_results.pgbench_raw where run_id = :run_id order by seq) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_perf.csv
copy (select * from pgmb_results.perf where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_planning.csv
copy (select * from pgmb_results.planning where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_checks.csv
copy (select * from pgmb_results.checks where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_latency.csv
copy (select * from pgmb_results.latency where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_latency_hist.csv
copy (select * from pgmb_results.latency_hist where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_explain_stats.csv
copy (select * from pgmb_results.explain_stats where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_explain_plan.csv
copy (select * from pgmb_results.explain_plan where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_resource.csv
copy (select * from pgmb_results.resource where run_id = :run_id) to stdout with (format csv, header) \g :pgmb_f
\set pgmb_f :outdir /export_*.csv
\echo run :run_id exported to :pgmb_f
