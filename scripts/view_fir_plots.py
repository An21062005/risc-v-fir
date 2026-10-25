#!/usr/bin/env python3
# -*- coding: utf-8 -*-
'view_fir_plots.py - xem nhanh đồ thị FIR RTL vs Python trong trình duyệt.'

import argparse
import html
import re
import subprocess
import sys
import webbrowser
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PLOT_DIR = PROJECT_ROOT / "data_test" / "fir_test" / "rtl_plots"
PLOT_SCRIPT = PROJECT_ROOT / "scripts" / "plot_fir_rtl_results.py"
TESTS = ["test_01_low", "test_02_high", "test_03_mixed",
         "test_04_noise", "test_05_impulse", "test_06_step"]
IMAGES = [("time_domain.png", "Miền thời gian"),
          ("frequency_domain.png", "Miền tần số (FFT)"),
          ("error.png", "Sai số RTL: actual − expected")]

CSS = """
:root { --surface:#fcfcfb; --page:#f9f9f7; --ink:#0b0b0b; --ink2:#52514e; --muted:#898781;
        --grid:#e1e0d9; --good:#0ca30c; --crit:#d03b3b; }
* { box-sizing: border-box; }
body { margin:0; background:var(--page); color:var(--ink);
       font:15px/1.5 "Segoe UI", system-ui, sans-serif; }
header { position:sticky; top:0; background:var(--surface); border-bottom:1px solid var(--grid);
         padding:10px 24px; display:flex; flex-wrap:wrap; gap:6px 14px; align-items:center; z-index:1; }
header b { margin-right:8px; }
nav a { color:var(--ink2); text-decoration:none; padding:3px 9px; border-radius:6px; }
nav a:hover { background:var(--grid); }
nav a.cur { background:var(--ink); color:var(--surface); }
main { max-width:1500px; margin:0 auto; padding:20px 24px 60px; }
h1 { font-size:22px; margin:6px 0 4px; }
h2 { font-size:17px; margin:28px 0 8px; }
.sub { color:var(--ink2); margin:0 0 14px; }
.badge { display:inline-block; padding:1px 9px; border-radius:6px; border:1.5px solid; font-weight:600;
         font-size:13px; color:var(--ink); background:var(--surface); }
.badge.pass { border-color:var(--good); } .badge.fail { border-color:var(--crit); }
table { border-collapse:collapse; background:var(--surface); border:1px solid var(--grid); }
th, td { padding:7px 12px; border-bottom:1px solid var(--grid); text-align:left; }
th { color:var(--ink2); font-weight:600; font-size:13px; }
td.num { text-align:right; font-variant-numeric:tabular-nums; }
figure { margin:0 0 22px; background:var(--surface); border:1px solid var(--grid); border-radius:8px;
         padding:10px; }
figure img { width:100%; height:auto; display:block; }
figcaption { color:var(--ink2); font-size:13px; margin-top:6px; }
pre { background:var(--surface); border:1px solid var(--grid); border-radius:8px; padding:12px 14px;
      overflow-x:auto; font:13px/1.45 Consolas, "Cascadia Mono", monospace; }
a { color:#2a78d6; }
"""


def parse_summary():
    """Trích từ summary.txt: khối số liệu từng test, trạng thái, tổng kết."""
    path = PLOT_DIR / "summary.txt"
    if not path.is_file():
        sys.exit(f"LỖI: không có {path}. Chạy: python scripts/plot_fir_rtl_results.py")
    text = path.read_text(encoding="utf-8")
    blocks, status = {}, {}
    for name in TESTS:
        m = re.search(rf"^\[{name}\][^\n]*\n(?:  [^\n]*\n)*", text, flags=re.M)
        if m:
            blocks[name] = "\n".join(l for l in m.group(0).rstrip().splitlines()
                                     if "->" not in l)
        m = re.search(rf"^\s*\[(PASS|FAIL|ERROR)\] {name}: ([^\n]*)$", text, flags=re.M)
        if m:
            status[name] = (m.group(1), m.group(2))
    gains = {}
    for m in re.finditer(r"^\s+(test_\d\d_\w+)\s+(\d+)\s+[\d.]+\s+[\d.]+\s+([+-][\d.]+)\s+([+-][\d.]+)",
                         text, flags=re.M):
        gains.setdefault(m.group(1), {})[int(m.group(2))] = (m.group(3), m.group(4))
    total = re.search(r"^\s*Tổng: ([^\n]*)$", text.split("TỔNG KẾT BIT-EXACT")[-1], flags=re.M)
    filt = text.split("HIỆU QUẢ LỌC")[-1].split("TỔNG KẾT BIT-EXACT")[0] if "HIỆU QUẢ LỌC" in text else ""
    return blocks, status, gains, (total.group(1) if total else "?"), filt.strip("=\n ")


