-- Remove everything the benchmark created in the current database.
--
--   psql -X -d <db> -f clean.sql                 drop test data and framework, keep results
--   psql -X -d <db> -f clean.sql -v results=1    drop the stored results as well
--   psql -X -d <db> -f clean.sql -v run_id=N     delete one run from the results, nothing else
--
-- Files in out/ (generated scripts, pgbench logs, CSV) are not touched:
-- psql cannot delete files. Remove them by hand; they are ignored by git.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\if :{?results}
\else
    \set results 0
\endif

\if :{?run_id}
    delete from pgmb_results.run where run_id = :run_id;
    \echo deleted run :run_id from pgmb_results
\else
    drop schema if exists pgmb_data cascade;
    drop schema if exists pgmb cascade;
    -- the intarray extension, if bench.sql installed it (-v intarray=1); an
    -- intarray that was already in the database lives elsewhere and stays
    drop schema if exists pgmb_intarray cascade;
    \echo dropped schemas pgmb_data, pgmb, pgmb_intarray
    \if :results
        drop schema if exists pgmb_results cascade;
        \echo dropped schema pgmb_results
    \else
        \echo kept schema pgmb_results (pass -v results=1 to drop it)
    \endif
\endif
