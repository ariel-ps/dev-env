#!/usr/bin/env python3
"""csv_to_html — render a CSV as a self-contained interactive HTML report.

Stdlib only. Produces one HTML file with:
  * per-column profile cards (type, missing, unique, stats, mini chart)
  * a sortable / searchable / paginated data table

Usage:
    python3 csv_to_html.py data.csv [-o out.html] [--open]
    cat data.csv | python3 csv_to_html.py - -o out.html
"""

import argparse
import csv
import html
import io
import json
import math
import os
import re
import sys
import webbrowser
from collections import Counter
from datetime import datetime

# --- palette (dataviz reference instance) -----------------------------------
SEQ_LIGHT = "#2a78d6"  # categorical slot 1 / sequential blue, light surface
SEQ_DARK = "#3987e5"

NUM_RE = re.compile(r"^[+-]?(\d{1,3}(,\d{3})+|\d*)(\.\d+)?([eE][+-]?\d+)?$")
PCT_RE = re.compile(r"^[+-]?[\d,]*\.?\d+\s*%$")
CURRENCY_RE = re.compile(r"^[-+]?[$€£₪¥]\s*[\d,]*\.?\d+$|^[\d,]*\.?\d+\s*[$€£₪¥]$")
BOOL_VALUES = {"true", "false", "yes", "no", "y", "n", "t", "f", "0", "1"}
DATE_FORMATS = (
    "%Y-%m-%d", "%Y/%m/%d", "%d/%m/%Y", "%m/%d/%Y", "%d-%m-%Y", "%d.%m.%Y",
    "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%SZ",
    "%Y-%m-%d %H:%M", "%b %d %Y", "%d %b %Y", "%Y-%m",
)
NULLS = {"", "na", "n/a", "nan", "null", "none", "nil", "-", "--"}


def is_null(v):
    return v is None or str(v).strip().lower() in NULLS


def to_number(v):
    s = str(v).strip()
    if PCT_RE.match(s):
        s = s.rstrip("%").strip()
    elif CURRENCY_RE.match(s):
        s = re.sub(r"[$€£₪¥\s]", "", s)
    if not NUM_RE.match(s) or s in ("", "+", "-", "."):
        return None
    try:
        return float(s.replace(",", ""))
    except ValueError:
        return None


def to_date(v):
    s = str(v).strip()
    if len(s) < 6 or len(s) > 32:
        return None
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


# --- reading ----------------------------------------------------------------

def read_csv(path, delimiter=None, encoding=None):
    if path == "-":
        raw = sys.stdin.buffer.read()
        name = "stdin"
    else:
        with open(path, "rb") as fh:
            raw = fh.read()
        name = os.path.basename(path)

    text = None
    for enc in ([encoding] if encoding else ["utf-8-sig", "utf-8", "cp1252", "latin-1"]):
        try:
            text = raw.decode(enc)
            break
        except (UnicodeDecodeError, LookupError):
            continue
    if text is None:
        raise SystemExit("csv_to_html: could not decode file; pass --encoding")

    if delimiter is None:
        sample = text[:64 * 1024]
        try:
            delimiter = csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
        except csv.Error:
            counts = {d: sample.count(d) for d in ",;\t|"}
            delimiter = max(counts, key=counts.get) if max(counts.values()) else ","

    rows = list(csv.reader(io.StringIO(text), delimiter=delimiter))
    rows = [r for r in rows if any(c.strip() for c in r)]
    if not rows:
        raise SystemExit("csv_to_html: file has no rows")

    header = [h.strip() or f"column_{i + 1}" for i, h in enumerate(rows[0])]
    seen, cols = Counter(), []
    for h in header:
        seen[h] += 1
        cols.append(h if seen[h] == 1 else f"{h}_{seen[h]}")

    width = len(cols)
    body = [(r + [""] * width)[:width] for r in rows[1:]]
    return name, delimiter, cols, body


# --- profiling --------------------------------------------------------------

