function figs = view_fir_plots(test)
% VIEW_FIR_PLOTS  Xem kết quả FIR11 RTL so với mô hình Python trong MATLAB.
%
%   view_fir_plots(n)       n = 1..6: mở 3 figure (thời gian, tần số, sai số) của test n
%       1 = test_01_low      sin 500 Hz
%       2 = test_02_high     sin 4000 Hz
%       3 = test_03_mixed    500 Hz + 4000 Hz
%       4 = test_04_noise    500 Hz + 4000 Hz + nhiễu Gauss
%       5 = test_05_impulse  đáp ứng xung
%       6 = test_06_step     đáp ứng bậc
%   view_fir_plots()        figure tổng hợp mixed + noise
%   view_fir_plots('list')  in trạng thái bit-exact của 6 test, không vẽ
%   figs = view_fir_plots(...)  trả về handle các figure
%
%   Dữ liệu (đường dẫn tính từ vị trí file này, không phụ thuộc thư mục hiện tại):
%       data_test/fir_test/output/<test>/input.dat, expected.dat   (Python)
%       outfeed/<test>/actual.dat                                   (FIR RTL)
%       hls/FIR11/FIR11/fir.cpp                                     (hệ số c[] cho lý thuyết)
%   So sánh bit-exact: error = actual - expected (int64), không tolerance, không dịch chuỗi.
%   Output chia SCALE = 1000 chỉ để hiển thị. Không ghi file nào.
%
%   Chạy trong MATLAB (Command Window), từ thư mục gốc project:
%       cd scripts; view_fir_plots(3)
%   hoặc từ terminal (Git Bash), tại thư mục gốc project:
%       matlab -r "cd scripts; view_fir_plots(3)"

    P = cfg();
    coeff = read_coefficients(P);

    if nargin < 1 || isempty(test)
        r3 = load_test(P, 3, coeff);
        r4 = load_test(P, 4, coeff);
        print_result(r3); print_result(r4);
        figs = fig_comparison(P, [r3 r4], coeff);
    elseif ischar(test) || isstring(test)
        if ~strcmpi(test, 'list')
            error('view_fir_plots: tham số chữ chỉ nhận ''list''.');
        end
        list_all(P, coeff);
        figs = gobjects(0);
    else
        n = double(test);
        if ~isscalar(n) || n < 1 || n > 6 || n ~= fix(n)
            error('view_fir_plots: số test phải là 1..6 (%s).', strjoin(P.names, ', '));
        end
        r = load_test(P, n, coeff);
        print_result(r);
        figs = [fig_time(P, r), fig_freq(P, r, coeff), fig_error(P, r)];
    end
    if nargout == 0
        clear figs
    end
end

% =========================================================================
% Cấu hình
% =========================================================================
function P = cfg()
    here = fileparts(mfilename('fullpath'));
    P.root = fileparts(here);
    P.ref = fullfile(P.root, 'data_test', 'fir_test', 'output');
    P.outfeed = fullfile(P.root, 'outfeed');
    P.firCpp = fullfile(P.root, 'hls', 'FIR11', 'FIR11', 'fir.cpp');
    P.FS = 10000; P.SCALE = 1000; P.N = 1000; P.TAPS = 11; P.TRANS = 10;
    P.names = {'test_01_low', 'test_02_high', 'test_03_mixed', ...
               'test_04_noise', 'test_05_impulse', 'test_06_step'};
    P.desc  = {'Sin 500 Hz', 'Sin 4000 Hz', '500 Hz + 4000 Hz', ...
               '500 Hz + 4000 Hz + nhiễu Gauss', 'Đáp ứng xung (x[0] = 1000)', ...
               'Đáp ứng bậc (x[n>=100] = 1000)'};
    P.kind  = {'sine', 'sine', 'sine', 'sine', 'impulse', 'step'};
    P.freqs = {500, 4000, [500 4000], [500 4000], [], []};
    P.zoom  = {[400 550], [400 450], [400 550], [400 550], [0 30], [90 130]};  % [a, b)
    % Bảng màu giống bản Python (input / expected / actual, PASS / FAIL, mực)
    P.cIn = hex('#2a78d6'); P.cExp = hex('#eb6834'); P.cAct = hex('#1baf7a');
    P.cGood = hex('#0ca30c'); P.cCrit = hex('#d03b3b');
    P.ink = hex('#0b0b0b'); P.ink2 = hex('#52514e'); P.grid = hex('#e1e0d9');
end

