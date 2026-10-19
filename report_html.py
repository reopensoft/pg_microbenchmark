#!/usr/bin/env python3
"""Generate a visual HTML report for a pg_microbenchmark run.

Reads the pgmb_results schema via psql and writes a single self-contained
HTML file (embedded CSS/JS, no external assets).

Examples:
  # report for the latest run
  python3 report_html.py

  # report for a specific run, custom output file
  python3 report_html.py --run 1 --out report.html

  # compare two runs (a = baseline, b = candidate)
  python3 report_html.py --compare --a 1 --b 2

Connection options: --db --host --port --user --psql
"""

import argparse
import csv
import html
import io
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# data access
# ---------------------------------------------------------------------------

def psql_cmd(args):
    # no -t: in CSV mode -t suppresses the header row, which we need
    cmd = [args.psql, "-X", "--csv"]
    if args.host:
        cmd += ["-h", args.host]
    if args.port:
        cmd += ["-p", str(args.port)]
    if args.user:
        cmd += ["-U", args.user]
    cmd += ["-d", args.db]
    return cmd


def query(args, sql):
    """Run a query, return (header, rows) with rows as lists of strings."""
    proc = subprocess.run(psql_cmd(args) + ["-c", sql],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"query failed:\n{proc.stderr.strip()}\n{sql}")
    rows = list(csv.reader(io.StringIO(proc.stdout)))
    if not rows:
        return [], []
    return rows[0], rows[1:]


def fnum(s):
    """Parse a CSV number; '' / NULL -> None."""
    if s is None or s == "" or s.upper() == "NULL":
        return None
    return float(s)


def fetch_run(args, run_id):
    """Fetch all result tables for one run into a dict."""
    d = {}

    _, rows = query(args, f"""
        select r.run_id, coalesce(r.label,''), r.preset, r.started_at,
               r.finished_at, r.server_version, r.config, r.settings
        from pgmb_results.run r where r.run_id = {run_id}""")
    if not rows:
        sys.exit(f"run {run_id} not found in pgmb_results.run")
    r = rows[0]
    d["meta"] = {
        "run_id": int(r[0]), "label": r[1], "preset": r[2],
        "started_at": r[3], "finished_at": r[4], "server_version": r[5],
        "config": json.loads(r[6]), "settings": json.loads(r[7]),
    }

    _, rows = query(args, f"""
        select kind, count(*), coalesce(round(sum(elapsed_ms)::numeric,1),0),
               coalesce(pg_size_pretty(sum(wal_bytes)),'')
        from pgmb_results.ddl_step where run_id = {run_id} group by kind""")
    d["ddl_stages"] = [{"stage": a, "steps": int(b), "ms": fnum(c), "wal": w}
                       for a, b, c, w in rows]

    _, rows = query(args, f"""
        select test_id, topic, kind, ord, round(elapsed_ms::numeric,1),
               coalesce(wal_bytes,0), coalesce(rel_bytes,0), coalesce(n_rows,0)
        from pgmb_results.ddl_step where run_id = {run_id} order by ord""")
    d["ddl_steps"] = [{"test_id": a, "topic": b, "kind": k, "ord": int(o),
                       "ms": fnum(m), "wal": int(w), "rel": int(rb),
                       "rows": int(n)} for a, b, k, o, m, w, rb, n in rows]

    _, rows = query(args, f"""
        select p.test_id, p.mode, p.clients, coalesce(p.transactions,0),
               coalesce(p.failed,0), p.tps, p.lat_avg_ms, p.lat_stddev_ms,
               l.p50_ms, l.p95_ms, l.p99_ms, l.max_ms
        from pgmb_results.perf p
        left join pgmb_results.latency l using (run_id, test_id)
        where p.run_id = {run_id} order by p.test_id""")
    d["perf"] = [{"test_id": a, "mode": b, "clients": int(c), "tx": int(t),
                  "failed": int(f), "tps": fnum(tp), "avg": fnum(av),
                  "std": fnum(sd), "p50": fnum(p50), "p95": fnum(p95),
                  "p99": fnum(p99), "mx": fnum(mx)}
                 for a, b, c, t, f, tp, av, sd, p50, p95, p99, mx in rows]

    _, rows = query(args, f"""
        select test_id, bucket, n from pgmb_results.latency_hist
        where run_id = {run_id}""")
    d["hist"] = {}
    for a, b, n in rows:
        d["hist"].setdefault(a, {})[int(b)] = int(n)

    _, rows = query(args, f"""
        select test_id, iterations, plan_ms_min, plan_ms_median, plan_ms_max,
               coalesce(mem_kb_max,0), distinct_plans, coalesce(plan_shape,'')
        from pgmb_results.planning where run_id = {run_id}
        order by plan_ms_median desc nulls last""")
    d["planning"] = [{"test_id": a, "n": int(b), "min": fnum(c),
                      "median": fnum(m), "max": fnum(mx), "mem": int(mb),
                      "plans": int(dp), "shape": sh}
                     for a, b, c, m, mx, mb, dp, sh in rows]

    _, rows = query(args, f"""
        select check_type, test_id, ok, coalesce(detail,'')
        from pgmb_results.checks where run_id = {run_id}
        order by check_type, test_id""")
    d["checks"] = [{"type": a, "test_id": b,
                    "ok": c in ("t", "true", "True", "1"), "detail": dt}
                   for a, b, c, dt in rows]
    return d


