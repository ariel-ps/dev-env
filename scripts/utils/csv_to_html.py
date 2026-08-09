#!/usr/bin/env python3
"""csv_to_html — render a CSV as a self-contained interactive HTML table.

Stdlib only. Produces one full-width HTML file: sortable, searchable,
paginated. Column types are inferred only to sort numbers as numbers.

Usage:
    python3 csv_to_html.py data.csv [-o out.html] [--open]
    cat data.csv | python3 csv_to_html.py - -o out.html
"""

import argparse
import csv
import html
import io
import json
import os
import re
import sys
import webbrowser
from collections import Counter
from datetime import datetime

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


def column_type(values):
    """Infer a column's type — only 'numeric' changes behaviour (sort + align)."""
    present = [v for v in values if not is_null(v)]
    if not present:
        return "empty", False

    num_ok = [n for n in (to_number(v) for v in present) if n is not None]
    if len(num_ok) / len(present) >= 0.85:
        kind = "integer" if all(float(n).is_integer() for n in num_ok) else "number"
        return kind, True

    date_ok = [d for d in (to_date(v) for v in present) if d is not None]
    if len(date_ok) / len(present) >= 0.85:
        return "date", False

    if {str(v).strip().lower() for v in present} <= BOOL_VALUES and len(set(present)) <= 2:
        return "boolean", False

    uniq = len(set(present))
    return ("category" if uniq <= max(20, len(present) * 0.15) else "text"), False


# --- rendering --------------------------------------------------------------

CSS = """
*,*::before,*::after{box-sizing:border-box}
:root{color-scheme:light;
 --surface-0:#f6f5f2;--surface-1:#fcfcfb;--border:#e2e0da;--border-strong:#cbc8bf;
 --text-primary:#0b0b0b;--text-secondary:#52514e;--text-muted:#7c7a73;--accent-soft:#e8f0fc;}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;
 --surface-0:#111110;--surface-1:#1a1a19;--border:#2f2f2c;--border-strong:#45443f;
 --text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#8d8c83;--accent-soft:#1d2b3d;}}
:root[data-theme="dark"]{color-scheme:dark;
 --surface-0:#111110;--surface-1:#1a1a19;--border:#2f2f2c;--border-strong:#45443f;
 --text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#8d8c83;--accent-soft:#1d2b3d;}
html,body{height:100%}
body{margin:0;background:var(--surface-0);color:var(--text-primary);
 font:14px/1.5 ui-sans-serif,-apple-system,"SF Pro Text",Segoe UI,Roboto,sans-serif;
 -webkit-font-smoothing:antialiased}
.wrap{height:100%;display:flex;flex-direction:column;padding:14px 16px 12px;gap:10px}
header{display:flex;flex-wrap:wrap;gap:10px 14px;align-items:baseline}
h1{font-size:16px;margin:0;font-weight:650;letter-spacing:-.01em}
.sub{color:var(--text-muted);font-size:12px;margin:0}
.toolbar{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
button,input[type=search],select{font:inherit;color:var(--text-primary);background:var(--surface-1);
 border:1px solid var(--border);border-radius:8px;padding:6px 10px}
button{cursor:pointer;padding:6px 12px}
button:hover{border-color:var(--border-strong)}
input[type=search]{min-width:260px;flex:1 1 320px}
.count{color:var(--text-muted);font-size:12px;margin-left:auto;white-space:nowrap}
.tablebox{flex:1 1 auto;min-height:0;overflow:auto;border:1px solid var(--border);
 border-radius:10px;background:var(--surface-1)}
table{border-collapse:separate;border-spacing:0;width:100%;font-size:13px}
th,td{padding:6px 12px;text-align:left;border-bottom:1px solid var(--border)}
th{position:sticky;top:0;z-index:2;background:var(--surface-1);cursor:pointer;white-space:nowrap;
 font-weight:600;color:var(--text-secondary);border-bottom:1px solid var(--border-strong)}
th:hover{color:var(--text-primary)}
th .dir{color:var(--text-muted);font-size:10px}
/* long values wrap onto more lines instead of being cut off */
td{vertical-align:top;max-width:60ch;white-space:pre-wrap;overflow-wrap:anywhere}
td.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
td.idx,th.idx{position:sticky;left:0;background:var(--surface-1);white-space:nowrap;
 color:var(--text-muted);font-variant-numeric:tabular-nums}
th.idx{z-index:3}
tbody tr:hover td{background:var(--accent-soft)}
td.null{color:var(--text-muted)}
.pager{display:flex;gap:8px;align-items:center;font-size:12px;color:var(--text-secondary)}
.note{color:var(--text-muted);font-size:12px;margin-left:auto}
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


SERVE_JS = """
const live = document.getElementById('live');
document.getElementById('reload').onclick = ()=>location.reload();
setInterval(()=>{ if(live.checked) location.reload(); }, 5000);
live.checked = new URLSearchParams(location.search).get('live') === '1';
live.onchange = ()=>{
  const u = new URL(location.href);
  live.checked ? u.searchParams.set('live','1') : u.searchParams.delete('live');
  history.replaceState(null,'',u);
};
"""


def build_html(title, cols, types, numeric_cols, rows, embedded, truncated, served=False):
    payload = json.dumps({"rows": embedded, "numericCols": numeric_cols},
                         ensure_ascii=False).replace("<", "\\u003c")
    head = "".join(
        f'<th data-c="{i}" title="{html.escape(c)} ({types[i]})">'
        f'{html.escape(c)} <span class="dir"></span></th>' for i, c in enumerate(cols))
    note = (f'<span class="note">first {len(embedded):,} of {len(rows):,} rows '
            f'(raise with --max-rows)</span>') if truncated else ""
    controls = f"""
  <span class="sub">read {datetime.now().strftime('%H:%M:%S')}</span>
  <button id="reload">Reload file</button>
  <label class="sub"><input type="checkbox" id="live"> auto every 5s</label>""" if served else ""
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
<style>{CSS}</style>
</head><body><div class="wrap">
<header>
  <h1>{html.escape(title)}</h1>
  <p class="sub">{len(rows):,} rows × {len(cols)} columns</p>{controls}
  <button id="theme" style="margin-left:auto">Toggle theme</button>
</header>
<div class="toolbar">
  <input type="search" id="q" placeholder="Filter rows (space-separated terms)…" aria-label="Filter rows">
  <select id="per" aria-label="Rows per page">
    <option>100</option><option selected>250</option><option>1000</option>
    <option value="all">all</option>
  </select>
  <span class="count" id="count"></span>
</div>
<div class="tablebox"><table id="grid">
  <thead><tr><th class="idx">#</th>{head}</tr></thead><tbody></tbody>
</table></div>
<div class="pager">
  <button id="prev">← prev</button><button id="next">next →</button>
  <span id="pagelbl"></span>{note}
</div>
</div>
<script type="application/json" id="data">{payload}</script>
<script>{JS}{SERVE_JS if served else ""}</script>
</body></html>"""