function c = hex(s)
    c = sscanf(s(2:end), '%2x%2x%2x', [1 3]) / 255;
end

% =========================================================================
% Đọc và kiểm tra dữ liệu
% =========================================================================
function v = read_dat(P, path)
    if ~isfile(path)
        error('Không tìm thấy %s (không dùng expected thay cho actual).', path);
    end
    txt = fileread(path);
    lines = regexp(strtrim(txt), '\r?\n', 'split');
    ok = ~cellfun(@isempty, regexp(lines, '^\s*[+-]?\d+\s*$', 'once'));
    if ~all(ok)
        bad = find(~ok, 1);
        error('%s:%d: không phải số nguyên thập phân: "%s"', path, bad, lines{bad});
    end
    v = str2double(lines(:));          % |v| < 2^31 < 2^53: double biểu diễn chính xác
    if numel(v) ~= P.N
        error('%s: %d mẫu, cần đúng %d.', path, numel(v), P.N);
    end
    if any(v < -2^31 | v > 2^31 - 1)
        error('%s: có giá trị ngoài phạm vi signed 32-bit.', path);
    end
end

function c = read_coefficients(P)
    src = fileread(P.firCpp);
    src = regexprep(src, '/\*.*?\*/', ' ');
    src = regexprep(src, '//[^\n]*', ' ');
    tok = regexp(src, 'coef_t\s+c\s*\[[^\]]*\]\s*=\s*\{([^}]*)\}', 'tokens');
    if numel(tok) ~= 1
        error('Không xác định được mảng c[] trong %s.', P.firCpp);
    end
    c = str2double(strsplit(tok{1}{1}, ','));
    c = c(:).';
    if numel(c) ~= P.TAPS || any(isnan(c))
        error('Mảng c[] trong fir.cpp không có đúng %d hệ số nguyên.', P.TAPS);
    end
end

function r = load_test(P, n, coeff)
    r.name = P.names{n}; r.desc = P.desc{n}; r.kind = P.kind{n};
    r.freqs = P.freqs{n}; r.zoom = P.zoom{n};
    r.x  = read_dat(P, fullfile(P.ref, r.name, 'input.dat'));
    r.ye = read_dat(P, fullfile(P.ref, r.name, 'expected.dat'));
    r.ya = read_dat(P, fullfile(P.outfeed, r.name, 'actual.dat'));
    r.err = int64(r.ya) - int64(r.ye);
    r.mism = find(r.err ~= 0);                     % chỉ số 1-based
    r.nMatch = P.N - numel(r.mism);
    r.maxAbs = max(abs(r.err));
    r.bitExact = isempty(r.mism);
    % Độ lợi: fit LS đồng thời DC + các tần số input có, đoạn n >= 10 (bỏ quá độ)
    r.gains = struct('f', {}, 'aIn', {}, 'aOut', {}, 'gAct', {}, 'gTh', {});
    if ~isempty(r.freqs)
        aIn = tone_fit(P, r.x, r.freqs);
        aOut = tone_fit(P, r.ya / P.SCALE, r.freqs);
        hTh = h_theory(P, coeff, r.freqs);
        for i = 1:numel(r.freqs)
            r.gains(i) = struct('f', r.freqs(i), 'aIn', aIn(i), 'aOut', aOut(i), ...
                'gAct', 20*log10(aOut(i)/aIn(i)), 'gTh', 20*log10(hTh(i)));
        end
    end
end

function list_all(P, coeff)
    fprintf('\n  #  Kết quả   Test              Khớp        max|error|\n');
    total = 0;
    for n = 1:6
        try
            r = load_test(P, n, coeff);
            st = 'PASS'; if ~r.bitExact, st = 'FAIL'; end
            fprintf('  %d  [%s]    %-16s  %4d/%d    %d\n', n, st, r.name, r.nMatch, P.N, r.maxAbs);
            total = total + r.nMatch;
        catch e
            fprintf('  %d  [ERROR]   %-16s  %s\n', n, P.names{n}, e.message);
        end
    end
    fprintf('  Tổng: %d/%d mẫu khớp\n\n', total, 6 * P.N);
end