def fetch_test_sql(args, test_ids):
    """Fetch the registered SQL for a list of test ids -> {test_id: sql}."""
    if not test_ids:
        return {}
    ids = ",".join("'" + t.replace("'", "''") + "'" for t in test_ids)
    _, rows = query(args, f"select id, sql from pgmb.test where id in ({ids})")
    return {a: b for a, b in rows}


def top_diff(compare, n=10):
    """(gains, regressions): lists of (test_id, tps_a, tps_b, ratio b/a)."""
    pairs = []
    for tid in set(compare["a_perf"]) & set(compare["b_perf"]):
        ra = compare["a_perf"][tid]["tps"]
        rb = compare["b_perf"][tid]["tps"]
        if ra and rb:
            pairs.append((tid, ra, rb, rb / ra))
    pairs.sort(key=lambda p: p[3], reverse=True)
    return pairs[:n], list(reversed(pairs[-n:]))


# ---------------------------------------------------------------------------
# html helpers
# ---------------------------------------------------------------------------

def esc(s):
    return html.escape(str(s), quote=True)


def fmt(v, nd=1, dash="—"):
    if v is None:
        return dash
    return f"{v:,.{nd}f}"


def topic_of(test_id):
    return test_id.split(".", 1)[0]


def sparkline_svg(hist, width=192, height=30):
    """Inline SVG bar chart of the 24-bucket log-scale latency histogram."""
    if not hist:
        return '<span class="dim">—</span>'
    mx = max(hist.values())
    bw, gap = 7, 1
    parts = [f'<svg class="spark" width="{width}" height="{height}" '
             f'viewBox="0 0 {width} {height}" role="img">']
    for b in range(4, 28):
        n = hist.get(b, 0)
        x = (b - 4) * (bw + gap)
        if n == 0:
            continue
        h = max(2, round((height - 2) * (n / mx) ** 0.5))
        y = height - h
        # hue: green (fast, low bucket) -> red (slow, high bucket)
        hue = 140 - 140 * (b - 4) / 23
        lo = 10 ** (b / 4) / 1000
        hi = 10 ** ((b + 1) / 4) / 1000
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{h}" rx="1" '
            f'fill="hsl({hue:.0f},70%,55%)">'
            f'<title>{lo:g}–{hi:g} ms: {n} tx</title></rect>')
    parts.append("</svg>")
    return "".join(parts)


def ratio_cell(ratio, better_high=True):
    """Color-coded ratio badge. better_high: ratio>1 is good."""
    if ratio is None:
        return '<td class="num dim">—</td>'
    if ratio >= 1.05:
        cls = "good" if better_high else "bad"
    elif ratio <= 0.95:
        cls = "bad" if better_high else "good"
    else:
        cls = "neutral"
    return f'<td class="num {cls}">{ratio:.2f}</td>'


