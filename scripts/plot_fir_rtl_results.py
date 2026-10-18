#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
plot_fir_rtl_results.py
=======================
Phân tích và trực quan hóa kết quả mô phỏng FIR11 RTL (tb_fir11_vectors.v).

Nguồn dữ liệu (đường dẫn tính từ project root, không phụ thuộc thư mục chạy):
    data_test/fir_test/output/<test>/input.dat     x[n]      (Python generator)
    data_test/fir_test/output/<test>/expected.dat  y_ref[n]  (Python, hệ số fir.cpp)
    outfeed/<test>/actual.dat                      y_rtl[n]  (RTL; scripts/run_rtl_tests.py
                                                    truyền +OUT_DIR=<project>/outfeed)
    hls/FIR11/FIR11/fir.cpp                        hệ số c[] cho đáp ứng lý thuyết

Đầu ra (chỉ ghi vào data_test/fir_test/rtl_plots/):
    <test>/time_domain.png, <test>/frequency_domain.png, <test>/error.png
    fir_rtl_comparison.png (mixed + noise), summary.txt
    Mỗi hình có bản .png (200 dpi) và .svg (vector) cùng tên.
    Xem trong cửa sổ tương tác (zoom/pan): python scripts/view_fir_plots.py <1-6> --window

Quy ước:
    - So sánh bit-exact: số nguyên Python, error[n] = actual[n] - expected[n], không
      tolerance, không dịch/căn chỉnh chuỗi, không làm tròn.
    - Output chia SCALE = 1000 CHỈ để hiển thị / đo biên độ; dữ liệu gốc giữ nguyên.
    - Độ lợi đo bằng fit bình phương tối thiểu đồng thời (DC + các tần số có trong
      input) trên đoạn ổn định n >= 10 (bỏ quá độ FIR 10 mẫu), không đọc bin FFT
      nên không bị rò rỉ phổ. Chỉ đo tại tần số mà input thực sự chứa.