function print_result(r)
    st = 'BIT-EXACT PASS'; if ~r.bitExact, st = 'FAIL'; end
    fprintf('\n[%s] %s: %s, %d/1000 mẫu khớp, max|error| = %d\n', r.name, r.desc, st, r.nMatch, r.maxAbs);
    if ~r.bitExact
        i = r.mism(1);
        fprintf('  Sai đầu tiên n = %d: input = %d, expected = %d, actual = %d\n', ...
                i - 1, r.x(i), r.ye(i), r.ya(i));
    end
    for g = r.gains
        fprintf('  Gain %4d Hz: đo RTL %+.3f dB | lý thuyết %+.3f dB (A_in = %.1f, A_out/SCALE = %.2f)\n', ...
                g.f, g.gAct, g.gTh, g.aIn, g.aOut);
    end
end

% =========================================================================
% Phân tích
% =========================================================================
function H = h_theory(P, coeff, f)
    k = 0:P.TAPS - 1;
    H = abs(exp(-1j * 2*pi * f(:) * k / P.FS) * coeff(:)) / P.SCALE;
end

function amp = tone_fit(P, x, freqs)
    seg = x(P.TRANS + 1:end);
    n = (P.TRANS:P.N - 1).';
    A = ones(numel(seg), 1);
    for f = freqs
        w = 2*pi*f / P.FS;
        A = [A, cos(w*n), sin(w*n)]; %#ok<AGROW>
    end
    coef = A \ seg;
    amp = hypot(coef(2:2:end), coef(3:2:end)).';
end

function [f, amp] = hann_spectrum(P, x)
    % Phổ biên độ một phía, cửa sổ Hann, bỏ quá độ; sin biên độ A -> đỉnh ~A
    seg = x(P.TRANS + 1:end);
    L = numel(seg);
    w = 0.5 - 0.5 * cos(2*pi*(0:L-1).' / (L - 1));
    X = fft(seg .* w);
    K = floor(L/2) + 1;
    amp = 2 * abs(X(1:K)) / sum(w);
    amp(1) = amp(1) / 2;
    f = (0:K-1).' * P.FS / L;
end

function [f, mag] = raw_dft(P, x)
    % |DFT| không cửa sổ, đủ 1000 mẫu (xung / bậc: cửa sổ sẽ xóa hoặc méo xung)
    X = fft(x);
    K = floor(numel(x)/2) + 1;
    mag = abs(X(1:K));
    f = (0:K-1).' * P.FS / numel(x);
end

function d = db(v)
    d = 20 * log10(max(abs(v), 1e-12));
end

% =========================================================================
% Vẽ
% =========================================================================
function ax = new_axes(P, tl)
    ax = nexttile(tl);
    hold(ax, 'on'); grid(ax, 'on'); box(ax, 'off');
    set(ax, 'FontSize', 12, 'GridColor', P.grid, 'GridAlpha', 1, 'XColor', P.ink2, 'YColor', P.ink2, ...
        'LineWidth', 1);
end

function fig = new_figure(name, pos)
    fig = figure('Name', name, 'NumberTitle', 'off', 'Color', 'w', 'Position', pos);
    % Chữ hiển thị nguyên văn (không để TeX biến test_03_mixed thành chỉ số dưới)
    set(fig, 'DefaultTextInterpreter', 'none', 'DefaultLegendInterpreter', 'none', ...
        'DefaultAxesTickLabelInterpreter', 'none');
end

function badge(P, ax, r, xy)
    if nargin < 4, xy = [0.01 0.97]; end
    if r.bitExact
        s = sprintf('✓ BIT-EXACT PASS  %d/%d mẫu', r.nMatch, P.N); c = P.cGood;
    else
        s = sprintf('✗ FAIL  %d/%d mẫu khớp', r.nMatch, P.N); c = P.cCrit;
    end
    text(ax, xy(1), xy(2), s, 'Units', 'normalized', 'VerticalAlignment', 'top', ...
         'FontWeight', 'bold', 'FontSize', 12, 'EdgeColor', c, 'LineWidth', 2, ...
         'BackgroundColor', 'w', 'Margin', 4, 'Color', P.ink);
end

function draw_time(P, ax, r, a, b, zoomView)
    idx = (a:b-1) + 1;                         % mẫu a..b-1 (0-based) -> chỉ số MATLAB
    t = (a:b-1).' * 1000 / P.FS;
    x = r.x(idx); ye = r.ye(idx) / P.SCALE; ya = r.ya(idx) / P.SCALE;
    if any(strcmp(r.kind, {'impulse', 'step'}))
        stairs(ax, t, x, 'Color', P.cIn, 'LineWidth', 1.6, 'DisplayName', 'Input x[n]');
    else
        plot(ax, t, x, 'Color', P.cIn, 'LineWidth', 1.4, 'DisplayName', 'Input x[n]');
    end
    plot(ax, t, ye, '-', 'Color', P.cExp, 'LineWidth', 2.6, 'DisplayName', 'Expected (Python) / SCALE');
    if zoomView
        plot(ax, t, ya, 'o', 'Color', P.cAct, 'MarkerSize', 7, 'LineWidth', 1.6, ...
             'DisplayName', 'Actual (RTL) / SCALE');
    else
        plot(ax, t, ya, '--', 'Color', P.cAct, 'LineWidth', 1.8, 'DisplayName', 'Actual (RTL) / SCALE');
    end
    xlim(ax, [t(1), t(end) + 1000 / P.FS]);
    xlabel(ax, 'Thời gian (ms)'); ylabel(ax, 'Biên độ (đơn vị mẫu)');
end

function fig = fig_time(P, r)
    fig = new_figure(sprintf('%s - miền thời gian', r.name), [60 60 1300 860]);
    tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl, {sprintf('%s — %s: miền thời gian', r.name, r.desc), ...
               sprintf('(FS = %d Hz; output chia SCALE = %d chỉ để hiển thị)', P.FS, P.SCALE)}, ...
          'FontWeight', 'bold', 'FontSize', 14, 'Interpreter', 'none');
    a = r.zoom(1); b = r.zoom(2);
    ax1 = new_axes(P, tl);
    draw_time(P, ax1, r, 0, P.N, false);
    yl = ylim(ax1);
    hz = patch(ax1, [a b b a] * 1000 / P.FS, yl([1 1 2 2]), P.grid, 'EdgeColor', 'none', ...
               'FaceAlpha', 0.7, 'HandleVisibility', 'off');
    uistack(hz, 'bottom');
    ylim(ax1, yl);
    title(ax1, sprintf('Toàn bộ %d mẫu (vùng xám = đoạn phóng to bên dưới)', P.N));
    legend(ax1, 'Location', 'northeast', 'NumColumns', 3);
    badge(P, ax1, r);
    ax2 = new_axes(P, tl);
    draw_time(P, ax2, r, a, b, true);
    title(ax2, {sprintf('Phóng to mẫu %d–%d (%d mẫu, %g–%g ms)', a, b-1, b-a, a*1000/P.FS, b*1000/P.FS), ...
                'đường cam = Expected, vòng tròn xanh ngọc = Actual RTL'});
    loc = 'northeast'; if strcmp(r.kind, 'step'), loc = 'southeast'; end
    legend(ax2, 'Location', loc, 'NumColumns', 3);