CSS = """
:root {
  --bg: #0d1117; --bg2: #161b22; --bg3: #1c2330;
  --fg: #e6edf3; --fg2: #9da7b3; --fg3: #6e7a8a;
  --line: #263041; --accent: #4da3ff; --accent2: #7ee0a3;
  --good: #3fb950; --bad: #f85149; --warn: #d29922;
  --mono: ui-monospace, "SF Mono", "Cascadia Code", Consolas, monospace;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
       font: 14px/1.5 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
.wrap { max-width: 1280px; margin: 0 auto; padding: 28px 24px 80px; }
header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 12px;
         margin-bottom: 6px; }
h1 { font-size: 24px; margin: 0; letter-spacing: .2px; }
.badge { display: inline-block; padding: 2px 10px; border-radius: 999px;
         font-size: 12px; font-weight: 600; background: var(--bg3);
         border: 1px solid var(--line); color: var(--fg2); }
.badge.accent { background: rgba(77,163,255,.15); border-color: rgba(77,163,255,.4);
                color: var(--accent); }
.meta { color: var(--fg2); font-size: 13px; margin-bottom: 22px; }
.meta code { font-family: var(--mono); color: var(--fg); background: var(--bg2);
             padding: 1px 6px; border-radius: 4px; font-size: 12px; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
         gap: 12px; margin: 18px 0 30px; }
.card { background: linear-gradient(180deg, var(--bg2), var(--bg));
        border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; }
.card .k { font-size: 11px; text-transform: uppercase; letter-spacing: .8px;
           color: var(--fg3); margin-bottom: 4px; }
.card .v { font-size: 22px; font-weight: 700; font-family: var(--mono); }
.card .s { font-size: 12px; color: var(--fg2); margin-top: 2px; }
.card.good .v { color: var(--good); } .card.bad .v { color: var(--bad); }
h2 { font-size: 17px; margin: 34px 0 12px; padding-bottom: 8px;
     border-bottom: 1px solid var(--line); display: flex; align-items: center; gap: 8px; }
h2 .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--accent); }
table { width: 100%; border-collapse: collapse; font-size: 13px;
        background: var(--bg2); border: 1px solid var(--line);
        border-radius: 10px; overflow: hidden; }
th, td { padding: 7px 10px; text-align: left; border-bottom: 1px solid var(--line);
         white-space: nowrap; }
th { background: var(--bg3); color: var(--fg2); font-size: 11px;
     text-transform: uppercase; letter-spacing: .6px; cursor: pointer;
     user-select: none; position: sticky; top: 0; }
th:hover { color: var(--fg); }
th .arr { color: var(--accent); font-size: 10px; }
tbody tr:hover { background: rgba(77,163,255,.06); }
td.num, th.num { text-align: right; font-family: var(--mono); font-size: 12.5px; }
td.test { font-family: var(--mono); font-size: 12.5px; }
td .topic { color: var(--fg3); }
.good { color: var(--good); font-weight: 600; }
.bad { color: var(--bad); font-weight: 600; }
.neutral { color: var(--fg2); }
.dim { color: var(--fg3); }
.spark { vertical-align: middle; }
.toolbar { display: flex; gap: 10px; margin: 0 0 10px; flex-wrap: wrap; }
.toolbar input, .toolbar select { background: var(--bg2); color: var(--fg);
    border: 1px solid var(--line); border-radius: 8px; padding: 7px 12px;
    font-size: 13px; outline: none; }
.toolbar input:focus, .toolbar select:focus { border-color: var(--accent); }
.toolbar .count { color: var(--fg3); font-size: 12px; align-self: center; }
.scroll { max-height: 640px; overflow: auto; border-radius: 10px;
          border: 1px solid var(--line); }
.scroll table { border: none; }
.stages { display: flex; flex-direction: column; gap: 8px; margin-bottom: 14px; }
.stage { display: grid; grid-template-columns: 130px 1fr 110px 90px; gap: 10px;
         align-items: center; font-size: 13px; }
.stage .name { color: var(--fg2); font-weight: 600; }
.stage .bar { background: var(--bg3); border-radius: 6px; height: 18px;
              overflow: hidden; }
.stage .bar i { display: block; height: 100%;
    background: linear-gradient(90deg, var(--accent), #7ee0a3);
    border-radius: 6px; }
.stage .ms { font-family: var(--mono); text-align: right; }
.stage .wal { color: var(--fg3); font-family: var(--mono); font-size: 12px;
              text-align: right; }
details { margin: 10px 0; }
summary { cursor: pointer; color: var(--accent); font-size: 13px;
          user-select: none; }
.pill { display: inline-block; padding: 1px 8px; border-radius: 999px;
        font-size: 11px; font-weight: 600; }
.pill.ok { background: rgba(63,185,80,.15); color: var(--good); }
.pill.fail { background: rgba(248,81,73,.15); color: var(--bad); }
tr.failrow { background: rgba(248,81,73,.08); }
tr.failrow:hover { background: rgba(248,81,73,.15); }
.sqlblock { background: var(--bg2); border: 1px solid var(--line);
            border-radius: 8px; padding: 10px 14px; margin: 8px 0 18px;
            font-family: var(--mono); font-size: 12.5px; line-height: 1.45;
            white-space: pre-wrap; word-break: break-word; color: var(--fg); }
.sqlblock .tid { display: block; color: var(--accent); font-weight: 600;
                 margin-bottom: 6px; font-size: 13px; }
.sqlblock .stats { display: block; color: var(--fg3); margin-top: 6px;
                   font-size: 11.5px; }
footer { margin-top: 40px; color: var(--fg3); font-size: 12px;
         border-top: 1px solid var(--line); padding-top: 14px; }
"""


