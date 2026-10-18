#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generate_fir_data.py
====================
Tạo test vectors cho IP FIR Low-pass Filter (C/C++ -> Verilog bằng HLS).

Với mỗi test case, chương trình tạo:
    input.dat           - mẫu đầu vào (số nguyên có dấu, thập phân, 1 mẫu/dòng)
    expected.dat        - đầu ra FIR tham chiếu (tổng tích chập số nguyên, KHÔNG chia SCALE)
    time_domain.png     - đồ thị miền thời gian
    frequency_domain.png- đồ thị phổ FFT

Và các file chung:
    coeff.dat, coeff_c.txt, fir_frequency_response.png, summary.txt

Mô hình FIR tham chiếu (khớp hls/FIR11/FIR11/fir.cpp đang tích hợp trong SoC):
    y[n] = sum_{k=0}^{NUM_TAPS-1} c[k] * x[n-k],   x[n<0] = 0
    - Hệ số c[] ĐỌC TRỰC TIẾP từ fir.cpp (không tự thiết kế). Không đọc được -> dừng.
    - c[k] nhân với mẫu trễ k (k = 0 là mẫu mới nhất), đúng vòng lặp HLS:
          for (i = N-1; i >= 0; i--)
              if (i == 0) { acc += x * c[0]; shift_reg[0] = x; }
              else        { shift_reg[i] = shift_reg[i-1]; acc += shift_reg[i] * c[i]; }
    - Lịch sử (10 mẫu) khởi tạo bằng 0 cho từng test case, không bỏ mẫu đầu.
    - Kiểu dữ liệu theo fir.h: data_t = coef_t = acc_t = int (signed 32-bit),
      y = acc, KHÔNG chia SCALE; tràn quấn vòng 32-bit (wrap).

