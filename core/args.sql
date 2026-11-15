-- Default every command-line variable to '' so that it can be passed as :'name'.
-- An empty value means "take it from the preset".
\if :{?preset}
\else
  \set preset mini-benchmark
\endif
\if :{?data_scale}
\else
  \set data_scale ''
\endif
\if :{?conn_scale}
\else
  \set conn_scale ''
\endif
\if :{?write_ratio}
\else
  \set write_ratio ''
\endif
\if :{?scope}
\else
  \set scope rw
\endif
\if :{?tags}
\else
  \set tags ''
\endif
\if :{?topics}
\else
  \set topics ''
\endif
\if :{?label}
\else
  \set label ''
\endif
\if :{?duration}
\else
  \set duration ''
\endif
\if :{?warmup}
\else
  \set warmup ''
\endif
\if :{?mode}
\else
  \set mode ''
\endif
\if :{?protocol}
\else
  \set protocol simple
\endif
\if :{?pgbench}
\else
  \set pgbench pgbench
\endif
\if :{?plan_iterations}
\else
  \set plan_iterations 20
\endif
\if :{?stmt_timeout}
\else
  \set stmt_timeout 120s
\endif
\if :{?arr_len}
\else
  \set arr_len 20
\endif
\if :{?arr_distinct}
\else
  \set arr_distinct 1000
\endif
\if :{?rls_role}
\else
  \set rls_role ''
\endif
\if :{?intarray}
\else
  \set intarray 0
\endif
\if :{?gucs}
\else
  \set gucs ''
\endif
\if :{?shared_db}
\else
  \set shared_db 0
\endif
\if :{?only}
\else
  \set only ''
\endif
\if :{?skip_ddl}
\else
  \set skip_ddl 0
\endif
\if :{?outdir}
\else
  \set outdir out
\endif
\if :{?cat}
\else
  \set cat cat
\endif