JS = """
document.querySelectorAll('th[data-sort]').forEach(function (th) {
  th.addEventListener('click', function () {
    var table = th.closest('table');
    var tbody = table.tBodies[0];
    var idx = Array.prototype.indexOf.call(th.parentNode.children, th);
    var asc = th.dataset.asc !== '1';
    table.querySelectorAll('th[data-sort]').forEach(function (h) {
      h.dataset.asc = ''; h.querySelector('.arr')?.remove();
    });
    th.dataset.asc = asc ? '1' : '';
    var arr = document.createElement('span');
    arr.className = 'arr'; arr.textContent = asc ? ' ▲' : ' ▼';
    th.appendChild(arr);
    var rows = Array.from(tbody.rows);
    rows.sort(function (a, b) {
      var x = a.cells[idx].dataset.v ?? a.cells[idx].textContent;
      var y = b.cells[idx].dataset.v ?? b.cells[idx].textContent;
      var nx = parseFloat(x), ny = parseFloat(y);
      if (!isNaN(nx) && !isNaN(ny)) return asc ? nx - ny : ny - nx;
      return asc ? String(x).localeCompare(String(y))
                 : String(y).localeCompare(String(x));
    });
    rows.forEach(function (r) { tbody.appendChild(r); });
  });
});
function filterTable(id, inputId, selectId) {
  var tbody = document.querySelector('#' + id + ' tbody');
  var q = (document.getElementById(inputId)?.value || '').toLowerCase();
  var topic = document.getElementById(selectId)?.value || '';
  var shown = 0;
  Array.from(tbody.rows).forEach(function (r) {
    var text = r.textContent.toLowerCase();
    var ok = (!q || text.includes(q))
           && (!topic || r.dataset.topic === topic);
    r.style.display = ok ? '' : 'none';
    if (ok) shown++;
  });
  var c = document.getElementById(inputId + 'Count');
  if (c) c.textContent = shown + ' / ' + tbody.rows.length + ' tests';
}
"""


def sortable_th(label, num=False, key=""):
    cls = "num" if num else ""
    return f'<th data-sort class="{cls}">{label}<span class="arr"></span></th>'


def td_num(v, nd=1, data=None, cls=""):
    d = f' data-v="{data if data is not None else ("" if v is None else v)}"'
    return f'<td class="num {cls}"{d}>{fmt(v, nd)}</td>'


# ---------------------------------------------------------------------------
# sections
# ---------------------------------------------------------------------------

def section_header(title):
    return f'<h2><span class="dot"></span>{esc(title)}</h2>'


def kpi_cards(d):
    perf = d["perf"]
    tps = [p["tps"] for p in perf if p["tps"] is not None]
    p95 = [p["p95"] for p in perf if p["p95"] is not None]
    ddl_ms = sum(s["ms"] or 0 for s in d["ddl_steps"])
    checks = d["checks"]
    failed = [c for c in checks if not c["ok"]]
    cfg = d["meta"]["config"]
    cards = [
        ("Preset", esc(d["meta"]["preset"]),
         f"scale {cfg.get('data_scale', '?')} · {cfg.get('clients', '?')} clients"),
        ("DDL phase", f"{ddl_ms / 1000:.1f} s",
         f"{len(d['ddl_steps'])} steps"),
        ("Perf tests", str(len(perf)),
         f"Σ {sum(tps):,.0f} tps" if tps else "no results"),
        ("Median p95", f"{sorted(p95)[len(p95) // 2]:.2f} ms" if p95 else "—",
         "across all tests"),
        ("Planning", str(len(d["planning"])),
         f"max {max((p['median'] or 0) for p in d['planning']):.1f} ms"
         if d["planning"] else ""),
        ("Checks", f"{len(checks) - len(failed)}/{len(checks)}",
         "passed" if not failed else f"{len(failed)} FAILED",
         "good" if not failed else "bad"),
    ]
    out = ['<div class="cards">']
    for c in cards:
        name, val, sub = c[0], c[1], c[2]
        cls = c[3] if len(c) > 3 else ""
        out.append(f'<div class="card {cls}"><div class="k">{name}</div>'
                   f'<div class="v">{val}</div><div class="s">{sub}</div></div>')
    out.append("</div>")
    return "".join(out)