def profile_column(name, values):
    present = [v for v in values if not is_null(v)]
    missing = len(values) - len(present)
    uniq = len(set(present))

    nums = [to_number(v) for v in present]
    num_ok = [n for n in nums if n is not None]
    dates = [to_date(v) for v in present] if present else []
    date_ok = [d for d in dates if d is not None]
    lowered = {str(v).strip().lower() for v in present}

    col = {
        "name": name, "count": len(values), "missing": missing, "unique": uniq,
        "type": "empty", "stats": [], "chart": None,
    }
    if not present:
        return col

    if len(num_ok) / len(present) >= 0.85:
        col["type"] = "integer" if all(float(n).is_integer() for n in num_ok) else "number"
        col["numeric"] = True
        srt = sorted(num_ok)
        mean = sum(srt) / len(srt)
        var = sum((x - mean) ** 2 for x in srt) / len(srt)
        col["stats"] = [
            ("min", fmt_num(srt[0])), ("median", fmt_num(percentile(srt, 0.5))),
            ("max", fmt_num(srt[-1])), ("mean", fmt_num(mean)),
            ("std", fmt_num(math.sqrt(var))), ("sum", fmt_num(sum(srt))),
        ]
        col["chart"] = histogram(srt)
    elif len(date_ok) / len(present) >= 0.85:
        col["type"] = "date"
        srt = sorted(date_ok)
        col["stats"] = [
            ("earliest", srt[0].strftime("%Y-%m-%d")),
            ("latest", srt[-1].strftime("%Y-%m-%d")),
            ("span", f"{(srt[-1] - srt[0]).days} d"),
        ]
        col["chart"] = histogram([d.timestamp() for d in srt],
                                 labeler=lambda t: datetime.fromtimestamp(t).strftime("%Y-%m-%d"))
    elif lowered <= BOOL_VALUES and uniq <= 2:
        col["type"] = "boolean"
        col["chart"] = top_values(present)
    else:
        col["type"] = "category" if uniq <= max(20, len(present) * 0.15) else "text"
        lens = [len(str(v)) for v in present]
        col["stats"] = [
            ("distinct", str(uniq)),
            ("mode", str(Counter(present).most_common(1)[0][0])[:40]),
            ("avg len", str(round(sum(lens) / len(lens), 1))),
        ]
        # near-unique text (ids, names, free text): top values say nothing —
        # chart the length distribution instead.
        if uniq > 0.6 * len(present):
            col["chart"] = histogram(sorted(lens), labeler=lambda x: f"{x:.0f} chars")
        else:
            col["chart"] = top_values(present)
    return col