def badge(st):
    kind, _ = st if st else ("ERROR", "")
    ok = kind == "PASS"
    label = "✓ BIT-EXACT PASS" if ok else ("✗ FAIL" if kind == "FAIL" else "✗ ERROR")
    return f'<span class="badge {"pass" if ok else "fail"}">{label}</span>'


def page(title, nav_cur, body, depth):
    up = "../" * depth
    links = [f'<a href="{up}index.html" class="{"cur" if nav_cur is None else ""}">Tổng quan</a>']
    for t in TESTS:
        links.append(f'<a href="{up}{t}/index.html" class="{"cur" if nav_cur == t else ""}">{t}</a>')
    return (f'<!doctype html><html lang="vi"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{html.escape(title)}</title><style>{CSS}</style></head><body>'
            f'<header><b>FIR11 RTL vs Python</b><nav>{"".join(links)}</nav></header>'
            f'<main>{body}</main></body></html>')


def build(blocks, status, gains, total, filt):
    rows = []
    for t in TESTS:
        st = status.get(t)
        g = gains.get(t, {})
        cell = lambda f: (f'{g[f][0]} <span style="color:var(--muted)">/ {g[f][1]}</span>'
                          if f in g else '<span style="color:var(--muted)">—</span>')
        rows.append(f'<tr><td><a href="{t}/index.html">{t}</a></td><td>{badge(st)}</td>'
                    f'<td>{html.escape(st[1]) if st else "thiếu dữ liệu"}</td>'
                    f'<td class="num">{cell(500)}</td><td class="num">{cell(4000)}</td></tr>')
    comp = PLOT_DIR / "fir_rtl_comparison.svg"
    if not comp.is_file():
        comp = PLOT_DIR / "fir_rtl_comparison.png"
    body = (f'<h1>Kết quả FIR11 RTL so với mô hình Python</h1>'
            f'<p class="sub">Tổng: {html.escape(total)}. Nguồn: outfeed/&lt;test&gt;/actual.dat '
            f'(RTL) và data_test/fir_test/output/ (Python).</p>'
            f'<table><tr><th>Test</th><th>Bit-exact</th><th>Chi tiết</th>'
            f'<th>Gain 500 Hz (dB)<br>đo RTL / lý thuyết</th>'
            f'<th>Gain 4000 Hz (dB)<br>đo RTL / lý thuyết</th></tr>{"".join(rows)}</table>')
    if comp.is_file():
        body += (f'<h2>Tổng hợp mixed + noise</h2><figure><img src="{comp.name}" '
                 f'alt="So sánh mixed và noise"><figcaption>{comp.name}</figcaption></figure>')
    if filt:
        body += f'<h2>Hiệu quả lọc</h2><pre>{html.escape(filt)}</pre>'
    body += '<h2>Báo cáo đầy đủ</h2><p><a href="summary.txt">summary.txt</a></p>'
    (PLOT_DIR / "index.html").write_text(page("FIR11 RTL - tổng quan", None, body, 0), encoding="utf-8")

    for i, t in enumerate(TESTS):
        tdir = PLOT_DIR / t
        if not tdir.is_dir():
            continue
        body = f'<h1>{t} {badge(status.get(t))}</h1>'
        if t in blocks:
            body += f'<pre>{html.escape(blocks[t])}</pre>'
        for fname, cap in IMAGES:
            if (tdir / fname).with_suffix(".svg").is_file():
                fname = Path(fname).with_suffix(".svg").name     # vector: nét ở mọi mức zoom
            if (tdir / fname).is_file():
                body += (f'<h2>{cap}</h2><figure><img src="{fname}" alt="{cap} - {t}">'
                         f'<figcaption>rtl_plots/{t}/{fname}</figcaption></figure>')
            else:
                body += f'<h2>{cap}</h2><p>Thiếu {fname}</p>'
        prev_t, next_t = TESTS[i - 1] if i else None, TESTS[i + 1] if i + 1 < len(TESTS) else None
        body += '<p>' + (f'<a href="../{prev_t}/index.html">← {prev_t}</a> ' if prev_t else '') + \
                (f' <a href="../{next_t}/index.html">{next_t} →</a>' if next_t else '') + '</p>'
        (tdir / "index.html").write_text(page(f"FIR11 RTL - {t}", t, body, 1), encoding="utf-8")