end

function draw_fft(P, ax, r, coeff)
    if strcmp(r.kind, 'sine')
        [f, X] = hann_spectrum(P, r.x);
        [~, Ye] = hann_spectrum(P, r.ye / P.SCALE);
        [~, Ya] = hann_spectrum(P, r.ya / P.SCALE);
        yl = 'Biên độ (dB re 1 đơn vị mẫu)';
    else
        [f, X] = raw_dft(P, r.x);
        [~, Ye] = raw_dft(P, r.ye / P.SCALE);
        [~, Ya] = raw_dft(P, r.ya / P.SCALE);
        yl = '|DFT| (dB re 1)';
    end
    plot(ax, f, db(X), 'Color', P.cIn, 'LineWidth', 1.4, 'DisplayName', 'Input');
    plot(ax, f, db(Ye), '-', 'Color', P.cExp, 'LineWidth', 2.6, 'DisplayName', 'Expected / SCALE');
    plot(ax, f, db(Ya), '--', 'Color', P.cAct, 'LineWidth', 1.8, 'DisplayName', 'Actual RTL / SCALE');
    top = max([db(X); db(Ya)]) + 14;
    switch r.kind
        case 'impulse'
            fr = linspace(0, P.FS/2, 1001);
            plot(ax, fr, db(h_theory(P, coeff, fr) * 1000), ':', 'Color', P.ink, 'LineWidth', 1.8, ...
                 'DisplayName', 'Lý thuyết IMPULSE_AMP·|H(f)|');
            ylim(ax, [top - 100, top]);
        case 'step'
            ylim(ax, [top - 110, top]);
        otherwise
            ylim(ax, [-40, top]);
    end
    xlim(ax, [0 P.FS/2]);
    xlabel(ax, 'Tần số (Hz)'); ylabel(ax, yl);
    for g = r.gains
        xline(ax, g.f, ':', 'Color', P.ink2, 'LineWidth', 1.2, 'HandleVisibility', 'off');
        ha = 'left'; dx = 40; if g.f > 4500, ha = 'right'; dx = -40; end
        text(ax, g.f + dx, top - 3, {sprintf('%d Hz', g.f), ...
             sprintf('vào %.0f → ra %.1f', g.aIn, g.aOut), sprintf('đo RTL %+.2f dB', g.gAct)}, ...
             'VerticalAlignment', 'top', 'HorizontalAlignment', ha, 'FontSize', 11, 'Color', P.ink);
    end
    legend(ax, 'Location', 'southwest');