def ddl_section(d):
    stages = d["ddl_stages"]
    mx = max((s["ms"] or 0) for s in stages) or 1
    out = [section_header("DDL phase")]
    out.append('<div class="stages">')
    for s in stages:
        pct = 100 * (s["ms"] or 0) / mx
        out.append(
            f'<div class="stage"><span class="name">{esc(s["stage"])}</span>'
            f'<span class="bar"><i style="width:{pct:.1f}%"></i></span>'
            f'<span class="ms">{fmt(s["ms"], 1)} ms · {s["steps"]} steps</span>'
            f'<span class="wal">{esc(s["wal"])}</span></div>')
    out.append("</div>")
    out.append('<details><summary>all DDL steps</summary><div class="scroll">'
               '<table><thead><tr>'
               + sortable_th("step") + sortable_th("topic")
               + sortable_th("kind") + sortable_th("ms", num=True)
               + sortable_th("rows", num=True) + sortable_th("size", num=True)
               + sortable_th("wal", num=True) + "</tr></thead><tbody>")
    for s in d["ddl_steps"]:
        out.append(
            f'<tr><td class="test">{esc(s["test_id"])}</td>'
            f'<td><span class="topic">{esc(s["topic"])}</span></td>'
            f'<td>{esc(s["kind"])}</td>'
            f'<td class="num" data-v="{s["ms"]}">{fmt(s["ms"], 1)}</td>'
            f'<td class="num" data-v="{s["rows"]}">{s["rows"]:,}</td>'
            f'<td class="num dim">{s["rel"] / 1048576:.1f} MB</td>'
            f'<td class="num dim">{s["wal"] / 1048576:.1f} MB</td></tr>')
    out.append("</tbody></table></div></details>")
    return "".join(out)