Chạy:  python3 generate_fir_data.py
"""

import os
import re
import sys

import numpy as np
from scipy import signal

import matplotlib
matplotlib.use("Agg")  # vẽ ra file, không cần màn hình
import matplotlib.pyplot as plt

# =============================================================================
# 1. CẤU HÌNH FIR  (chỉnh sửa tại đây)
# =============================================================================
NUM_TAPS = 11
FS = 10000          # Hz - tần số lấy mẫu
F_PASS = 2000       # Hz - biên dải thông
F_STOP = 3000       # Hz - biên dải chắn
SCALE = 1000        # hệ số lượng tử hóa: coeff_int = round(coeff_float * SCALE)

NUM_SAMPLES = 1000
RANDOM_SEED = 42

F_LOW = 500         # Hz - tần số thử trong dải thông
F_HIGH = 4000       # Hz - tần số thử trong dải chắn

AMP_LOW = 1000
AMP_HIGH = 400
NOISE_STD = 150

IMPULSE_AMP = 1000
STEP_AMP = 1000
STEP_POSITION = 100     # chỉ số mẫu bắt đầu chuyển lên STEP_AMP

# -----------------------------------------------------------------------------
# Nguồn hệ số: DUY NHẤT là mảng c[] trong fir.cpp của IP HLS đang tích hợp.
#   Đường dẫn tính từ project root (= 2 cấp trên thư mục script), không phụ
#   thuộc thư mục chạy lệnh. Không đọc được -> báo lỗi và dừng (không firwin).
# -----------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, os.pardir, os.pardir))
FIR_CPP_PATH = os.path.join(PROJECT_ROOT, "hls", "FIR11", "FIR11", "fir.cpp")
FIR_H_PATH = os.path.join(PROJECT_ROOT, "hls", "FIR11", "FIR11", "fir.h")
FIR_CPP_ARRAY_NAME = "c"        # tên mảng hệ số trong fir.cpp

# Chỉ dùng để ĐỐI CHIẾU kết quả đọc fir.cpp, không phải nguồn dữ liệu.
# Lệch -> dừng: fir.cpp đã đổi hoặc bộ đọc sai, cần xem lại trước khi tạo dữ liệu.
HLS_COEFF_CROSSCHECK = [54, 0, -92, 0, 313, 500, 313, 0, -92, 0, 54]

# -----------------------------------------------------------------------------
# ĐỘ RỘNG DỮ LIỆU theo fir.h: typedef int data_t / coef_t / acc_t (signed 32-bit)
#   Phép nhân-cộng tính chính xác bằng int64 rồi quấn vòng 32-bit. Cộng/nhân
#   modulo 2^32 đồng dư nên wrap tổng cuối = wrap từng bước như phần cứng
#   (kiểm lại bằng vòng lặp Python thuần, wrap sau từng phép toán).
#   Nếu có giá trị vượt phạm vi, chương trình luôn in CẢNH BÁO.
# -----------------------------------------------------------------------------
DATA_WIDTH = 32     # bit, input x (data_t = int)
COEFF_WIDTH = 32    # bit, hệ số (coef_t = int)
ACC_WIDTH = 32      # bit, bộ tích lũy (acc_t = int)
OUT_WIDTH = 32      # bit, đầu ra y (data_t = int)
OVERFLOW_MODE = "wrap"

# -----------------------------------------------------------------------------
# Bật / tắt từng test case
# -----------------------------------------------------------------------------
ENABLED_TESTS = {
    "test_01_low": True,
    "test_02_high": True,
    "test_03_mixed": True,
    "test_04_noise": True,
    "test_05_impulse": True,
    "test_06_step": True,
}

# -----------------------------------------------------------------------------
# Tiêu chí đánh giá khả năng lọc (đo trên đầu ra tham chiếu, trạng thái ổn định)
#   - Độ lợi tại F_LOW  >= PASSBAND_GAIN_MIN_DB
#   - Độ lợi tại F_HIGH <= STOPBAND_GAIN_MAX_DB
#   - Độ lợi đo được lệch so với lý thuyết <= MEASURE_TOL_DB (kiểm tra phép đo)
#   Đặt giá trị None để bỏ tiêu chí tương ứng.
# -----------------------------------------------------------------------------
PASSBAND_GAIN_MIN_DB = -1.0
STOPBAND_GAIN_MAX_DB = -20.0
MEASURE_TOL_DB = 0.2

# Đồ thị
PLOT_TIME_MS = 20.0     # độ dài cửa sổ thời gian vẽ cho tín hiệu sin (None = toàn bộ)
PLOT_DPI = 120

OUTPUT_DIR = os.path.join(SCRIPT_DIR, "output")

# Các tần số báo cáo độ lợi lý thuyết
GAIN_REPORT_FREQS = (F_LOW, F_PASS, F_STOP, F_HIGH)


# =============================================================================
# Tiện ích
# =============================================================================
def signed_range(width):
    """Phạm vi biểu diễn của số nguyên có dấu width bit."""
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def apply_overflow(values, width, mode, label, warnings):
    """Áp quy tắc tràn số cho mảng int64; ghi cảnh báo nếu có giá trị vượt phạm vi."""
    lo, hi = signed_range(width)
    values = np.asarray(values, dtype=np.int64)
    n_over = int(np.count_nonzero((values < lo) | (values > hi)))
    if n_over:
        warnings.append(
            f"{label}: {n_over} giá trị vượt phạm vi {width}-bit có dấu "
            f"[{lo}, {hi}] (min={values.min()}, max={values.max()}) -> áp dụng '{mode}'"
        )
        if mode == "saturate":
            values = np.clip(values, lo, hi)
        elif mode == "wrap":
            span = 1 << width
            values = ((values - lo) % span) + lo
        else:
            raise ValueError(f"OVERFLOW_MODE không hợp lệ: {mode}")
    return values


def gain_db(g):
    return 20.0 * np.log10(max(abs(g), 1e-12))


# =============================================================================
# 3. Hệ số FIR
# =============================================================================
class CoeffSourceError(RuntimeError):
    """Không đọc / xác minh được hệ số từ source HLS."""


def read_c_source(path):
    """Đọc file C/C++ và bỏ chú thích để regex không bắt nhầm."""
    if not os.path.isfile(path):
        raise CoeffSourceError(f"Không tìm thấy file: {path}")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return re.sub(r"//[^\n]*", " ", src)


def check_fir_header(path):
    """Xác minh N và kiểu dữ liệu trong fir.h khớp với mô hình tham chiếu."""
    src = read_c_source(path)
    m = re.search(r"\bconst\s+int\s+N\s*=\s*(\d+)\s*;", src)
    if not m:
        raise CoeffSourceError(f"Không tìm thấy 'const int N = ...' trong {path}")
    if int(m.group(1)) != NUM_TAPS:
        raise CoeffSourceError(f"fir.h: N = {m.group(1)}, script NUM_TAPS = {NUM_TAPS}")
    types = {name: base.strip() for base, name in
             re.findall(r"\btypedef\s+([\w\s<>,]+?)\s+(\w+)\s*;", src)}
    for t in ("data_t", "coef_t", "acc_t"):
        if types.get(t) != "int":
            raise CoeffSourceError(f"fir.h: {t} = {types.get(t)!r}, mô hình giả định 'int'")


def load_coefficients_from_cpp(path):
    """Đọc mảng số nguyên FIR_CPP_ARRAY_NAME có NUM_TAPS phần tử từ file C/C++."""
    src = read_c_source(path)
    pattern = re.compile(r"\b([A-Za-z_]\w*)\s*\[[^\]]*\]\s*=\s*\{([^}]*)\}")
    bodies = [body for name, body in pattern.findall(src) if name == FIR_CPP_ARRAY_NAME]
    if len(bodies) != 1:
        raise CoeffSourceError(
            f"Tìm thấy {len(bodies)} khai báo '{FIR_CPP_ARRAY_NAME}[] = {{...}}' "
            f"trong {path} (cần đúng 1)")
    items = [t.strip() for t in bodies[0].split(",") if t.strip()]
    try:
        vals = [int(t, 0) for t in items]
    except ValueError as e:
        raise CoeffSourceError(f"Mảng '{FIR_CPP_ARRAY_NAME}' có phần tử không phải số nguyên: {e}")
    if len(vals) != NUM_TAPS:
        raise CoeffSourceError(f"Mảng '{FIR_CPP_ARRAY_NAME}' có {len(vals)} phần tử, cần {NUM_TAPS}")
    print(f"[coeff] Đọc mảng '{FIR_CPP_ARRAY_NAME}' từ {path}")
    return np.array(vals, dtype=np.int64)


def get_coefficients():
    """Trả về (coeff_int, mô tả nguồn). Lỗi -> CoeffSourceError, không có phương án dự phòng."""
    check_fir_header(FIR_H_PATH)
    coeff_int = load_coefficients_from_cpp(FIR_CPP_PATH)
    if coeff_int.tolist() != HLS_COEFF_CROSSCHECK:
        raise CoeffSourceError(
            f"Hệ số đọc từ fir.cpp {coeff_int.tolist()} khác bộ đối chiếu "
            f"{HLS_COEFF_CROSSCHECK}. Kiểm tra lại fir.cpp / bộ đọc trước khi tạo dữ liệu.")
    rel_cpp = os.path.relpath(FIR_CPP_PATH, PROJECT_ROOT).replace(os.sep, "/")
    return coeff_int, f"đọc từ {rel_cpp} (mảng {FIR_CPP_ARRAY_NAME}[])"


def theoretical_gain(coeff_int, freqs_hz):
    """Độ lợi (biên độ, tuyến tính) của FIR đã lượng tử hóa, chuẩn hóa bằng SCALE."""
    _, h = signal.freqz(coeff_int / SCALE, worN=np.atleast_1d(freqs_hz), fs=FS)
    return np.abs(h)


# =============================================================================
# 2. Tạo tín hiệu
# =============================================================================
def time_axis():
    return np.arange(NUM_SAMPLES) / FS


def sine(amp, freq):
    return amp * np.sin(2 * np.pi * freq * time_axis())


def gen_low():
    return sine(AMP_LOW, F_LOW)


def gen_high():
    return sine(AMP_HIGH, F_HIGH)


def gen_mixed():
    return sine(AMP_LOW, F_LOW) + sine(AMP_HIGH, F_HIGH)


def gen_noise():
    rng = np.random.default_rng(RANDOM_SEED)
    return gen_mixed() + rng.normal(0.0, NOISE_STD, NUM_SAMPLES)


def gen_impulse():
    x = np.zeros(NUM_SAMPLES)
    x[0] = IMPULSE_AMP
    return x


def gen_step():
    x = np.zeros(NUM_SAMPLES)
    x[STEP_POSITION:] = STEP_AMP
    return x


def quantize_input(x_float, warnings):
    """Làm tròn về số nguyên và kiểm tra phạm vi DATA_WIDTH (bão hòa nếu vượt)."""
    x = np.rint(x_float).astype(np.int64)
    lo, hi = signed_range(DATA_WIDTH)
    n_over = int(np.count_nonzero((x < lo) | (x > hi)))
    if n_over:
        warnings.append(f"input: {n_over} mẫu vượt {DATA_WIDTH}-bit, đã bão hòa về [{lo}, {hi}]")
        x = np.clip(x, lo, hi)
    return x


# Danh sách test: tên thư mục -> (mô tả, hàm tạo tín hiệu, tần số cần đánh giá, loại)
TESTS = {
    "test_01_low":     ("Low Frequency Only",  gen_low,     [F_LOW],         "sine"),
    "test_02_high":    ("High Frequency Only", gen_high,    [F_HIGH],        "sine"),
    "test_03_mixed":   ("Mixed Frequencies",   gen_mixed,   [F_LOW, F_HIGH], "sine"),
    "test_04_noise":   ("Mixed + Gaussian Noise", gen_noise, [F_LOW, F_HIGH], "sine"),
    "test_05_impulse": ("Impulse Response",    gen_impulse, [],              "impulse"),
    "test_06_step":    ("Step Response",       gen_step,    [],              "step"),
}


# =============================================================================
# 4. FIR tham chiếu (số nguyên)
# =============================================================================
def fir_reference(x, coeff_int, warnings):
    """
    Mô phỏng FIR thanh ghi dịch đúng như code HLS:
        shift_reg khởi tạo 0; mỗi mẫu: dịch, nạp x[n], acc = sum shift_reg[k]*c[k].
    Tính chính xác bằng int64, sau đó áp quy tắc tràn ACC_WIDTH / OUT_WIDTH.
    """
    shift_reg = np.zeros(NUM_TAPS, dtype=np.int64)
    acc = np.empty(len(x), dtype=np.int64)
    for n, sample in enumerate(x):
        shift_reg[1:] = shift_reg[:-1]
        shift_reg[0] = sample
        acc[n] = int(np.dot(shift_reg, coeff_int))

    # Kiểm tra chéo bằng một cách tính độc lập (np.convolve)
    ref = np.convolve(x, coeff_int)[: len(x)]
    if not np.array_equal(acc, ref):
        raise AssertionError("Mô hình thanh ghi dịch không khớp np.convolve")

    # Cảnh báo về tổng trung gian: |tổng riêng phần| <= sum|c*x| nên chỉ cần kiểm tra cận trên
    worst_partial = int(np.max(np.convolve(np.abs(x), np.abs(coeff_int))[: len(x)]))
    acc_lo, acc_hi = signed_range(ACC_WIDTH)
    if worst_partial > acc_hi:
        warnings.append(f"accumulator: tổng riêng phần có thể đạt {worst_partial} > {ACC_WIDTH}-bit")

    y = apply_overflow(acc, ACC_WIDTH, OVERFLOW_MODE, "accumulator", warnings)
    y = apply_overflow(y, OUT_WIDTH, OVERFLOW_MODE, "output", warnings)
    return y


def wrap32(v):
    """Quấn vòng số nguyên Python về signed 32-bit (bù 2)."""
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def fir_hls_pure_python(x, coeffs):
    """
    Mô hình độc lập để kiểm expected.dat: chỉ số nguyên Python (không numpy), chạy
    đúng thứ tự vòng Shift_Accum_Loop trong fir.cpp, wrap 32-bit sau MỖI phép nhân
    và cộng. shift_reg khởi tạo 0 (mỗi lần gọi = một test case mới).
    """
    n_taps = len(coeffs)
    c = [int(v) for v in coeffs]
    shift_reg = [0] * n_taps
    out = []
    for sample in x:
        xs = wrap32(int(sample))
        acc = 0
        for i in range(n_taps - 1, -1, -1):
            if i == 0:
                acc = wrap32(acc + wrap32(xs * c[0]))
                shift_reg[0] = xs
            else:
                shift_reg[i] = shift_reg[i - 1]
                acc = wrap32(acc + wrap32(shift_reg[i] * c[i]))
        out.append(acc)
    return out


# =============================================================================
# Đo độ lợi ở trạng thái ổn định
# =============================================================================
def steady_state_slice():
    """Bỏ NUM_TAPS-1 mẫu quá độ đầu (khi thanh ghi dịch chưa đầy)."""
    return slice(NUM_TAPS - 1, NUM_SAMPLES)


def tone_amplitudes(x, freqs):
    """
    Ước lượng biên độ các thành phần sin tại `freqs` bằng bình phương tối thiểu,
    fit ĐỒNG THỜI mọi tần số + DC: x ~ DC + sum_f (a_f cos + b_f sin).
    - Không bị rò rỉ phổ như đọc một bin FFT, kể cả khi đoạn tín hiệu không chứa
      số chu kỳ nguyên (sau khi bỏ đoạn quá độ).
    - Fit đồng thời để thành phần mạnh (500 Hz) không rò sang ước lượng của thành
      phần yếu (4000 Hz đã bị suy giảm ~36 dB).
    """
    n = np.arange(len(x))
    cols = [np.ones(len(x))]
    for f in freqs:
        w = 2 * np.pi * f / FS
        cols += [np.cos(w * n), np.sin(w * n)]
    coef, *_ = np.linalg.lstsq(np.column_stack(cols), x.astype(float), rcond=None)
    return {f: float(np.hypot(coef[1 + 2 * i], coef[2 + 2 * i])) for i, f in enumerate(freqs)}


def measure_gains(x, y, freqs):
    """Độ lợi đo được (dB) tại từng tần số, dùng đầu ra đã chia SCALE, bỏ quá độ."""
    if not freqs:
        return {}
    ss = steady_state_slice()
    a_in = tone_amplitudes(x[ss], freqs)
    a_out = tone_amplitudes(y[ss] / SCALE, freqs)
    return {f: gain_db(a_out[f] / a_in[f]) if a_in[f] > 0 else float("nan") for f in freqs}


def amplitude_spectrum(x):
    """Phổ biên độ một phía, cửa sổ Hann (giảm rò rỉ phổ), hiệu chỉnh biên độ sin."""
    win = np.hanning(len(x))
    X = np.fft.rfft(x * win)
    amp = 2.0 * np.abs(X) / np.sum(win)
    amp[0] /= 2.0
    freqs = np.fft.rfftfreq(len(x), d=1.0 / FS)
    return freqs, amp


def dft_magnitude(x):
    """
    |DFT| không cửa sổ - dùng cho xung / bậc thang. Không áp cửa sổ Hann vì
    cửa sổ bằng 0 ở mẫu đầu sẽ xóa mất xung. Với xung: |Y(f)|/|X(f)| = |H(f)|.
    """
    return np.fft.rfftfreq(len(x), d=1.0 / FS), np.abs(np.fft.rfft(x))


# =============================================================================
# 5. Vẽ đồ thị
# =============================================================================
def plot_time_domain(path, title, x, y, kind):
    t_ms = time_axis() * 1000.0
    y_disp = y / SCALE  # chỉ để hiển thị: expected.dat là tổng chưa chia SCALE

    if kind == "impulse":
        sel = slice(0, min(NUM_SAMPLES, 3 * NUM_TAPS))
    elif kind == "step":
        a = max(0, STEP_POSITION - 2 * NUM_TAPS)
        sel = slice(a, min(NUM_SAMPLES, STEP_POSITION + 4 * NUM_TAPS))
    elif PLOT_TIME_MS is None:
        sel = slice(0, NUM_SAMPLES)
    else:
        sel = slice(0, min(NUM_SAMPLES, int(PLOT_TIME_MS * FS / 1000)))

    fig, ax = plt.subplots(figsize=(10, 4.5))
    if kind in ("impulse", "step"):
        ax.step(t_ms[sel], x[sel], where="post", label="Input x[n]", alpha=0.8)
        ax.plot(t_ms[sel], y_disp[sel], "o-", ms=3, label="FIR output y[n] / SCALE")
    else:
        ax.plot(t_ms[sel], x[sel], label="Input x[n]", alpha=0.8)
        ax.plot(t_ms[sel], y_disp[sel], label="FIR output y[n] / SCALE", lw=1.8)
    ax.set_title(f"{title} - Time Domain")
    ax.set_xlabel("Thời gian (ms)")
    ax.set_ylabel("Biên độ")
    ax.grid(True, alpha=0.4)
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(path, dpi=PLOT_DPI)
    plt.close(fig)


def plot_frequency_domain(path, title, x, y, kind, freqs_mark, gains, coeff_int):
    ss = steady_state_slice()
    if kind in ("impulse", "step"):
        # Không bỏ đoạn đầu và không áp cửa sổ: thông tin nằm ở chính đoạn quá độ
        f, ax_in = dft_magnitude(x)
        _, ax_out = dft_magnitude(y / SCALE)
    else:
        f, ax_in = amplitude_spectrum(x[ss])
        _, ax_out = amplitude_spectrum(y[ss] / SCALE)

    fig, (a1, a2) = plt.subplots(2, 1, figsize=(10, 7), sharex=True)
    a1.plot(f, ax_in, label="Input", alpha=0.8)
    a1.plot(f, ax_out, label="Output / SCALE", alpha=0.9)
    a1.set_ylabel("Biên độ" if kind == "sine" else "|DFT|")
    a1.set_title(f"{title} - Frequency Domain (FFT, cửa sổ Hann, bỏ quá độ)"
                 if kind == "sine" else f"{title} - Frequency Domain (FFT)")

    a2.plot(f, 20 * np.log10(np.maximum(ax_in, 1e-6)), label="Input", alpha=0.8)
    a2.plot(f, 20 * np.log10(np.maximum(ax_out, 1e-6)), label="Output / SCALE", alpha=0.9)
    a2.set_ylabel("Biên độ (dB)" if kind == "sine" else "|DFT| (dB)")
    a2.set_xlabel("Tần số (Hz)")
    if kind == "sine":
        a2.set_ylim(bottom=-60)

    if kind == "impulse":
        # Phổ đáp ứng xung (chuẩn hóa theo biên độ xung) = đáp ứng tần số của FIR
        fr = np.linspace(0, FS / 2, 512)
        h = theoretical_gain(coeff_int, fr)
        # Phổ đầu ra = IMPULSE_AMP * |H(f)| -> vẽ đường lý thuyết cùng thang để so sánh
        a1.plot(fr, h * IMPULSE_AMP, "k--", lw=1, label="IMPULSE_AMP x |H(f)| lý thuyết")
        a2.plot(fr, 20 * np.log10(np.maximum(h * IMPULSE_AMP, 1e-6)), "k--", lw=1,
                label="IMPULSE_AMP x |H(f)| lý thuyết")
        top = 20 * np.log10(IMPULSE_AMP) + 10
        a2.set_ylim(top - 90, top)

    for fm in freqs_mark:
        for a in (a1, a2):
            a.axvline(fm, color="r", ls=":", lw=1)
        txt = f"{fm} Hz: {gains[fm]:+.2f} dB" if fm in gains else f"{fm} Hz"
        a2.annotate(txt, xy=(fm, 0), xytext=(5, -15), textcoords="offset points",
                    color="r", fontsize=9)
    for a in (a1, a2):
        a.axvspan(F_PASS, F_STOP, color="gray", alpha=0.12)
        a.grid(True, alpha=0.4)
        a.legend(loc="upper right")
    a1.set_xlim(0, FS / 2)
    fig.tight_layout()
    fig.savefig(path, dpi=PLOT_DPI)
    plt.close(fig)


def plot_fir_response(path, coeff_int):
    f = np.linspace(0, FS / 2, 2048)
    h_q = theoretical_gain(coeff_int, f)
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(10, 7))
    a1.plot(f, 20 * np.log10(np.maximum(h_q, 1e-9)), label="Hệ số HLS fir.cpp (c/SCALE)")
    a1.axvspan(F_PASS, F_STOP, color="gray", alpha=0.15, label="Dải chuyển tiếp")
    for fm in GAIN_REPORT_FREQS:
        g = gain_db(theoretical_gain(coeff_int, fm)[0])
        a1.axvline(fm, color="r", ls=":", lw=1)
        a1.annotate(f"{fm} Hz: {g:+.2f} dB", xy=(fm, g), xytext=(5, 5),
                    textcoords="offset points", color="r", fontsize=9)
    if STOPBAND_GAIN_MAX_DB is not None:
        a1.axhline(STOPBAND_GAIN_MAX_DB, color="m", ls="--", lw=0.8,
                   label=f"Tiêu chí dải chắn {STOPBAND_GAIN_MAX_DB} dB")
    a1.set_ylim(-90, 5)
    a1.set_xlim(0, FS / 2)
    a1.set_xlabel("Tần số (Hz)")
    a1.set_ylabel("Độ lợi (dB)")
    a1.set_title(f"Đáp ứng tần số FIR {NUM_TAPS} tap (FS={FS} Hz, SCALE={SCALE})")
    a1.grid(True, alpha=0.4)
    a1.legend(loc="lower left", fontsize=8)

    a2.stem(np.arange(NUM_TAPS), coeff_int)
    a2.set_xlabel("Chỉ số tap k")
    a2.set_ylabel("c[k]")
    a2.set_title(f"Hệ số nguyên HLS: {coeff_int.tolist()}")
    a2.grid(True, alpha=0.4)
    fig.tight_layout()
    fig.savefig(path, dpi=PLOT_DPI)
    plt.close(fig)


# =============================================================================
# Xuất file
# =============================================================================
def write_dat(path, values):
    """Mỗi dòng một số nguyên có dấu dạng thập phân, không header."""
    with open(path, "w", newline="\n") as f:
        for v in values:
            f.write(f"{int(v)}\n")


def read_dat(path):
    with open(path, "r") as f:
        return [int(line) for line in f if line.strip()]


def write_coeff_c(path, coeff_int, desc):
    body = ", ".join(str(int(c)) for c in coeff_int)
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        f.write(f"// FIR low-pass coefficients (HLS IP) - exported by generate_fir_data.py\n")
        f.write(f"// Source : {desc}\n")
        f.write(f"// FS={FS} Hz, F_PASS={F_PASS} Hz, F_STOP={F_STOP} Hz, SCALE={SCALE}\n")
        f.write(f"// Convention: y[n] = sum_k c[k] * x[n-k]  (c[0] multiplies newest sample)\n")
        f.write(f"// Types: data_t = coef_t = acc_t = int (signed 32-bit), wrap on overflow\n")
        f.write(f"// Output is NOT divided by SCALE (DC gain = sum(c) = {int(coeff_int.sum())})\n")
        f.write(f"#define NUM_TAPS {NUM_TAPS}\n")
        f.write(f"#define FIR_SCALE {SCALE}\n")
        f.write(f"const coef_t c[NUM_TAPS] = {{{body}}};\n")


# =============================================================================
# Main
# =============================================================================
def check_coeff_range(coeff_int):
    lo, hi = signed_range(COEFF_WIDTH)
    if coeff_int.min() < lo or coeff_int.max() > hi:
        raise ValueError(f"Hệ số vượt phạm vi {COEFF_WIDTH}-bit: {coeff_int}")


def evaluate_criteria(name, gains):
    """Trả về danh sách (mô tả, đạt?) cho các tiêu chí độ lợi đã cấu hình."""
    out = []
    if F_LOW in gains and PASSBAND_GAIN_MIN_DB is not None:
        out.append((f"gain@{F_LOW}Hz {gains[F_LOW]:+.2f} dB >= {PASSBAND_GAIN_MIN_DB} dB",
                    gains[F_LOW] >= PASSBAND_GAIN_MIN_DB))
    if F_HIGH in gains and STOPBAND_GAIN_MAX_DB is not None and name != "test_04_noise":
        out.append((f"gain@{F_HIGH}Hz {gains[F_HIGH]:+.2f} dB <= {STOPBAND_GAIN_MAX_DB} dB",
                    gains[F_HIGH] <= STOPBAND_GAIN_MAX_DB))
    return out


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    summary = []

    def log(msg=""):
        print(msg)
        summary.append(msg)

    def rel(p):
        return os.path.relpath(p, PROJECT_ROOT).replace(os.sep, "/")

    # ---- Hệ số ----
    try:
        coeff_int, desc = get_coefficients()
    except CoeffSourceError as e:
        print(f"LỖI: không lấy được hệ số FIR từ source HLS: {e}", file=sys.stderr)
        print("Dừng. Không tạo dữ liệu, không thay bằng hệ số firwin.", file=sys.stderr)
        return 2
    check_coeff_range(coeff_int)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    log("=" * 72)
    log("FIR TEST VECTOR GENERATOR")
    log("=" * 72)
    log(f"Hệ số       : {desc}")
    log(f"coeff_int   : {coeff_int.tolist()}")
    log(f"sum(coeff)  : {int(coeff_int.sum())}  (DC gain = {coeff_int.sum() / SCALE:.4f})")
    log(f"Đối xứng    : {'có' if np.array_equal(coeff_int, coeff_int[::-1]) else 'KHÔNG'} "
        f"(thứ tự hệ số {'không ảnh hưởng' if np.array_equal(coeff_int, coeff_int[::-1]) else 'QUAN TRỌNG'})")
    log(f"Đối chiếu   : khớp bộ hệ số HLS kỳ vọng {HLS_COEFF_CROSSCHECK}")
    log(f"Kiểu dữ liệu: x int{DATA_WIDTH}, coeff int{COEFF_WIDTH}, acc int{ACC_WIDTH}, "
        f"y int{OUT_WIDTH}, overflow={OVERFLOW_MODE} (theo fir.h), y KHÔNG chia SCALE")
    log(f"Mô hình     : y[n] = sum_k c[k]*x[n-k], k=0..{NUM_TAPS - 1}; "
        f"lịch sử {NUM_TAPS - 1} mẫu = 0 đầu mỗi test")
    log(f"Tín hiệu    : FS={FS} Hz, F_PASS={F_PASS} Hz, F_STOP={F_STOP} Hz, SCALE={SCALE}, "
        f"NUM_SAMPLES={NUM_SAMPLES}")

    g_lin = {f: float(theoretical_gain(coeff_int, f)[0]) for f in GAIN_REPORT_FREQS}
    g_th = {f: gain_db(g_lin[f]) for f in GAIN_REPORT_FREQS}
    log("Độ lợi lý thuyết |H(f)| = |sum c[k] e^-jwk| / SCALE (hệ số HLS):")
    log(f"  {0:>5} Hz (DC)              : {gain_db(coeff_int.sum() / SCALE):+.3f} dB  "
        f"(x{coeff_int.sum() / SCALE:.4f})")
    log(f"  {F_LOW:>5} Hz (test, dải thông): {g_th[F_LOW]:+.3f} dB  (x{g_lin[F_LOW]:.4f})")
    log(f"  {F_PASS:>5} Hz (biên dải thông): {g_th[F_PASS]:+.3f} dB  (x{g_lin[F_PASS]:.4f})")
    log(f"  {F_STOP:>5} Hz (biên dải chắn) : {g_th[F_STOP]:+.3f} dB  (x{g_lin[F_STOP]:.4f})")
    log(f"  {F_HIGH:>5} Hz (test, dải chắn): {g_th[F_HIGH]:+.3f} dB  (x{g_lin[F_HIGH]:.4f})")

    coeff_dat = os.path.join(OUTPUT_DIR, "coeff.dat")
    coeff_c = os.path.join(OUTPUT_DIR, "coeff_c.txt")
    fr_png = os.path.join(OUTPUT_DIR, "fir_frequency_response.png")
    write_dat(coeff_dat, coeff_int)
    write_coeff_c(coeff_c, coeff_int, desc)
    plot_fir_response(fr_png, coeff_int)
    for p in (coeff_dat, coeff_c, fr_png):
        log(f"  -> {rel(p)}")

    all_checks = []
    out_lo, out_hi = signed_range(OUT_WIDTH)

    # ---- Test cases ----
    for name, (title, gen, freqs, kind) in TESTS.items():
        if not ENABLED_TESTS.get(name, False):
            log(f"\n[{name}] bỏ qua (tắt trong ENABLED_TESTS)")
            continue
        warnings = []
        x = quantize_input(gen(), warnings)
        y = fir_reference(x, coeff_int, warnings)
        assert len(x) == len(y) == NUM_SAMPLES

        tdir = os.path.join(OUTPUT_DIR, name)
        os.makedirs(tdir, exist_ok=True)
        paths = {k: os.path.join(tdir, k) for k in
                 ("input.dat", "expected.dat", "time_domain.png", "frequency_domain.png")}
        # input.dat đã có: phải trùng từng mẫu với tín hiệu vừa tạo (cấu hình không đổi)
        input_status = "tạo mới"
        if os.path.isfile(paths["input.dat"]):
            same = read_dat(paths["input.dat"]) == [int(v) for v in x]
            input_status = "không đổi so với file cũ" if same else "THAY ĐỔI so với file cũ"
            all_checks.append((f"{name}: input.dat không đổi so với bản trước", same))
        write_dat(paths["input.dat"], x)
        write_dat(paths["expected.dat"], y)

        gains = measure_gains(x, y, freqs) if kind == "sine" else {}
        plot_time_domain(paths["time_domain.png"], title, x, y, kind)
        plot_frequency_domain(paths["frequency_domain.png"], title, x, y, kind, freqs, gains,
                              coeff_int)

        log(f"\n[{name}] {title}")
        log(f"  Số mẫu      : input={len(x)}, expected={len(y)}; input.dat {input_status}")
        log(f"  Phạm vi     : x=[{x.min()}, {x.max()}], y=[{y.min()}, {y.max()}] "
            f"(headroom int{OUT_WIDTH}: {out_hi / max(abs(int(y.min())), abs(int(y.max())), 1):.0f}x)")
        for f_ in freqs:
            log(f"  Gain {f_:>5} Hz: đo={gains[f_]:+.3f} dB, lý thuyết={g_th[f_]:+.3f} dB, "
                f"lệch={gains[f_] - g_th[f_]:+.3f} dB")
            if MEASURE_TOL_DB is not None:
                # Với test có nhiễu, sai số đo tại tần số bị suy giảm mạnh là đáng kể
                if name == "test_04_noise" and f_ == F_HIGH:
                    log(f"    (không so với lý thuyết: thành phần {F_HIGH} Hz sau lọc "
                        f"~{AMP_HIGH * g_lin[F_HIGH]:.0f} đơn vị (sau /SCALE), chìm trong "
                        f"nhiễu đã lọc -> sai số đo lớn)")
                    continue
                all_checks.append((f"{name}: |đo - lý thuyết| tại {f_} Hz <= {MEASURE_TOL_DB} dB",
                                   abs(gains[f_] - g_th[f_]) <= MEASURE_TOL_DB))
        for c in evaluate_criteria(name, gains):
            all_checks.append((f"{name}: {c[0]}", c[1]))

        if kind == "impulse":
            ok = np.array_equal(y[:NUM_TAPS], coeff_int * IMPULSE_AMP) and not np.any(y[NUM_TAPS:])
            log(f"  y[0:{NUM_TAPS}] = coeff_int x {IMPULSE_AMP}: {'khớp' if ok else 'KHÔNG khớp'}")
            all_checks.append((f"{name}: đáp ứng xung = coeff_int x {IMPULSE_AMP}", ok))
        if kind == "step":
            final = int(y[-1])
            exp_final = int(coeff_int.sum()) * STEP_AMP
            ok = final == exp_final
            log(f"  Giá trị xác lập y[-1] = {final} (sum(coeff) x {STEP_AMP} = {exp_final})")
            all_checks.append((f"{name}: giá trị xác lập = sum(coeff) x {STEP_AMP}", ok))
        for w in warnings:
            log(f"  CẢNH BÁO: {w}")
        for p in paths.values():
            log(f"  -> {rel(p)}")

    # ---- Kiểm tra độc lập expected.dat: đọc lại từ đĩa, vòng lặp Python thuần ----
    log("\n" + "=" * 72)
    log("KIỂM TRA ĐỘC LẬP expected.dat (Python thuần, vòng lặp fir.cpp, wrap 32-bit từng bước)")
    log("=" * 72)
    total, total_bad = 0, 0
    for name in TESTS:
        if not ENABLED_TESTS.get(name, False):
            continue
        tdir = os.path.join(OUTPUT_DIR, name)
        x_f = read_dat(os.path.join(tdir, "input.dat"))
        y_f = read_dat(os.path.join(tdir, "expected.dat"))
        y_ref = fir_hls_pure_python(x_f, coeff_int.tolist())
        ok_len = len(x_f) == len(y_f) == NUM_SAMPLES
        mism = [i for i, (a, b) in enumerate(zip(y_f, y_ref)) if a != b]
        n_bad = len(mism) + abs(len(y_f) - len(y_ref))
        total += len(y_ref)
        total_bad += n_bad
        msg = f"  {name}: {len(y_ref) - n_bad}/{len(y_ref)} mẫu khớp"
        if mism:
            msg += f"; lệch đầu tiên n={mism[0]}: file={y_f[mism[0]]}, ref={y_ref[mism[0]]}"
        log(msg)
        all_checks.append((f"{name}: expected.dat khớp mô hình Python thuần ({len(y_ref)} mẫu)",
                           ok_len and n_bad == 0))
    log(f"  Tổng: {total - total_bad}/{total} mẫu khớp, {total_bad} lệch")

    # ---- Tổng kết ----
    log("\n" + "=" * 72)
    log("ĐÁNH GIÁ MÔ HÌNH THAM CHIẾU THEO TIÊU CHÍ ĐÃ CẤU HÌNH")
    log("(Đây là đặc tính của bộ hệ số/expected.dat, CHƯA phải kết quả mô phỏng RTL)")
    log("=" * 72)
    for desc_c, ok in all_checks:
        log(f"  [{'PASS' if ok else 'FAIL'}] {desc_c}")
    n_fail = sum(1 for _, ok in all_checks if not ok)
    log(f"Tổng: {len(all_checks) - n_fail}/{len(all_checks)} tiêu chí đạt")

    with open(os.path.join(OUTPUT_DIR, "summary.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(summary) + "\n")
    print(f"\nTóm tắt lưu tại: {os.path.join(OUTPUT_DIR, 'summary.txt')}")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