end

function fig = fig_freq(P, r, coeff)
    if strcmp(r.kind, 'impulse')
        fig = new_figure(sprintf('%s - miền tần số', r.name), [90 50 1300 920]);
        tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    else
        fig = new_figure(sprintf('%s - miền tần số', r.name), [90 90 1300 640]);
        tl = tiledlayout(fig, 1, 1, 'Padding', 'compact');
    end
    title(tl, {sprintf('%s — %s: miền tần số', r.name, r.desc), ...
               sprintf('(0 – %d Hz Nyquist; output chia SCALE = %d)', P.FS/2, P.SCALE)}, ...
          'FontWeight', 'bold', 'FontSize', 14, 'Interpreter', 'none');
    ax1 = new_axes(P, tl);
    draw_fft(P, ax1, r, coeff);
    switch r.kind
        case 'sine'
            title(ax1, {sprintf('Phổ biên độ: cửa sổ Hann, bỏ %d mẫu quá độ đầu (n = %d…%d)', ...
                        P.TRANS, P.TRANS, P.N - 1), 'cùng chuẩn hóa 2|X|/Σw; độ lợi ghi trên hình đo bằng fit bình phương tối thiểu'});
            badge(P, ax1, r, [0.38 0.97]);
        case 'impulse'
            title(ax1, '|DFT| không cửa sổ, đủ 1000 mẫu (cửa sổ sẽ xóa xung tại n = 0)');
            badge(P, ax1, r);
            ax2 = new_axes(P, tl);
            [f, X] = raw_dft(P, r.x);
            [~, Ye] = raw_dft(P, r.ye / P.SCALE);
            [~, Ya] = raw_dft(P, r.ya / P.SCALE);
            fr = linspace(0, P.FS/2, 1001);
            patch(ax2, [2000 3000 3000 2000], [-95 -95 6 6], P.grid, 'EdgeColor', 'none', ...
                  'FaceAlpha', 0.6, 'HandleVisibility', 'off');
            plot(ax2, fr, db(h_theory(P, coeff, fr)), ':', 'Color', P.ink, 'LineWidth', 1.8, ...
                 'DisplayName', 'Lý thuyết |H(f)| từ c[] trong fir.cpp');
            plot(ax2, f, db(Ye ./ X), '-', 'Color', P.cExp, 'LineWidth', 2.6, ...
                 'DisplayName', 'Đo từ Expected: |Y/SCALE| / |X|');
            plot(ax2, f, db(Ya ./ X), '--', 'Color', P.cAct, 'LineWidth', 1.8, ...
                 'DisplayName', 'Đo từ Actual RTL: |Y/SCALE| / |X|');
            for fq = [500 4000]
                k = round(fq * P.N / P.FS) + 1;
                xline(ax2, fq, ':', 'Color', P.ink2, 'LineWidth', 1.2, 'HandleVisibility', 'off');
                text(ax2, fq + 40, -6, {sprintf('%d Hz: đo RTL %+.2f dB', fq, db(Ya(k) / X(k))), ...
                     sprintf('lý thuyết %+.2f dB', db(h_theory(P, coeff, fq)))}, ...
                     'VerticalAlignment', 'top', 'FontSize', 11, 'Color', P.ink, 'BackgroundColor', 'w');
            end
            text(ax2, 2500, -85, {'dải chuyển tiếp', '2000–3000 Hz'}, 'HorizontalAlignment', 'center', ...
                 'FontSize', 11, 'Color', P.ink2);
            xlim(ax2, [0 P.FS/2]); ylim(ax2, [-95 6]);
            xlabel(ax2, 'Tần số (Hz)'); ylabel(ax2, 'Độ lợi (dB)');
            title(ax2, 'Đáp ứng tần số đo từ đáp ứng xung (xung chứa mọi tần số với cùng biên độ)');
            legend(ax2, 'Location', 'southwest');
        case 'step'
            title(ax1, {'|DFT| không cửa sổ, đủ 1000 mẫu. Bậc thang bị cắt cụt ở n = 999 nên tỉ số', ...
                        'phổ ra/vào KHÔNG phải |H(f)|: không suy ra độ lợi theo tần số từ hình này'});
            settled = r.ya(100 + P.TAPS + 1:end) / P.SCALE;
            g = mean(settled) / r.x(end);
            text(ax1, 0.99, 0.97, {sprintf('Độ lợi DC đo trong miền thời gian (n ≥ %d): %.4f (%+.3f dB)', ...
                 100 + P.TAPS, g, db(g)), sprintf('Lý thuyết sum(c)/SCALE = %.4f', sum(coeff) / P.SCALE)}, ...
                 'Units', 'normalized', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', ...
                 'FontSize', 11, 'EdgeColor', P.grid, 'BackgroundColor', 'w', 'Color', P.ink);
            badge(P, ax1, r);
    end