def perf_section(d, compare=None):
    """compare: dict with 'a'/'b' perf lists keyed by test_id, or None."""
    out = [section_header("Performance (pgbench)")]
    topics = sorted({topic_of(p["test_id"]) for p in d["perf"]})
    opts = "".join(f'<option>{esc(t)}</option>' for t in topics)
    out.append('<div class="toolbar">'
               '<input id="perfQ" type="search" placeholder="filter tests…" '
               'oninput="filterTable(\'perfT\',\'perfQ\',\'perfTopic\')">'
               f'<select id="perfTopic" onchange="filterTable(\'perfT\',\'perfQ\',\'perfTopic\')">'
               f'<option value="">all topics</option>{opts}</select>'
               '<span class="count" id="perfQCount"></span></div>')
    out.append('<div class="scroll"><table id="perfT"><thead><tr>'
               + sortable_th("test"))
    if compare:
        out += [sortable_th("tps a", num=True), sortable_th("tps b", num=True),
                sortable_th("ratio b/a", num=True),
                sortable_th("p99 a", num=True), sortable_th("p99 b", num=True)]
    else:
        out += [sortable_th("tx", num=True), sortable_th("tps", num=True),
                sortable_th("avg", num=True), sortable_th("p50", num=True),
                sortable_th("p95", num=True), sortable_th("p99", num=True),
                sortable_th("max", num=True), sortable_th("histogram")]
    out.append("</tr></thead><tbody>")
    for p in d["perf"]:
        tid = p["test_id"]
        out.append(f'<tr data-topic="{esc(topic_of(tid))}">'
                   f'<td class="test">{esc(tid)}</td>')
        if compare:
            a = compare["a_perf"].get(tid)
            b = compare["b_perf"].get(tid)
            ra = (a["tps"] if a else None)
            rb = (b["tps"] if b else None)
            ratio = (rb / ra) if (ra and rb) else None
            out.append(td_num(ra, 1))
            out.append(td_num(rb, 1))
            out.append(ratio_cell(ratio, better_high=True))
            out.append(td_num(a["p99"] if a else None, nd=3))
            out.append(td_num(b["p99"] if b else None, nd=3))
        else:
            out.append(f'<td class="num" data-v="{p["tx"]}">{p["tx"]:,}</td>')
            out.append(td_num(p["tps"], 1))
            out.append(td_num(p["avg"], nd=3))
            out.append(td_num(p["p50"], nd=3))
            out.append(td_num(p["p95"], nd=3))
            out.append(td_num(p["p99"], nd=3))
            out.append(td_num(p["mx"], 1))
            out.append(f'<td>{sparkline_svg(d["hist"].get(tid, {}))}</td>')
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def planning_section(d, compare=None):
    out = [section_header("Planning")]
    out.append('<div class="scroll"><table><thead><tr>'
               + sortable_th("test"))
    if compare:
        out += [sortable_th("median a", num=True), sortable_th("median b", num=True),
                sortable_th("ratio a/b", num=True),
                sortable_th("plans a", num=True), sortable_th("plans b", num=True)]
    else:
        out += [sortable_th("n", num=True), sortable_th("min", num=True),
                sortable_th("median", num=True), sortable_th("max", num=True),
                sortable_th("mem", num=True), sortable_th("plans", num=True),
                sortable_th("shape")]
    out.append("</tr></thead><tbody>")
    for p in d["planning"]:
        tid = p["test_id"]
        out.append(f'<tr><td class="test">{esc(tid)}</td>')
        if compare:
            a = compare["a_pl"].get(tid)
            b = compare["b_pl"].get(tid)
            ma = a["median"] if a else None
            mb = b["median"] if b else None
            ratio = (ma / mb) if (ma and mb) else None
            out.append(td_num(ma, nd=3))
            out.append(td_num(mb, nd=3))
            out.append(ratio_cell(ratio, better_high=True))
            out.append(f'<td class="num">{a["plans"] if a else "—"}</td>')
            out.append(f'<td class="num">{b["plans"] if b else "—"}</td>')
        else:
            out.append(f'<td class="num">{p["n"]}</td>')
            out.append(td_num(p["min"], nd=3))
            out.append(td_num(p["median"], nd=3))
            out.append(td_num(p["max"], nd=3))
            out.append(f'<td class="num dim">{p["mem"] / 1024:.1f} MB</td>')
            out.append(f'<td class="num">{p["plans"]}</td>')
            out.append(f'<td class="dim" style="max-width:340px;overflow:hidden;'
                       f'text-overflow:ellipsis">{esc(p["shape"])}</td>')
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def checks_section(d):
    out = [section_header("Checks")]
    by_type = {}
    for c in d["checks"]:
        by_type.setdefault(c["type"], []).append(c)
    out.append('<div class="cards">')
    for t in sorted(by_type):
        cs = by_type[t]
        failed = [c for c in cs if not c["ok"]]
        cls = "bad" if failed else "good"
        out.append(f'<div class="card {cls}"><div class="k">{esc(t)}</div>'
                   f'<div class="v">{len(cs) - len(failed)}/{len(cs)}</div>'
                   f'<div class="s">{"all passed" if not failed else str(len(failed)) + " failed"}</div></div>')
    out.append("</div>")
    # per-test table, always shown; failed rows are highlighted
    out.append('<div class="toolbar">'
               '<input id="chkQ" type="search" placeholder="filter checks…" '
               'oninput="filterTable(\'chkT\',\'chkQ\',\'chkType\')">'
               '<select id="chkType" onchange="filterTable(\'chkT\',\'chkQ\',\'chkType\')">'
               '<option value="">all types</option>'
               + "".join(f'<option>{esc(t)}</option>' for t in sorted(by_type))
               + '</select>'
               '<span class="count" id="chkQCount"></span></div>')
    out.append('<div class="scroll"><table id="chkT"><thead><tr>'
               + sortable_th("type") + sortable_th("test")
               + sortable_th("result") + sortable_th("detail") + "</tr></thead><tbody>")
    for c in d["checks"]:
        pill = ('<span class="pill ok">pass</span>' if c["ok"]
                else '<span class="pill fail">fail</span>')
        row_cls = ' class="failrow"' if not c["ok"] else ""
        out.append(f'<tr data-topic="{esc(c["type"])}"{row_cls}>'
                   f'<td>{esc(c["type"])}</td>'
                   f'<td class="test">{esc(c["test_id"])}</td>'
                   f'<td>{pill}</td>'
                   f'<td class="dim" style="white-space:normal">'
                   f'{esc(c["detail"])}</td></tr>')
    out.append("</tbody></table></div>")
    return "".join(out)