Chạy:  python scripts/plot_fir_rtl_results.py      (exit 0 = mọi test bit-exact)
"""

import re
import sys
from pathlib import Path

import numpy as np
import matplotlib
import matplotlib.pyplot as plt     # backend: Agg khi lưu file (main), TkAgg khi xem cửa sổ

# =============================================================================
# Cấu hình
# =============================================================================
PROJECT_ROOT = Path(__file__).resolve().parent.parent
FIR_TEST_DIR = PROJECT_ROOT / "data_test" / "fir_test"
REF_DIR = FIR_TEST_DIR / "output"
OUTFEED_DIR = PROJECT_ROOT / "outfeed"
PLOT_DIR = FIR_TEST_DIR / "rtl_plots"
FIR_CPP = PROJECT_ROOT / "hls" / "FIR11" / "FIR11" / "fir.cpp"

FS = 10000
SCALE = 1000
NUM_SAMPLES = 1000
NUM_TAPS = 11
TRANSIENT = NUM_TAPS - 1          # 10 mẫu quá độ đầu (lịch sử FIR = 0)
F_LOW, F_HIGH = 500, 4000
IMPULSE_AMP = 1000
STEP_POSITION = 100
INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1
DPI = 200                         # PNG; mỗi hình cũng được lưu dạng SVG (vector)

# tên -> (mô tả, loại, các tần số input chứa, vùng phóng to [a, b))
TESTS = {
    "test_01_low":     ("Sin 500 Hz",                     "sine",    [F_LOW],         (400, 550)),
    "test_02_high":    ("Sin 4000 Hz",                    "sine",    [F_HIGH],        (400, 450)),
    "test_03_mixed":   ("500 Hz + 4000 Hz",               "sine",    [F_LOW, F_HIGH], (400, 550)),
    "test_04_noise":   ("500 Hz + 4000 Hz + nhiễu Gauss", "sine",    [F_LOW, F_HIGH], (400, 550)),
    "test_05_impulse": ("Đáp ứng xung (x[0] = 1000)",     "impulse", [],              (0, 30)),
    "test_06_step":    ("Đáp ứng bước (x[n>=100] = 1000)", "step",   [],              (90, 130)),
}

# Bảng màu: 3 slot categorical đầu của palette tham chiếu (đã validate all-pairs),
# status palette cho PASS/FAIL (luôn kèm ký hiệu + chữ), mực/khung trung tính.
C_IN, C_EXP, C_ACT = "#2a78d6", "#eb6834", "#1baf7a"
C_GOOD, C_CRIT = "#0ca30c", "#d03b3b"
INK, INK2, MUTED = "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, SURFACE = "#e1e0d9", "#c3c2b7", "#fcfcfb"

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": INK2, "axes.linewidth": 1.0, "axes.labelcolor": INK, "axes.titlecolor": INK,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False,
    "xtick.color": INK2, "ytick.color": INK2, "xtick.labelcolor": INK, "ytick.labelcolor": INK,
    "text.color": INK, "legend.frameon": True, "legend.framealpha": 0.94,
    "legend.edgecolor": AXIS, "legend.facecolor": SURFACE, "font.size": 11.5,
    "axes.titlesize": 12.5, "axes.titleweight": "bold", "axes.labelsize": 12,
    "xtick.labelsize": 11, "ytick.labelsize": 11, "legend.fontsize": 10.5,
    "lines.antialiased": True, "svg.fonttype": "path",
})


class DataError(Exception):
    """Dữ liệu thiếu hoặc không hợp lệ."""


# =============================================================================
# Đọc và kiểm tra dữ liệu
# =============================================================================
INT_RE = re.compile(r"^[+-]?\d+$")


def read_dat(path):
    """Đúng NUM_SAMPLES số nguyên thập phân có dấu, mỗi dòng một số, trong int32."""
    if not path.is_file():
        raise DataError(f"không tìm thấy {rel(path)}")
    lines = path.read_text(encoding="ascii", errors="strict").splitlines()
    vals = []
    for i, line in enumerate(lines, 1):
        s = line.strip()
        if not INT_RE.match(s):
            raise DataError(f"{rel(path)}:{i}: không phải số nguyên thập phân: {line!r}")
        v = int(s)
        if not INT32_MIN <= v <= INT32_MAX:
            raise DataError(f"{rel(path)}:{i}: {v} ngoài phạm vi signed 32-bit")
        vals.append(v)
    if len(vals) != NUM_SAMPLES:
        raise DataError(f"{rel(path)}: {len(vals)} mẫu, cần đúng {NUM_SAMPLES}")
    return vals


def read_hls_coefficients():
    """Hệ số c[] trong fir.cpp; đối chiếu với output/coeff.dat của generator."""
    src = FIR_CPP.read_text(encoding="utf-8", errors="replace")
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    m = re.findall(r"\bcoef_t\s+c\s*\[[^\]]*\]\s*=\s*\{([^}]*)\}", src)
    if len(m) != 1:
        raise DataError(f"không xác định được mảng c[] trong {rel(FIR_CPP)}")
    c = [int(t, 0) for t in m[0].split(",") if t.strip()]
    if len(c) != NUM_TAPS:
        raise DataError(f"c[] có {len(c)} phần tử, cần {NUM_TAPS}")
    gen = [int(l) for l in (REF_DIR / "coeff.dat").read_text().split()]
    if gen != c:
        raise DataError(f"hệ số fir.cpp {c} khác output/coeff.dat {gen}")
    return np.array(c, dtype=np.int64)


def rel(p):
    try:
        return Path(p).resolve().relative_to(PROJECT_ROOT).as_posix()
    except ValueError:
        return str(p)


# =============================================================================
# Phân tích
# =============================================================================
def h_theory(coeff, freqs):
    """|H(f)| lý thuyết của hệ số HLS, chuẩn hóa /SCALE."""
    f = np.atleast_1d(np.asarray(freqs, dtype=float))
    k = np.arange(len(coeff))
    h = np.exp(-2j * np.pi * np.outer(f, k) / FS) @ coeff.astype(float)
    return np.abs(h) / SCALE


def tone_fit(x, freqs):
    """
    Fit đồng thời x ~ DC + sum_f (a_f cos + b_f sin) trên đoạn ổn định n >= TRANSIENT.
    Trả về {f: (biên độ, sai số chuẩn của biên độ)}.
    """
    seg = np.asarray(x[TRANSIENT:], dtype=float)
    n = np.arange(TRANSIENT, TRANSIENT + len(seg))
    cols = [np.ones(len(seg))]
    for f in freqs:
        w = 2 * np.pi * f / FS
        cols += [np.cos(w * n), np.sin(w * n)]
    A = np.column_stack(cols)
    coef, *_ = np.linalg.lstsq(A, seg, rcond=None)
    resid = seg - A @ coef
    sigma = np.sqrt(np.sum(resid ** 2) / max(len(seg) - A.shape[1], 1))
    se = sigma * np.sqrt(2.0 / len(seg))
    return {f: (float(np.hypot(coef[1 + 2 * i], coef[2 + 2 * i])), float(se))
            for i, f in enumerate(freqs)}


def db(v):
    return 20.0 * np.log10(np.maximum(np.abs(v), 1e-12))


def hann_spectrum(x):
    """Phổ biên độ một phía, cửa sổ Hann, bỏ quá độ; sin biên độ A -> đỉnh ~A."""
    seg = np.asarray(x[TRANSIENT:], dtype=float)
    w = np.hanning(len(seg))
    amp = 2.0 * np.abs(np.fft.rfft(seg * w)) / np.sum(w)
    amp[0] /= 2.0
    return np.fft.rfftfreq(len(seg), 1.0 / FS), amp


def raw_dft(x):
    """|DFT| không cửa sổ, toàn bộ 1000 mẫu (impulse/step: cửa sổ sẽ xóa/méo xung)."""
    return np.fft.rfftfreq(len(x), 1.0 / FS), np.abs(np.fft.rfft(np.asarray(x, dtype=float)))


def analyze(name, x, y_exp, y_act, coeff):
    desc, kind, freqs, zoom = TESTS[name]
    xi = np.array(x, dtype=np.int64)
    ye = np.array(y_exp, dtype=np.int64)
    ya = np.array(y_act, dtype=np.int64)
    err = ya - ye                                   # int64: không tràn với int32 - int32
    mism = np.flatnonzero(err)
    r = {"name": name, "desc": desc, "kind": kind, "freqs": freqs, "zoom": zoom,
         "x": xi, "y_exp": ye, "y_act": ya, "err": err, "mism": mism,
         "n": NUM_SAMPLES, "n_match": NUM_SAMPLES - len(mism),
         "max_abs_err": int(np.max(np.abs(err))) if len(err) else 0,
         "bit_exact": len(mism) == 0, "gains": {}}
    if freqs:
        a_in = tone_fit(xi, freqs)
        a_exp = tone_fit(ye / SCALE, freqs)
        a_act = tone_fit(ya / SCALE, freqs)
        h_th = h_theory(coeff, freqs)
        for i, f in enumerate(freqs):
            ai, ao, se = a_in[f][0], a_act[f][0], a_act[f][1]
            r["gains"][f] = {
                "a_in": ai, "a_out_act": ao, "a_out_exp": a_exp[f][0], "se_out": se,
                "g_act_db": float(db(ao / ai)), "g_exp_db": float(db(a_exp[f][0] / ai)),
                "g_th_db": float(db(h_th[i])), "g_se_db": float(20 / np.log(10) * se / ao) if ao else float("nan"),
            }
    if kind == "impulse":
        f, X = raw_dft(xi)
        _, Ya = raw_dft(ya / SCALE)
        k = {fq: int(round(fq * NUM_SAMPLES / FS)) for fq in (F_LOW, F_HIGH)}
        r["impulse_h"] = {fq: (float(db(Ya[k[fq]] / X[k[fq]])), float(db(h_theory(coeff, fq)[0])))
                          for fq in (F_LOW, F_HIGH)}
    if kind == "step":
        settled = ya[STEP_POSITION + NUM_TAPS:] / SCALE
        r["dc_gain"] = (float(np.mean(settled) / xi[-1]), float(np.sum(coeff)) / SCALE,
                        bool(np.all(settled == settled[0])))
    return r


# =============================================================================
# Vẽ  (fig_* trả về Figure: dùng chung cho lưu file và cửa sổ tương tác)
# =============================================================================
ANNOT = 10.5        # cỡ chữ chú thích trên hình
LW_IN, LW_EXP, LW_ACT, LW_REF = 1.5, 2.6, 2.0, 1.6
DASH_ACT = (0, (5, 3))


def t_ms(n):
    return np.asarray(n) * 1000.0 / FS


def status_badge(ax, r, loc=(0.01, 0.97)):
    if r["bit_exact"]:
        txt, col = f"✓ BIT-EXACT PASS  {r['n_match']}/{r['n']} mẫu", C_GOOD
    else:
        txt, col = f"✗ FAIL  {r['n_match']}/{r['n']} mẫu khớp", C_CRIT
    ax.text(*loc, txt, transform=ax.transAxes, ha="left", va="top", fontsize=11,
            fontweight="bold", color=INK,
            bbox=dict(boxstyle="round,pad=0.4", fc=SURFACE, ec=col, lw=2.0), zorder=10)


def draw_time(ax, r, sl, zoom_view):
    n = np.arange(r["n"])[sl]
    t = t_ms(n)
    x, ye, ya = r["x"][sl], r["y_exp"][sl] / SCALE, r["y_act"][sl] / SCALE
    if r["kind"] in ("impulse", "step"):
        ax.step(t, x, where="post", color=C_IN, lw=LW_IN + 0.3, label="Input x[n]")
    else:
        ax.plot(t, x, color=C_IN, lw=LW_IN, label="Input x[n]")
    ax.plot(t, ye, color=C_EXP, lw=LW_EXP, label="Expected (Python) / SCALE", zorder=3)
    if zoom_view:
        ax.plot(t, ya, ls="none", marker="o", ms=7, mfc="none", mec=C_ACT, mew=1.8,
                label="Actual (RTL) / SCALE", zorder=4)
    else:
        ax.plot(t, ya, color=C_ACT, lw=LW_ACT, ls=DASH_ACT, label="Actual (RTL) / SCALE", zorder=4)
    ax.set_xlabel("Thời gian (ms)")
    ax.set_ylabel("Biên độ (đơn vị mẫu)")
    ax.set_xlim(t[0], t[-1] + (t[1] - t[0]))


def fig_time_domain(r):
    a, b = r["zoom"]
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 9), gridspec_kw={"height_ratios": [1, 1.15]})
    draw_time(ax1, r, slice(0, r["n"]), zoom_view=False)
    ax1.axvspan(t_ms(a), t_ms(b), color=GRID, alpha=0.7, lw=0, zorder=0)
    ax1.set_title(f"Toàn bộ {r['n']} mẫu (vùng xám = đoạn phóng to bên dưới)")
    ax1.legend(loc="upper right", ncol=3)
    status_badge(ax1, r)
    draw_time(ax2, r, slice(a, b), zoom_view=True)
    ax2.set_title(f"Phóng to mẫu {a}–{b - 1} ({b - a} mẫu, {t_ms(a):g}–{t_ms(b):g} ms)\n"
                  "đường cam = Expected, vòng tròn xanh ngọc = Actual RTL")
    ax2.legend(loc="lower right" if r["kind"] == "step" else "upper right", ncol=3)
    fig.suptitle(f"{r['name']} — {r['desc']}: miền thời gian\n(FS = {FS} Hz; output chia "
                 f"SCALE = {SCALE} chỉ để hiển thị)", fontsize=14, fontweight="bold", color=INK)
    fig.tight_layout()
    return fig


def mark_freqs(ax, r, ymax):
    for f in r["freqs"]:
        ax.axvline(f, color=INK2, lw=1.1, ls=":", zorder=1)
        g = r["gains"][f]
        ax.annotate(f"{f} Hz\nvào {g['a_in']:.0f} → ra {g['a_out_act']:.1f}\n"
                    f"đo RTL {g['g_act_db']:+.2f} dB",
                    xy=(f, ymax), xytext=(7 if f < 4500 else -7, -4), textcoords="offset points",
                    ha="left" if f < 4500 else "right", va="top", fontsize=ANNOT, color=INK)


def draw_fft(ax, r, coeff):
    kind = r["kind"]
    if kind == "sine":
        f, X = hann_spectrum(r["x"])
        _, Ye = hann_spectrum(r["y_exp"] / SCALE)
        _, Ya = hann_spectrum(r["y_act"] / SCALE)
        ylabel = "Biên độ (dB re 1 đơn vị mẫu)"
    else:
        f, X = raw_dft(r["x"])
        _, Ye = raw_dft(r["y_exp"] / SCALE)
        _, Ya = raw_dft(r["y_act"] / SCALE)
        ylabel = "|DFT| (dB re 1)"
    ax.plot(f, db(X), color=C_IN, lw=LW_IN, label="Input")
    ax.plot(f, db(Ye), color=C_EXP, lw=LW_EXP, label="Expected / SCALE", zorder=3)
    ax.plot(f, db(Ya), color=C_ACT, lw=LW_ACT, ls=DASH_ACT, label="Actual RTL / SCALE", zorder=4)
    top = float(max(db(X).max(), db(Ya).max())) + 14
    if kind == "impulse":
        fr = np.linspace(0, FS / 2, 1001)
        ax.plot(fr, db(h_theory(coeff, fr) * IMPULSE_AMP), color=INK, lw=LW_REF, ls=(0, (1, 2)),
                label="Lý thuyết IMPULSE_AMP·|H(f)|", zorder=5)
        ax.set_ylim(top - 100, top)
    elif kind == "step":
        ax.set_ylim(top - 110, top)
    else:
        ax.set_ylim(-40, top)
    ax.set_xlim(0, FS / 2)
    ax.set_xlabel("Tần số (Hz)")
    ax.set_ylabel(ylabel)
    if r["freqs"]:
        mark_freqs(ax, r, top - 2)
    ax.legend(loc="lower left")


def fig_frequency_domain(r, coeff):
    kind = r["kind"]
    if kind == "impulse":
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 9.6))
    else:
        fig, ax1 = plt.subplots(1, 1, figsize=(13, 6.4))
    draw_fft(ax1, r, coeff)
    if kind == "sine":
        ax1.set_title("Phổ biên độ: cửa sổ Hann (giảm rò rỉ phổ), bỏ 10 mẫu quá độ đầu "
                      f"(n = {TRANSIENT}…{r['n'] - 1})\ncùng chuẩn hóa 2|X|/Σw cho cả 3 tín hiệu")
        fig.text(0.99, 0.01, "Độ lợi ghi trên hình: fit bình phương tối thiểu tại tần số input có, "
                 "không đọc từ bin FFT", ha="right", va="bottom", fontsize=10, color=INK2)
    elif kind == "impulse":
        ax1.set_title("|DFT| không cửa sổ, đủ 1000 mẫu (cửa sổ sẽ xóa xung tại n = 0)")
        f, X = raw_dft(r["x"])
        _, Ye = raw_dft(r["y_exp"] / SCALE)
        _, Ya = raw_dft(r["y_act"] / SCALE)
        fr = np.linspace(0, FS / 2, 1001)
        ax2.plot(fr, db(h_theory(coeff, fr)), color=INK, lw=LW_REF, ls=(0, (1, 2)),
                 label="Lý thuyết |H(f)| từ c[] trong fir.cpp", zorder=5)
        ax2.plot(f, db(Ye / X), color=C_EXP, lw=LW_EXP, label="Đo từ Expected: |Y/SCALE| / |X|", zorder=3)
        ax2.plot(f, db(Ya / X), color=C_ACT, lw=LW_ACT, ls=DASH_ACT,
                 label="Đo từ Actual RTL: |Y/SCALE| / |X|", zorder=4)
        for fq in (F_LOW, F_HIGH):
            m, th = r["impulse_h"][fq]
            ax2.axvline(fq, color=INK2, lw=1.1, ls=":")
            ax2.annotate(f"{fq} Hz: đo RTL {m:+.2f} dB\nlý thuyết {th:+.2f} dB", xy=(fq, -6),
                         xytext=(7, 0), textcoords="offset points", va="top", fontsize=ANNOT, color=INK,
                         bbox=dict(boxstyle="round,pad=0.25", fc=SURFACE, ec="none"))
        ax2.axvspan(2000, 3000, color=GRID, alpha=0.6, lw=0, zorder=0)
        ax2.text(2500, -88, "dải chuyển tiếp\n2000–3000 Hz", ha="center", fontsize=ANNOT, color=INK2)
        ax2.set_ylim(-95, 6)
        ax2.set_xlim(0, FS / 2)
        ax2.set_xlabel("Tần số (Hz)")
        ax2.set_ylabel("Độ lợi (dB)")
        ax2.set_title("Đáp ứng tần số đo từ đáp ứng xung (xung chứa mọi tần số với cùng biên độ)")
        ax2.legend(loc="lower left")
    else:
        ax1.set_title("|DFT| không cửa sổ, đủ 1000 mẫu. Bậc thang bị cắt cụt ở n = 999 nên tỉ số\n"
                      "phổ ra/vào KHÔNG phải |H(f)|: không suy ra độ lợi theo tần số từ hình này")
        g, th, flat = r["dc_gain"]
        ax1.text(0.99, 0.97, f"Độ lợi DC đo trong miền thời gian (n ≥ {STEP_POSITION + NUM_TAPS}): "
                 f"{g:.4f} ({db(g):+.3f} dB)\nLý thuyết sum(c)/SCALE = {th:.4f}",
                 transform=ax1.transAxes, ha="right", va="top", fontsize=ANNOT, color=INK,
                 bbox=dict(boxstyle="round,pad=0.4", fc=SURFACE, ec=AXIS))
    status_badge(ax1, r, loc=(0.01, 0.97) if kind != "sine" else (0.38, 0.97))
    fig.suptitle(f"{r['name']} — {r['desc']}: miền tần số\n(0 – {FS // 2} Hz Nyquist; "
                 f"output chia SCALE = {SCALE})", fontsize=14, fontweight="bold", color=INK)
    fig.tight_layout(rect=(0, 0.035, 1, 1) if kind == "sine" else None)   # chừa chỗ cho ghi chú
    return fig


def draw_error(ax, r):
    n = np.arange(r["n"])
    err = r["err"]
    ax.plot(n, err, color=INK, lw=1.6, drawstyle="steps-mid", label="error[n] = actual − expected")
    if r["bit_exact"]:
        ax.set_ylim(-1, 1)
        ax.set_yticks([-1, 0, 1])
        status_badge(ax, r)
        ax.text(0.01, 0.20, "max |error| = 0 (so sánh số nguyên signed 32-bit, không tolerance)",
                transform=ax.transAxes, ha="left", va="bottom", fontsize=ANNOT, color=INK)
    else:
        m = r["mism"]
        ax.plot(m, err[m], ls="none", marker="x", ms=8, mew=2, color=C_CRIT, label="mẫu sai")
        i = int(m[0])
        status_badge(ax, r)
        ax.text(0.01, 0.05, f"Sai đầu tiên: n = {i}, expected = {int(r['y_exp'][i])}, "
                f"actual = {int(r['y_act'][i])}\nmax |error| = {r['max_abs_err']}",
                transform=ax.transAxes, ha="left", va="bottom", fontsize=ANNOT, color=INK,
                bbox=dict(boxstyle="round,pad=0.4", fc=SURFACE, ec=C_CRIT, lw=1.6))
        ax.legend(loc="lower right")
    ax.set_xlim(0, r["n"] - 1)
    ax.set_xlabel("Chỉ số mẫu n")
    ax.set_ylabel("actual − expected (LSB)")


def fig_error(r):
    fig, ax = plt.subplots(1, 1, figsize=(13, 4.6))
    draw_error(ax, r)
    ax.set_title(f"{r['name']} — {r['desc']}: sai số RTL, bit-exact từng mẫu "
                 f"({r['n_match']}/{r['n']} khớp)")
    fig.tight_layout()
    return fig


def fig_comparison(results, coeff):
    cols = [results[k] for k in ("test_03_mixed", "test_04_noise") if k in results]
    if not cols:
        return None
    fig, axes = plt.subplots(3, len(cols), figsize=(9 * len(cols), 15), squeeze=False,
                             gridspec_kw={"height_ratios": [1.15, 1.15, 0.6]})
    for j, r in enumerate(cols):
        a, b = r["zoom"]
        draw_time(axes[0, j], r, slice(a, b), zoom_view=True)
        axes[0, j].set_title(f"{r['name']}: miền thời gian, mẫu {a}–{b - 1}")
        axes[0, j].legend(loc="upper right", ncol=1, fontsize=10)
        draw_fft(axes[1, j], r, coeff)
        axes[1, j].set_title(f"{r['name']}: phổ (Hann, bỏ quá độ)")
        draw_error(axes[2, j], r)
        axes[2, j].set_title(f"{r['name']}: actual − expected")
    fig.suptitle("FIR11 HLS — RTL (tb_fir11_vectors) so với mô hình Python: giữ 500 Hz, "
                 "suy giảm 4000 Hz, khớp bit-exact", fontsize=15, fontweight="bold", color=INK)
    fig.tight_layout()
    return fig


def save_figure(fig, png_path):
    """Lưu PNG (DPI cao, chèn báo cáo) + SVG cùng tên (vector, phóng to không mờ)."""
    fig.savefig(png_path, dpi=DPI)
    fig.savefig(Path(png_path).with_suffix(".svg"))
    plt.close(fig)


def load_test(name, coeff):
    """Đọc + kiểm tra input/expected/actual của một test và phân tích. Lỗi -> DataError."""
    try:
        x = read_dat(REF_DIR / name / "input.dat")
        ye = read_dat(REF_DIR / name / "expected.dat")
        ya = read_dat(OUTFEED_DIR / name / "actual.dat")
    except (OSError, UnicodeDecodeError) as e:
        raise DataError(str(e))
    return analyze(name, x, ye, ya, coeff)


# =============================================================================
# Main
# =============================================================================
def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    plt.switch_backend("Agg")       # chỉ ghi file, không mở cửa sổ
    lines = []

    def log(s=""):
        print(s)
        lines.append(s)

    try:
        coeff = read_hls_coefficients()
    except (DataError, OSError) as e:
        print(f"LỖI: {e}", file=sys.stderr)
        return 2
    PLOT_DIR.mkdir(parents=True, exist_ok=True)

    log("=" * 78)
    log("FIR11 RTL vs PYTHON REFERENCE - PHÂN TÍCH KẾT QUẢ MÔ PHỎNG")
    log("=" * 78)
    log(f"input/expected : {rel(REF_DIR)}/<test>/")
    log(f"actual (RTL)   : {rel(OUTFEED_DIR)}/<test>/actual.dat  (tb_fir11_vectors.v, +OUT_DIR)")
    log(f"Hệ số HLS      : {coeff.tolist()}  ({rel(FIR_CPP)}, khớp output/coeff.dat)")
    log(f"So sánh        : error[n] = actual[n] - expected[n], số nguyên signed 32-bit, "
        "không tolerance, không dịch chuỗi")
    log(f"Độ lợi         : fit LS đồng thời (DC + tần số input có), n = {TRANSIENT}..{NUM_SAMPLES - 1}; "
        "Gain = 20log10(A_out/SCALE / A_in)")

    results, errors, plots = {}, {}, []
    for name in TESTS:
        tdir = PLOT_DIR / name
        try:
            r = load_test(name, coeff)
        except DataError as e:
            errors[name] = str(e)
            log(f"\n[{name}] LỖI DỮ LIỆU: {e} -> bỏ qua test này (không dùng expected thay actual)")
            continue
        results[name] = r
        tdir.mkdir(parents=True, exist_ok=True)
        files = {"time": tdir / "time_domain.png", "freq": tdir / "frequency_domain.png",
                 "err": tdir / "error.png"}
        save_figure(fig_time_domain(r), files["time"])
        save_figure(fig_frequency_domain(r, coeff), files["freq"])
        save_figure(fig_error(r), files["err"])
        plots += files.values()

        log(f"\n[{name}] {r['desc']}")
        log(f"  Mẫu kiểm tra     : {r['n']}")
        log(f"  Khớp / không khớp: {r['n_match']} / {len(r['mism'])}")
        log(f"  max |error|      : {r['max_abs_err']}")
        if r["bit_exact"]:
            log("  Bit-exact        : PASS")
        else:
            i = int(r["mism"][0])
            log(f"  Bit-exact        : FAIL (sai đầu tiên n={i}: input={int(r['x'][i])}, "
                f"expected={int(r['y_exp'][i])}, actual={int(r['y_act'][i])})")
        for f, g in r["gains"].items():
            log(f"  Gain {f:>4} Hz     : đo RTL {g['g_act_db']:+.3f} dB (±{g['g_se_db']:.3f}, 1σ)"
                f" | đo Expected {g['g_exp_db']:+.3f} dB | lý thuyết {g['g_th_db']:+.3f} dB"
                f" | A_in={g['a_in']:.2f}, A_out/SCALE={g['a_out_act']:.3f}")
        if r["kind"] == "impulse":
            for fq, (m, th) in r["impulse_h"].items():
                log(f"  |H({fq} Hz)| từ xung: đo RTL {m:+.3f} dB | lý thuyết {th:+.3f} dB")
        if r["kind"] == "step":
            g, th, flat = r["dc_gain"]
            log(f"  Độ lợi DC (bước) : đo RTL {g:.4f} ({db(g):+.3f} dB) | lý thuyết {th:.4f}"
                f" | đầu ra xác lập {'hằng' if flat else 'KHÔNG hằng'}")
        for p in files.values():
            log(f"  -> {rel(p)} (+ .svg)")

    comp = fig_comparison(results, coeff)
    if comp is not None:
        save_figure(comp, PLOT_DIR / "fir_rtl_comparison.png")
        plots.append(PLOT_DIR / "fir_rtl_comparison.png")
        log(f"\n-> {rel(PLOT_DIR / 'fir_rtl_comparison.png')} (+ .svg, tổng hợp mixed + noise)")

    # ---- Hiệu quả lọc (mixed / noise) ----
    log("\n" + "=" * 78)
    log("HIỆU QUẢ LỌC (đo từ actual RTL; lý thuyết từ c[] của fir.cpp)")
    log("=" * 78)
    log(f"  {'test':<16}{'f (Hz)':>7}{'A_in':>10}{'A_out':>10}{'đo RTL (dB)':>14}{'lý thuyết (dB)':>16}{'lệch (dB)':>11}")
    for name in ("test_01_low", "test_02_high", "test_03_mixed", "test_04_noise"):
        if name not in results:
            continue
        for f, g in results[name]["gains"].items():
            log(f"  {name:<16}{f:>7}{g['a_in']:>10.2f}{g['a_out_act']:>10.3f}"
                f"{g['g_act_db']:>+14.3f}{g['g_th_db']:>+16.3f}{g['g_act_db'] - g['g_th_db']:>+11.3f}")
    for name in ("test_03_mixed", "test_04_noise"):
        if name in results and F_LOW in results[name]["gains"]:
            g = results[name]["gains"]
            log(f"  {name}: 4000 Hz bị suy giảm thêm "
                f"{g[F_LOW]['g_act_db'] - g[F_HIGH]['g_act_db']:.2f} dB so với 500 Hz (đo RTL)")
    log("  Ghi chú: test_04_noise có nhiễu Gauss băng rộng; sai số chuẩn (1σ) của phép đo tại 4000 Hz")
    log("  lớn hơn do thành phần ra chỉ còn ~18 đơn vị. Chưa có ngưỡng đặc tả chính thức cho dải")
    log("  thông/dải chắn nên báo cáo này chỉ nêu mức suy giảm đo được, không kết luận PASS đặc tả.")

    # ---- Tổng kết ----
    total = sum(r["n"] for r in results.values()) + NUM_SAMPLES * len(errors)
    match = sum(r["n_match"] for r in results.values())
    n_pass = sum(1 for r in results.values() if r["bit_exact"])
    log("\n" + "=" * 78)
    log("TỔNG KẾT BIT-EXACT")
    log("=" * 78)
    for name in TESTS:
        if name in errors:
            log(f"  [ERROR] {name}: {errors[name]}")
        else:
            r = results[name]
            log(f"  [{'PASS' if r['bit_exact'] else 'FAIL'}] {name}: {r['n_match']}/{r['n']} mẫu khớp, "
                f"max |error| = {r['max_abs_err']}")
    log(f"  Tổng: {n_pass}/{len(TESTS)} test bit-exact, {match}/{total} mẫu khớp, "
        f"{total - match} không khớp/thiếu")
    log(f"  Kết quả bước phân tích: {'PASS' if n_pass == len(TESTS) else 'FAIL'}")
    log(f"  Đồ thị: {len(plots)} hình (mỗi hình .png + .svg) trong {rel(PLOT_DIR)}/")

    (PLOT_DIR / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"\nBáo cáo: {rel(PLOT_DIR / 'summary.txt')}")
    return 0 if n_pass == len(TESTS) else 1


if __name__ == "__main__":
    sys.exit(main())
