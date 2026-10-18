-- Presets are plain rows; any value can be overridden with -v on the command line.
insert into pgmb.preset (name, descr, data_scale, base_clients, write_ratio, duration, warmup, mode, tags) values
('sanity',          'no data at all and one transaction per test: checks that every statement parses, plans and runs',
    0,     1, 0.5,  0, 0, 'isolated', '{}'),
('micro-benchmark', 'tiny data, one connection, every test on its own; finishes in a couple of minutes',
    0.01,  1, 0.5,  1, 0, 'isolated', '{}'),
('mini-benchmark',  'all topics on moderate data, every test on its own with a few connections',
    1,     4, 0.5,  3, 0, 'isolated', '{}'),
('midi-benchmark',  'all topics on five times the data of mini-benchmark, every test on its own with a few connections',
    5,     4, 0.5,  5, 0, 'isolated', '{}'),
('mini-oltp',       'short transactions mixed in one workload on many connections',
    1,    16, 0.3, 60, 5, 'mixed',    '{oltp,perf}'),
('mini-olap',       'heavy queries on larger data, few connections, read-mostly',
    5,     2, 0,   10, 0, 'isolated', '{olap}');