def show_window(target):
    """Vẽ lại bằng chính các hàm fig_* của plot_fir_rtl_results.py trong cửa sổ Tk tương tác."""
    import matplotlib
    matplotlib.use("TkAgg")
    sys.dont_write_bytecode = True                      # không tạo scripts/__pycache__
    sys.path.insert(0, str(PLOT_SCRIPT.parent))
    import plot_fir_rtl_results as P
    import matplotlib.pyplot as plt
    try:
        coeff = P.read_hls_coefficients()
        if target:
            r = P.load_test(target, coeff)
            figs = [(P.fig_time_domain(r), "miền thời gian"),
                    (P.fig_frequency_domain(r, coeff), "miền tần số"),
                    (P.fig_error(r), "sai số")]
        else:
            results = {t: P.load_test(t, coeff) for t in ("test_03_mixed", "test_04_noise")}
            figs = [(P.fig_comparison(results, coeff), "tổng hợp mixed + noise")]
    except (P.DataError, OSError) as e:
        sys.exit(f"LỖI: {e}")
    for fig, what in figs:
        fig.canvas.manager.set_window_title(f"{target or 'FIR11'} - {what}")
    print("Đã mở cửa sổ đồ thị: dùng thanh công cụ để zoom (kính lúp), pan (mũi tên 4 chiều), "
          "Home để về ban đầu, đĩa mềm để lưu. Đóng hết cửa sổ để thoát.")
    plt.show()


def resolve_test(arg):
    a = arg.lower().removeprefix("test_")
    for t in TESTS:
        num, kind = t.split("_")[1], t.split("_", 2)[2]
        if a in (t[5:], num, str(int(num)), kind):
            return t
    sys.exit(f"Không nhận ra test '{arg}'. Gõ số 1-6: "
             + ", ".join(f"{i} = {t}" for i, t in enumerate(TESTS, 1)))


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except AttributeError:
            pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("test", nargs="?", help="số test 1-6 cần mở (mặc định: trang tổng quan)")
    ap.add_argument("--regen", action="store_true", help="chạy plot_fir_rtl_results.py trước")
    ap.add_argument("--list", action="store_true", help="liệt kê test và trạng thái rồi thoát")
    ap.add_argument("--no-open", action="store_true", help="chỉ sinh HTML, không mở trình duyệt")
    ap.add_argument("--window", action="store_true",
                    help="mở cửa sổ đồ thị tương tác (zoom/pan) thay cho trình duyệt")
    args = ap.parse_args()
    target = resolve_test(args.test) if args.test else None

    if args.regen:
        rc = subprocess.call([sys.executable, str(PLOT_SCRIPT)])
        if rc not in (0, 1):            # 1 = có test FAIL: vẫn mở để xem
            sys.exit(rc)
    if args.window:
        show_window(target)
        return
    blocks, status, gains, total, filt = parse_summary()
    if args.list:
        for i, t in enumerate(TESTS, 1):
            st = status.get(t, ("ERROR", "không có trong summary.txt"))
            print(f"  {i}  [{st[0]:5}] {t}: {st[1]}")
        print(f"  Tổng: {total}")
        return
    build(blocks, status, gains, total, filt)
    page_path = (PLOT_DIR / target / "index.html") if target else (PLOT_DIR / "index.html")
    print(f"HTML: {page_path}")
    if not args.no_open:
        webbrowser.open(page_path.resolve().as_uri())


if __name__ == "__main__":
    main()