def percentile(srt, q):
    if not srt:
        return 0.0
    k = (len(srt) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return srt[int(k)] if lo == hi else srt[lo] * (hi - k) + srt[hi] * (k - lo)


def fmt_num(x):
    if x is None:
        return "—"
    if x != x or x in (float("inf"), float("-inf")):
        return str(x)
    if abs(x) >= 1e7 or (0 < abs(x) < 1e-4):
        return f"{x:.3g}"
    if float(x).is_integer():
        return f"{int(x):,}"
    return f"{x:,.4g}"


def histogram(srt, bins=24, labeler=fmt_num):
    lo, hi = srt[0], srt[-1]
    if hi == lo:  # constant column — a full-width bar would say nothing
        return {"kind": "flat", "bars": [{"label": labeler(lo), "value": len(srt),
                                          "sub": f"every row is {labeler(lo)}"}]}
    step = (hi - lo) / bins
    counts = [0] * bins
    for v in srt:
        idx = min(int((v - lo) / step), bins - 1)
        counts[idx] += 1
    return {"kind": "hist", "bars": [
        {"label": labeler(lo + i * step), "value": c,
         "sub": f"{labeler(lo + i * step)} – {labeler(lo + (i + 1) * step)}"}
        for i, c in enumerate(counts)]}


def top_values(present, k=8):
    common = Counter(str(v).strip() for v in present).most_common(k)
    total = len(present)
    bars = [{"label": lbl[:36], "value": n, "sub": f"{n:,} rows · {n / total:.1%}"} for lbl, n in common]
    rest = total - sum(n for _, n in common)
    if rest > 0:
        bars.append({"label": "Other", "value": rest, "sub": f"{rest:,} rows · {rest / total:.1%}"})
    return {"kind": "bars", "bars": bars}


# --- rendering --------------------------------------------------------------

CSS = """
*,*::before,*::after{box-sizing:border-box}
:root{color-scheme:light;
 --surface-0:#f6f5f2;--surface-1:#fcfcfb;--border:#e2e0da;--border-strong:#cbc8bf;
 --text-primary:#0b0b0b;--text-secondary:#52514e;--text-muted:#7c7a73;
 --series-1:%(seq_light)s;--accent-soft:#e8f0fc;--grid:#eeece7;}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;
 --surface-0:#111110;--surface-1:#1a1a19;--border:#2f2f2c;--border-strong:#45443f;
 --text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#8d8c83;
 --series-1:%(seq_dark)s;--accent-soft:#1d2b3d;--grid:#26261f;}}
:root[data-theme="dark"]{color-scheme:dark;
 --surface-0:#111110;--surface-1:#1a1a19;--border:#2f2f2c;--border-strong:#45443f;
 --text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#8d8c83;
 --series-1:%(seq_dark)s;--accent-soft:#1d2b3d;--grid:#26261f;}
body{margin:0;background:var(--surface-0);color:var(--text-primary);
 font:14px/1.5 ui-sans-serif,-apple-system,"SF Pro Text",Segoe UI,Roboto,sans-serif;
 -webkit-font-smoothing:antialiased}
.wrap{max-width:1400px;margin:0 auto;padding:28px 20px 64px}
header{display:flex;flex-wrap:wrap;gap:16px;align-items:baseline;justify-content:space-between;margin-bottom:6px}
h1{font-size:20px;margin:0;font-weight:650;letter-spacing:-.01em}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--text-muted);
 font-weight:600;margin:34px 0 12px}
.sub{color:var(--text-secondary);font-size:13px;margin:0}
.tags{display:flex;gap:8px;flex-wrap:wrap;margin:14px 0 0}
.tag{background:var(--surface-1);border:1px solid var(--border);border-radius:999px;
 padding:3px 10px;font-size:12px;color:var(--text-secondary)}
button{font:inherit;color:var(--text-primary);background:var(--surface-1);
 border:1px solid var(--border);border-radius:8px;padding:6px 12px;cursor:pointer}
button:hover{border-color:var(--border-strong)}
.cards{display:grid;gap:14px;align-items:start;grid-template-columns:repeat(auto-fill,minmax(290px,1fr))}
.card{background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px 15px}
.card-head{display:flex;justify-content:space-between;align-items:center;gap:8px}
.card-name{font-weight:620;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.type{font-size:11px;padding:2px 7px;border-radius:6px;background:var(--accent-soft);
 color:var(--text-secondary);border:1px solid var(--border);white-space:nowrap}
.meta{color:var(--text-muted);font-size:12px;margin:3px 0 10px}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:6px 10px;margin-top:10px}
.stats div{min-width:0}
.stats dt{font-size:11px;color:var(--text-muted);margin:0}
.stats dd{font-size:13px;margin:0;font-variant-numeric:tabular-nums;
 overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chart{width:100%%;height:74px;display:block}
.chart rect{fill:var(--series-1)}
.chart rect:hover{fill:var(--text-primary)}
.chart .track{fill:var(--grid)}
.flat{margin:2px 0 0;font-size:12px;color:var(--text-secondary)}
.blabels{margin-top:6px;display:grid;gap:3px}
.blabel{display:flex;justify-content:space-between;gap:10px;font-size:12px;color:var(--text-secondary)}
.blabel span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.blabel span:last-child{font-variant-numeric:tabular-nums;color:var(--text-muted);flex:none}
.toolbar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:10px}
input[type=search],select{font:inherit;color:var(--text-primary);background:var(--surface-1);
 border:1px solid var(--border);border-radius:8px;padding:6px 10px}
input[type=search]{min-width:240px;flex:1 1 240px}
.count{color:var(--text-muted);font-size:12px;margin-left:auto}
.tablebox{overflow:auto;max-height:70vh;border:1px solid var(--border);
 border-radius:12px;background:var(--surface-1)}
table{border-collapse:separate;border-spacing:0;width:100%%;font-size:13px}
th,td{padding:7px 12px;text-align:left;border-bottom:1px solid var(--border);white-space:nowrap}
th{position:sticky;top:0;z-index:2;background:var(--surface-1);cursor:pointer;
 font-weight:600;color:var(--text-secondary);border-bottom:1px solid var(--border-strong)}
th:hover{color:var(--text-primary)}
th .dir{color:var(--text-muted);font-size:10px}
td.num{text-align:right;font-variant-numeric:tabular-nums}
td.idx{color:var(--text-muted);font-variant-numeric:tabular-nums;
 position:sticky;left:0;background:var(--surface-1)}
th.idx{left:0;z-index:3}
tbody tr:hover td{background:var(--accent-soft)}
td.null{color:var(--text-muted);font-style:italic}
.pager{display:flex;gap:8px;align-items:center;margin-top:10px;font-size:13px;color:var(--text-secondary)}
.note{color:var(--text-muted);font-size:12px;margin-top:8px}
"""

JS = """
const D = JSON.parse(document.getElementById('data').textContent);
const numeric = new Set(D.numericCols);
const tbody = document.querySelector('#grid tbody');
const search = document.getElementById('q');
const perPage = document.getElementById('per');
const count = document.getElementById('count');
const pageLbl = document.getElementById('pagelbl');
let sortCol = null, sortDir = 1, page = 0, view = D.rows.map((r,i)=>[i,r]);

function apply(){
  const q = search.value.trim().toLowerCase();
  view = D.rows.map((r,i)=>[i,r]);
  if(q){
    const terms = q.split(/\\s+/);
    view = view.filter(([,r])=>{const s=r.join(' ').toLowerCase();return terms.every(t=>s.includes(t));});
  }
  if(sortCol !== null){
    const c = sortCol, isNum = numeric.has(c);
    view.sort((a,b)=>{
      let x=a[1][c], y=b[1][c];
      if(isNum){x=parseFloat(String(x).replace(/[^0-9eE.+-]/g,''));y=parseFloat(String(y).replace(/[^0-9eE.+-]/g,''));
        if(isNaN(x)&&isNaN(y))return 0; if(isNaN(x))return 1; if(isNaN(y))return -1; return (x-y)*sortDir;}
      return String(x).localeCompare(String(y),undefined,{numeric:true,sensitivity:'base'})*sortDir;
    });
  }
  page = 0; render();
}

function render(){
  const per = perPage.value === 'all' ? view.length : parseInt(perPage.value,10);
  const pages = Math.max(1, Math.ceil(view.length/Math.max(per,1)));
  page = Math.min(page, pages-1);
  const slice = view.slice(page*per, page*per+per);
  const frag = document.createDocumentFragment();
  for(const [i,r] of slice){
    const tr = document.createElement('tr');
    const idx = document.createElement('td');
    idx.className = 'idx'; idx.textContent = i+1; tr.appendChild(idx);
    r.forEach((v,c)=>{
      const td = document.createElement('td');
      if(v === '' || v === null){ td.className='null'; td.textContent='—'; }
      else { if(numeric.has(c)) td.className='num'; td.textContent=v; td.title=v; }
      tr.appendChild(td);
    });
    frag.appendChild(tr);
  }
  tbody.replaceChildren(frag);
  count.textContent = view.length.toLocaleString() + ' of ' + D.rows.length.toLocaleString() + ' rows';
  pageLbl.textContent = 'page ' + (page+1) + ' / ' + pages;
}

document.querySelectorAll('#grid th[data-c]').forEach(th=>{
  th.addEventListener('click',()=>{
    const c = +th.dataset.c;
    sortDir = (sortCol === c) ? -sortDir : 1; sortCol = c;
    document.querySelectorAll('#grid th .dir').forEach(d=>d.textContent='');
    th.querySelector('.dir').textContent = sortDir>0 ? '▲' : '▼';
    apply();
  });
});
search.addEventListener('input', ()=>{clearTimeout(window._t); window._t=setTimeout(apply,120);});
perPage.addEventListener('change', render);
document.getElementById('prev').onclick = ()=>{ if(page>0){page--;render();} };
document.getElementById('next').onclick = ()=>{ page++; render(); };
document.getElementById('theme').onclick = ()=>{
  const cur = document.documentElement.dataset.theme
    || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  document.documentElement.dataset.theme = cur === 'dark' ? 'light' : 'dark';
};
render();
"""


def svg_chart(chart):
    """Vertical histogram or horizontal top-value bars, as inline SVG."""
    if not chart or not chart["bars"]:
        return ""
    bars = chart["bars"]
    peak = max(b["value"] for b in bars) or 1
    parts = []
    if chart["kind"] == "flat":
        return f'<p class="flat">{html.escape(bars[0]["sub"])}</p>'
    if chart["kind"] == "hist":
        w, h, gap = 100.0, 74.0, 2.0
        bw = max((w - gap * (len(bars) - 1)) / len(bars), 0.5)
        for i, b in enumerate(bars):
            bh = max(h * b["value"] / peak, 1.5) if b["value"] else 0
            if not bh:
                continue
            x = i * (bw + gap)
            parts.append(
                f'<rect x="{x:.2f}" y="{h - bh:.2f}" width="{bw:.2f}" height="{bh:.2f}" rx="2">'
                f'<title>{html.escape(b["sub"])} — {b["value"]:,} rows</title></rect>')
        return (f'<svg class="chart" viewBox="0 0 {w:g} {h:g}" preserveAspectRatio="none" '
                f'role="img" aria-label="distribution">{"".join(parts)}</svg>')

    rows = bars[:9]
    rh, gap = 12.0, 5.0
    h = len(rows) * rh + (len(rows) - 1) * gap
    labels = []
    for i, b in enumerate(rows):
        y = i * (rh + gap)
        bw = max(100.0 * b["value"] / peak, 1.0)
        parts.append(f'<rect class="track" x="0" y="{y:.2f}" width="100" height="{rh}" rx="3"/>')
        parts.append(f'<rect x="0" y="{y:.2f}" width="{bw:.2f}" height="{rh}" rx="3">'
                     f'<title>{html.escape(b["label"])} — {html.escape(b["sub"])}</title></rect>')
        labels.append(f'<div class="blabel"><span>{html.escape(b["label"])}</span>'
                      f'<span>{b["value"]:,}</span></div>')
    svg = (f'<svg class="chart" style="height:{h:.0f}px" viewBox="0 0 100 {h:.2f}" '
           f'preserveAspectRatio="none" role="img" aria-label="top values">{"".join(parts)}</svg>')
    return svg + f'<div class="blabels">{"".join(labels)}</div>'


def render_card(col, total):
    pct = (col["missing"] / total * 100) if total else 0
    stats = "".join(
        f'<div><dt>{html.escape(k)}</dt><dd title="{html.escape(v)}">{html.escape(v)}</dd></div>'
        for k, v in col["stats"])
    return f"""<div class="card">
  <div class="card-head"><div class="card-name" title="{html.escape(col['name'])}">{html.escape(col['name'])}</div>
    <div class="type">{col['type']}</div></div>
  <p class="meta">{col['unique']:,} unique · {col['missing']:,} missing ({pct:.1f}%)</p>
  {svg_chart(col['chart'])}
  {f'<dl class="stats">{stats}</dl>' if stats else ''}
</div>"""


def build_html(title, source, delimiter, cols, rows, profiles, embedded, truncated):
    numeric_cols = [i for i, c in enumerate(profiles) if c.get("numeric")]
    payload = json.dumps({"rows": embedded, "numericCols": numeric_cols},
                         ensure_ascii=False).replace("<", "\\u003c")
    head = "".join(
        f'<th data-c="{i}" title="{html.escape(c)} ({profiles[i]["type"]})">'
        f'{html.escape(c)} <span class="dir"></span></th>' for i, c in enumerate(cols))
    delim_label = {"\t": "tab", " ": "space"}.get(delimiter, delimiter)
    note = (f'<p class="note">Table shows the first {len(embedded):,} of {len(rows):,} rows; '
            f'column profiles above are computed over all {len(rows):,}.</p>') if truncated else ""
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
<style>{CSS % {"seq_light": SEQ_LIGHT, "seq_dark": SEQ_DARK}}</style>
</head><body><div class="wrap">
<header>
  <div>
    <h1>{html.escape(title)}</h1>
    <p class="sub">{html.escape(source)}</p>
  </div>
  <button id="theme">Toggle theme</button>
</header>
<div class="tags">
  <span class="tag">{len(rows):,} rows</span>
  <span class="tag">{len(cols)} columns</span>
  <span class="tag">delimiter “{html.escape(delim_label)}”</span>
  <span class="tag">generated {datetime.now().strftime('%Y-%m-%d %H:%M')}</span>
</div>

<h2>Columns</h2>
<div class="cards">{"".join(render_card(c, len(rows)) for c in profiles)}</div>

<h2>Data</h2>
<div class="toolbar">
  <input type="search" id="q" placeholder="Filter rows (space-separated terms)…" aria-label="Filter rows">
  <select id="per" aria-label="Rows per page">
    <option>50</option><option selected>100</option><option>250</option>
    <option>1000</option><option value="all">all</option>
  </select>
  <span class="count" id="count"></span>
</div>
<div class="tablebox"><table id="grid">
  <thead><tr><th class="idx">#</th>{head}</tr></thead><tbody></tbody>
</table></div>
<div class="pager">
  <button id="prev">← prev</button><button id="next">next →</button>
  <span id="pagelbl"></span>
</div>
{note}
</div>
<script type="application/json" id="data">{payload}</script>
<script>{JS}</script>
</body></html>"""


def main():
    ap = argparse.ArgumentParser(prog="csv_to_html", description="Render a CSV as interactive HTML.")
    ap.add_argument("csv", help="CSV path, or - for stdin")
    ap.add_argument("-o", "--output", help="output HTML path (default: <input>.html)")
    ap.add_argument("-t", "--title", help="report title (default: file name)")
    ap.add_argument("-d", "--delimiter", help="force delimiter (default: sniff)")
    ap.add_argument("--encoding", help="force input encoding")
    ap.add_argument("--max-rows", type=int, default=5000,
                    help="max rows embedded in the table (default 5000; 0 = all)")
    ap.add_argument("--open", action="store_true", help="open the report in the browser")
    args = ap.parse_args()

    name, delimiter, cols, rows = read_csv(args.csv, args.delimiter, args.encoding)
    profiles = [profile_column(c, [r[i] for r in rows]) for i, c in enumerate(cols)]

    limit = len(rows) if args.max_rows in (0, None) else min(args.max_rows, len(rows))
    embedded, truncated = rows[:limit], limit < len(rows)

    out = args.output or (name.rsplit(".", 1)[0] + ".html" if args.csv != "-" else "csv-report.html")
    if args.csv != "-" and not args.output:
        out = os.path.splitext(os.path.abspath(args.csv))[0] + ".html"

    doc = build_html(args.title or name, f"{name} · {len(rows):,} rows × {len(cols)} columns",
                     delimiter, cols, rows, profiles, embedded, truncated)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(doc)

    size = os.path.getsize(out)
    print(f"csv_to_html: wrote {out} ({size / 1024:.0f} KB, {len(rows):,} rows × {len(cols)} cols)")
    if args.open:
        webbrowser.open("file://" + os.path.abspath(out))


if __name__ == "__main__":
    main()