def settings_section(d):
    s = d["meta"]["settings"]
    if not s:
        return ""
    items = "".join(
        f'<tr><td class="test">{esc(k)}</td><td>{esc(v)}</td></tr>'
        for k, v in sorted(s.items()))
    return (section_header("Non-default server settings")
            + f'<div class="scroll"><table><thead><tr><th>setting</th>'
              f'<th>value</th></tr></thead><tbody>{items}</tbody></table></div>')


def compare_settings_section(da, db):
    ka, kb = set(da["meta"]["settings"]), set(db["meta"]["settings"])
    rows = []
    for k in sorted(ka | kb):
        va = da["meta"]["settings"].get(k)
        vb = db["meta"]["settings"].get(k)
        if va is not None and vb is not None and va == vb:
            continue
        rows.append(f'<tr><td class="test">{esc(k)}</td>'
                    f'<td>{esc(va if va is not None else "—")}</td>'
                    f'<td>{esc(vb if vb is not None else "—")}</td></tr>')
    if not rows:
        return ""
    return (section_header("Settings that differ (a vs b)")
            + '<div class="scroll"><table><thead><tr><th>setting</th>'
              + '<th>a</th><th>b</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def compare_ddl_section(da, db):
    out = [section_header("DDL steps (a vs b)")]
    out.append('<div class="scroll"><table><thead><tr>'
               + sortable_th("step") + sortable_th("ms a", num=True)
               + sortable_th("ms b", num=True) + sortable_th("ratio a/b", num=True)
               + "</tr></thead><tbody>")
    ba = {s["test_id"]: s for s in da["ddl_steps"]}
    bb = {s["test_id"]: s for s in db["ddl_steps"]}
    for tid in sorted(set(ba) | set(bb), key=lambda t: (ba.get(t) or bb.get(t))["ord"]):
        a, b = ba.get(tid), bb.get(tid)
        ratio = (a["ms"] / b["ms"]) if (a and b and b["ms"]) else None
        out.append(f'<tr><td class="test">{esc(tid)}</td>'
                   + td_num(a["ms"] if a else None, 1)
                   + td_num(b["ms"] if b else None, 1)
                   + ratio_cell(ratio, better_high=True) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def compare_sql_section(compare, args, n=10):
    """SQL of the tests with the largest TPS differences between a and b."""
    gains, regs = top_diff(compare, n)
    if not gains and not regs:
        return ""
    out = [section_header(f"SQL of the most differing tests (top {n} by TPS ratio)")]
    sqls = fetch_test_sql(args, [p[0] for p in gains + regs])
    for label, pairs, better_high in (("Gains (b faster)", gains, True),
                                      ("Regressions (b slower)", regs, False)):
        if not pairs:
            continue
        out.append(f'<h3 style="margin:18px 0 4px;font-size:14px;'
                   f'color:var(--{"good" if better_high else "bad"})">{label}</h3>')
        for tid, ra, rb, ratio in pairs:
            sql = sqls.get(tid)
            if sql is None:
                continue
            out.append(
                f'<div class="sqlblock"><span class="tid">{esc(tid)}'
                f' <span class="dim">· ratio b/a {ratio:.2f}</span></span>'
                f'{esc(sql)}'
                f'<span class="stats">a: {ra:,.1f} tps · b: {rb:,.1f} tps</span></div>')
    return "".join(out)


def compare_checks_section(da, db):
    ca = {(c["test_id"], c["type"]): c["ok"] for c in da["checks"]}
    cb = {(c["test_id"], c["type"]): c["ok"] for c in db["checks"]}
    diff = [(k, ca.get(k), cb.get(k)) for k in set(ca) | set(cb)
            if ca.get(k) != cb.get(k)]
    if not diff:
        return (section_header("Checks")
                + '<p class="meta">no check outcome differs between the runs</p>')
    out = [section_header("Checks whose outcome differs"),
           '<table><thead><tr><th>test</th><th>type</th><th>a</th>'
           '<th>b</th></tr></thead><tbody>']
    for (tid, t), a, b in sorted(diff):
        out.append(f'<tr><td class="test">{esc(tid)}</td><td>{esc(t)}</td>'
                   f'<td><span class="pill {"ok" if a else "fail"}">'
                   f'{"pass" if a else "fail"}</span></td>'
                   f'<td><span class="pill {"ok" if b else "fail"}">'
                   f'{"pass" if b else "fail"}</span></td></tr>')
    out.append("</tbody></table>")
    return "".join(out)


# ---------------------------------------------------------------------------
# page assembly
# ---------------------------------------------------------------------------

def meta_line(d):
    m = d["meta"]
    cfg = m["config"]
    bits = [f"started <code>{m['started_at']}</code>",
            f"server <code>{esc(m['server_version'])}</code>",
            f"preset <code>{esc(m['preset'])}</code>",
            f"scale <code>{esc(cfg.get('data_scale', '?'))}</code>",
            f"clients <code>{esc(cfg.get('clients', '?'))}</code>",
            f"mode <code>{esc(cfg.get('mode', '?'))}</code>",
            f"protocol <code>{esc(cfg.get('protocol', '?'))}</code>"]
    if m["label"]:
        bits.insert(0, f"label <code>{esc(m['label'])}</code>")
    return " · ".join(bits)


def build_page(d, compare=None, args=None):
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    if compare:
        title = f"pg_microbenchmark — run {compare['b']['meta']['run_id']} vs {compare['a']['meta']['run_id']}"
        header = (f'<header><h1>{esc(title)}</h1>'
                  f'<span class="badge accent">comparison</span></header>'
                  f'<div class="meta">a (baseline): {meta_line(compare["a"])}<br>'
                  f'b (candidate): {meta_line(compare["b"])}</div>')
        body = (compare_settings_section(compare["a"], compare["b"])
                + kpi_cards(compare["b"])
                + compare_ddl_section(compare["a"], compare["b"])
                + perf_section(compare["b"], compare)
                + planning_section(compare["b"], compare)
                + compare_sql_section(compare, args)
                + compare_checks_section(compare["a"], compare["b"]))
    else:
        m = d["meta"]
        title = f"pg_microbenchmark — run {m['run_id']}"
        header = (f'<header><h1>{esc(title)}</h1>'
                  f'<span class="badge accent">{esc(m["preset"])}</span>'
                  + (f'<span class="badge">{esc(m["label"])}</span>'
                     if m["label"] else "")
                  + "</header>"
                  f'<div class="meta">{meta_line(d)}</div>')
        body = (kpi_cards(d) + ddl_section(d) + perf_section(d)
                + planning_section(d) + checks_section(d)
                + settings_section(d))
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
{header}
{body}
<footer>generated {now} by report_html.py · data from pgmb_results ·
click column headers to sort · ratio &gt; 1 means b is better
(more tps, less time)</footer>
</div>
<script>{JS}</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--run", type=int, help="run id (default: latest)")
    p.add_argument("--compare", action="store_true",
                   help="compare two runs instead of a single report")
    p.add_argument("--a", type=int, help="baseline run id (default: latest)")
    p.add_argument("--b", type=int, help="candidate run id (default: latest)")
    p.add_argument("--out", type=Path, help="output HTML file "
                   "(default: report_run<N>.html or report_compare_A_B.html)")
    p.add_argument("--db", default="bench")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    p.add_argument("--user")
    p.add_argument("--psql", default="psql")
    return p


def latest_run(args):
    _, rows = query(args, "select max(run_id) from pgmb_results.run")
    if not rows or not rows[0][0]:
        sys.exit("no runs found in pgmb_results.run")
    return int(rows[0][0])


def main():
    args = build_parser().parse_args()

    if args.compare:
        a = args.a or latest_run(args)
        b = args.b or latest_run(args)
        if a == b:
            sys.exit("--a and --b must differ")
        da, db = fetch_run(args, a), fetch_run(args, b)
        compare = {"a": da, "b": db,
                   "a_perf": {p["test_id"]: p for p in da["perf"]},
                   "b_perf": {p["test_id"]: p for p in db["perf"]},
                   "a_pl": {p["test_id"]: p for p in da["planning"]},
                   "b_pl": {p["test_id"]: p for p in db["planning"]}}
        page = build_page(db, compare, args)
        out = args.out or REPO / f"report_compare_{a}_{b}.html"
    else:
        run_id = args.run or latest_run(args)
        d = fetch_run(args, run_id)
        page = build_page(d)
        out = args.out or REPO / f"report_run{run_id}.html"

    out.write_text(page, encoding="utf-8")
    print(f"HTML report written to {out} ({out.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