def render(args, cached_rows=None, served=False):
    """Parse the CSV (or reuse an already-parsed one) and return (name, html)."""
    if cached_rows is None:
        name, _, cols, rows = read_csv(args.csv, args.delimiter, args.encoding)
    else:
        name, cols, rows = cached_rows

    types, numeric_cols = [], []
    for i, c in enumerate(cols):
        kind, is_num = column_type([r[i] for r in rows])
        types.append(kind)
        if is_num:
            numeric_cols.append(i)

    limit = len(rows) if args.max_rows in (0, None) else min(args.max_rows, len(rows))
    doc = build_html(args.title or name, cols, types, numeric_cols, rows,
                     rows[:limit], limit < len(rows), served=served)
    return name, doc, cols, rows


def serve(args):
    """Serve the CSV on localhost, re-reading the file on every request."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    # stdin can only be read once — parse it up front and serve that snapshot.
    cached = None
    if args.csv == "-":
        name, _, cols, rows = read_csv(args.csv, args.delimiter, args.encoding)
        cached = (name, cols, rows)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            if self.path.split("?")[0] not in ("/", "/index.html"):
                self.send_error(404)
                return
            try:
                _, doc, _, _ = render(args, cached_rows=cached, served=True)
            except SystemExit as exc:  # unreadable/empty file — keep the server up
                doc = f"<!DOCTYPE html><meta charset=utf-8><pre>{html.escape(str(exc))}</pre>"
            body = doc.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *a):  # one line per request, not three
            sys.stderr.write(f"csv_to_html: {self.address_string()} {fmt % a}\n")

    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as exc:
        if args.port and exc.errno in (48, 98):  # address already in use
            httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        else:
            raise SystemExit(f"csv_to_html: cannot bind port {args.port}: {exc}")

    url = f"http://127.0.0.1:{httpd.server_port}/"
    src = "stdin (snapshot)" if cached else os.path.abspath(args.csv)
    print(f"csv_to_html: serving {src} at {url}  (ctrl-c to stop)", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\ncsv_to_html: stopped")
    finally:
        httpd.server_close()


def main():
    ap = argparse.ArgumentParser(prog="csv_to_html", description="Render a CSV as interactive HTML.")
    ap.add_argument("csv", help="CSV path, or - for stdin")
    ap.add_argument("-o", "--output", help="output HTML path (default: <input>.html)")
    ap.add_argument("-t", "--title", help="report title (default: file name)")
    ap.add_argument("-d", "--delimiter", help="force delimiter (default: sniff)")
    ap.add_argument("--encoding", help="force input encoding")
    ap.add_argument("--max-rows", type=int, default=5000,
                    help="max rows embedded in the table (default 5000; 0 = all)")
    ap.add_argument("-s", "--serve", action="store_true",
                    help="serve on 127.0.0.1 instead of writing a file; "
                         "the CSV is re-read on every request")
    ap.add_argument("-p", "--port", type=int, default=8787,
                    help="port for --serve (default 8787; 0 picks a free one)")
    ap.add_argument("--open", action="store_true", help="open the report in the browser")
    ap.add_argument("--no-open", action="store_true", help="with --serve, do not open a browser")
    args = ap.parse_args()

    if args.serve:
        serve(args)
        return

    name, doc, cols, rows = render(args)

    if args.output:
        out = args.output
    elif args.csv == "-":
        out = "csv-report.html"
    else:
        out = os.path.splitext(os.path.abspath(args.csv))[0] + ".html"

    with open(out, "w", encoding="utf-8") as fh:
        fh.write(doc)

    size = os.path.getsize(out)
    print(f"csv_to_html: wrote {out} ({size / 1024:.0f} KB, {len(rows):,} rows × {len(cols)} cols)")
    if args.open:
        webbrowser.open("file://" + os.path.abspath(out))


if __name__ == "__main__":
    main()