end

function draw_error(P, ax, r)
    n = (0:P.N - 1).';
    stairs(ax, n, double(r.err), 'Color', P.ink, 'LineWidth', 1.6, ...
           'DisplayName', 'error[n] = actual − expected');
    if r.bitExact
        ylim(ax, [-1 1]); yticks(ax, [-1 0 1]);
        text(ax, 0.01, 0.22, 'max |error| = 0 (so sánh số nguyên signed 32-bit, không tolerance)', ...
             'Units', 'normalized', 'FontSize', 11, 'Color', P.ink);
    else
        m = r.mism;
        plot(ax, m - 1, double(r.err(m)), 'x', 'Color', P.cCrit, 'MarkerSize', 9, 'LineWidth', 2, ...
             'DisplayName', 'mẫu sai');
        i = m(1);
        text(ax, 0.01, 0.06, {sprintf('Sai đầu tiên: n = %d, expected = %d, actual = %d', ...
             i - 1, r.ye(i), r.ya(i)), sprintf('max |error| = %d', r.maxAbs)}, 'Units', 'normalized', ...
             'VerticalAlignment', 'bottom', 'FontSize', 11, 'EdgeColor', P.cCrit, 'BackgroundColor', 'w');
        legend(ax, 'Location', 'southeast');
    end
    badge(P, ax, r);
    xlim(ax, [0 P.N - 1]);
    xlabel(ax, 'Chỉ số mẫu n'); ylabel(ax, 'actual − expected (LSB)');
end

function fig = fig_error(P, r)
    fig = new_figure(sprintf('%s - sai số', r.name), [120 120 1300 440]);
    tl = tiledlayout(fig, 1, 1, 'Padding', 'compact');
    ax = new_axes(P, tl);
    draw_error(P, ax, r);
    title(ax, sprintf('%s — %s: sai số RTL, bit-exact từng mẫu (%d/%d khớp)', ...
          r.name, r.desc, r.nMatch, P.N));
end

function fig = fig_comparison(P, rs, coeff)
    fig = new_figure('FIR11 - tổng hợp mixed + noise', [40 30 1600 1000]);
    tl = tiledlayout(fig, 3, numel(rs), 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl, 'FIR11 HLS — RTL (tb_fir11_vectors) so với Python: giữ 500 Hz, suy giảm 4000 Hz, khớp bit-exact', ...
          'FontWeight', 'bold', 'FontSize', 14, 'Interpreter', 'none');
    for j = 1:numel(rs)
        r = rs(j);
        ax = nexttile(tl, j); prep(P, ax);
        draw_time(P, ax, r, r.zoom(1), r.zoom(2), true);
        title(ax, sprintf('%s: miền thời gian, mẫu %d–%d', r.name, r.zoom(1), r.zoom(2) - 1), 'Interpreter', 'none');
        legend(ax, 'Location', 'northeast');
        ax = nexttile(tl, numel(rs) + j); prep(P, ax);
        draw_fft(P, ax, r, coeff);
        title(ax, sprintf('%s: phổ (Hann, bỏ quá độ)', r.name), 'Interpreter', 'none');
        ax = nexttile(tl, 2*numel(rs) + j); prep(P, ax);
        draw_error(P, ax, r);
        title(ax, sprintf('%s: actual − expected', r.name), 'Interpreter', 'none');
    end
end

function prep(P, ax)
    hold(ax, 'on'); grid(ax, 'on'); box(ax, 'off');
    set(ax, 'FontSize', 11, 'GridColor', P.grid, 'GridAlpha', 1, 'XColor', P.ink2, 'YColor', P.ink2);
end
