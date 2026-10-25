> Lưu trữ lịch sử: các firmware phụ và testbench tương ứng đã được bỏ khi tinh gọn project.
> Các tên/lệnh/kết quả bên dưới mô tả trạng thái tại thời điểm kiểm chứng.
> Luồng hiện hành: [fir_timer_1000.c](../firmware/fir_timer_1000.c); xem
> [hướng dẫn hiện tại](../firmware/README.md) để build và chạy.

# Giai đoạn 4.1 — deadline checker và verification trước synthesis

> **Báo cáo lịch sử (Giai đoạn 4.1, trước Phase 5).** Kết quả dưới đây mô tả RTL tại thời điểm đó.
> Đã thay đổi ở Phase 5 (2026-10-21, [PHASE5_VERIFICATION.md](PHASE5_VERIFICATION.md)): địa chỉ không
> map trả **DECERR**; `cpu_axi_master` kiểm BRESP/RRESP (thanh ghi BUSERR); RAM ngoài không trả lời thì
> giao dịch kết thúc bằng **SLVERR sau 1 024 chu kỳ** (CPU không còn treo); có reset synchronizer; đã
> chạy Vivado synthesis (synthesis PASS, timing 100 MHz FAIL). Mục "Giới hạn trước synthesis" bên dưới
> vì vậy không còn đúng hoàn toàn. Trạng thái tổng thể hiện tại: [README](../README.md).

Ngày chạy: 2026-10-21. Simulator: Vivado XSim 2026.1, CPU/AXI/FIR HLS thật,
clock 100 MHz, backend `sdram_model` hiện có. Đây là verification mô phỏng;
không synthesis, không thay backend RAM, không commit/push.

## Kết quả XSim cuối cùng

**44/44 simulation run đạt expectation, 0 lỗi checker**: regression 26/26,
ma trận 12/12, special 6/6. Tổng 117,397 checks. Bốn expected-red mutation
đều bị từ chối đúng lý do; ba kiểm tra artifact Python cũng từ chối dữ liệu sai.
Ngoài checker trong XSim, đã đọc lại 20 file `actual.dat` (20.000 mẫu) và so
bit-exact với reference vừa sinh, kiểm lại fixture/header và SHA-256 image.

| Dataset | B (bypass) | C (cache) | Checks/run | Miss/coalesced |
|---|---|---|---:|---|
| `test_01_low` | PASS 1000/1000 | PASS 1000/1000 | 83 | 0/0 |
| `test_02_high` | PASS 1000/1000 | PASS 1000/1000 | 83 | 0/0 |
| `test_03_mixed` | PASS 1000/1000 | PASS 1000/1000 | 83 | 0/0 |
| `test_04_noise` | PASS 1000/1000 | PASS 1000/1000 | 83 | 0/0 |
| `test_05_impulse` | PASS 1000/1000 | PASS 1000/1000 | 83 | 0/0 |
| `test_06_step` | PASS 1000/1000 | PASS 1000/1000 | 83 | 0/0 |

Mỗi run thường: 1000 tick cách nhau đúng 10000 clock, backlog tối đa 1,
1000 Timer ISR + 1000 FIR ISR, 2001 ACK, 2000 kiểm tra ngữ cảnh x1..x31,
không BUSY write/OVERRUN, input/output đúng thứ tự và đúng reference.

| Số đo thường (clock) | B | C |
|---|---:|---:|
| tick → IRQ take min/avg/max | 2/2/5 | 2/3/5 |
| tick → accept min/avg/max | 126/127/137 | 112/130/200 |
| Jitter accept | 11 | 88 |
| Khoảng accept min/max | 9994/10011 | 9913/10088 |
| tick → store min/avg/max | 236/237/247 | 225/244/313 |
| accept → FIR done | 17 | 17 |
| Longest CPU bus transaction | 32 | 99 |
| Cycle tới HALT | 10032106 | 10035454 |

Các số đo trên được kiểm bằng log của cả sáu dataset ở mỗi cấu hình.

| Special | B | C |
|---|---|---|
| Reset giữa giao dịch/ISR/refill | PASS, 3 điểm, 134 checks | PASS, 4 điểm, 151 checks |
| Quá tải PERIOD=100 | PASS, 79 checks | PASS, 79 checks |
| Deadline miss TB/firmware khi quá tải | 1000/1000 | 1000/1000 |
| Max backlog TB/firmware | 967/967 | 948/948 |
| Tick gộp trong scheduling (clock/firmware) | 139/139 | 175/175 |
| Hai nguồn pending đồng thời | 96497 clock | 97916 clock |
| Output đúng thứ tự khi quá tải | 1000/1000 | 1000/1000 |
| Delay phản hồi output cuối 20000 clock | PASS, 76 checks | PASS, 76 checks |
| tick cuối → store cuối trong ca delay | 20230 clock | 20214 clock |
| Miss TB/firmware và mã thoát trong ca delay | 1/1, exit 6 | 1/1, exit 6 |

Firmware cũ nguyên bản còn được giữ trong `D:/SoC/verification_evidence/phase41_2026-10-21/phase41_baseline/firmware` (bản lưu cục bộ, ngoài repo)
và chạy với cùng stimulus: store cuối ở +20232 clock, `tb_missed=1`,
`fst.missed=0`, firmware exit 0. Mutation tái lập bằng script cũng cho
miss 1/0, exit 0 (+20227 clock với phần tối ưu gửi/backlog mới).

Regression đầy đủ:

| Test | Checks | Cycle tới HALT (nếu có) | Result |
|---|---:|---:|---|
| `tb_fir11_wrapper` | 477 | — | PASS |
| `tb_fir11_vectors` | 90985 | — | PASS |
| `tb_axi_fir` | 36 | — | PASS |
| `tb_ext_ram_cfgA` | 9 | — | PASS |
| `tb_ext_ram_axi_b` | 8343 | — | PASS |
| `tb_ext_ram_axi_c` | 8343 | — | PASS |
| `tb_cpu_bus_b` | 104 | — | PASS |
| `tb_cpu_bus_c` | 162 | — | PASS |
| `tb_timer` | 2013 | — | PASS |
| `tb_irq_ack` | 439 | — | PASS |
| `tb_cpu_fault_b` | 2008 | — | PASS |
| `tb_cpu_fault_c` | 2008 | — | PASS |
| `tb_cpu_firmware` | 28 | 1672 | PASS |
| `tb_cpu_fir_firmware` | 54 | 1509 | PASS |
| `tb_cpu_fir_stream` | 71 | 6365 | PASS |
| `tb_cpu_ext_ram_b` | 47 | 8524 | PASS |
| `tb_cpu_ext_ram_c` | 47 | 13072 | PASS |
| `tb_cpu_fir_1000` | 82 | 218389 | PASS |
| `tb_cpu_fir_1000_c` | 82 | 230955 | PASS |
| `tb_cpu_timer_irq_a` | 58 | 120212 | PASS |
| `tb_cpu_timer_irq_b` | 59 | 120212 | PASS |
| `tb_cpu_timer_irq_c` | 59 | 120211 | PASS |
| `tb_cpu_fir_timer` | 66 | 321098 | PASS |
| `tb_cpu_fir_timer_stress` | 60 | 8609 | PASS |
| `tb_cpu_fir_timer_1000_b` | 83 | 10032106 | PASS |
| `tb_cpu_fir_timer_1000_c` | 83 | 10035454 | PASS |

`D:/SoC/verification_evidence/phase41_2026-10-21/phase41_final/results.json` chứa các kết quả từng run và đường dẫn log;
`artifact_validation.json` chứa đối chiếu 20 stream và hash fixture/image.

## Thay đổi và cơ chế deadline

| File | Lý do |
|---|---|
| `firmware/fir_timer_isr.h` | Giữ Timer chạy xuyên suốt output cuối; mask riêng Timer IRQ khi đủ N release; chỉ dừng clock sau store cuối và lần đọc deadline. Rút gọn điều kiện gửi và clamp backlog để vẫn vừa IMEM. |
| `firmware/fir_timer.c`, `firmware/fir_timer_1000.c` | Cập nhật mô tả luồng dùng chung ISR; không đổi polling firmware. |
| `scripts/build_firmware.py` | Thêm image `fir_timer_1000_stress`, PERIOD=100, vẫn kiểm ISA và giới hạn bộ nhớ. |
| `tb/tb_cpu_fir_timer_1000.v` | Deadline từ clock độc lập, ngân sách timing cố định, reset giữa giao dịch/ISR/refill, stress, delay output cuối, delay input, lưu `actual.dat`. |
| `tb/tb_cpu_fir_timer.v` | Áp dụng hợp đồng drain clock cho bản 32 mẫu; deadline và timing budget độc lập. |
| `tb/tb_irq_ack.v` | Kiểm cạnh IRQ trước/đúng/sau ACK, nguồn ACK khác nguồn ưu tiên, đồng thời và coalescing. |
| `tb/tb_cpu_fault.v` | CPU thật nhận SLVERR thật và backend không phản hồi, ở B/C; chỉ đặc tả hành vi hiện tại. |
| `scripts/run_rtl_tests.py` | Sinh dataset/header theo từng run, build riêng image 1000 mẫu, ghi provenance SHA-256, đăng ký test mới. |
| `.gitignore` | Bỏ các thư mục suite/scratch Giai đoạn 4.1 khỏi danh sách file nguồn. |
| `scripts/verify_phase41.py` | Chạy lại các suite matrix/special/regression/mutations, kiểm exit code, marker và lý do expected-red cụ thể. |

Không sửa RTL trong Giai đoạn 4.1. Các thay đổi RTL đã có sẵn trong working tree
khi bắt đầu (`timer.v`, `soc_pkg.vh`, `soc_top.v`) được giữ nguyên.

Với sample i (đánh số từ 0), release là tick i+1, deadline là thời điểm tick i+2.
Firmware chỉ có TICK_COUNT, không có cycle CSR mà CPU hỗ trợ. Cơ chế mới:

1. Timer IRQ cập nhật release, số tick gộp và backlog như trước.
2. Khi đã quan sát đủ N release, ghi INT_ENABLE=2 để mask Timer IRQ. Timer và
   TICK_COUNT tiếp tục chạy. Điều này cũng tránh Timer ưu tiên cao làm đói FIR
   vô hạn khi PERIOD ngắn hơn thời gian phục vụ một Timer ISR.
3. FIR ISR ACK nguồn đã đọc, đọc DATA_OUT một lần, hoàn tất store, rồi đọc
   TICK_COUNT đang chạy. Nếu tick mới nhất > i+1, tăng `fst.missed`.
4. Sau lần quan sát deadline của output cuối, dừng Timer và cập nhật `done`.

Firmware đo bảo thủ: lần quan sát sau store có thể qua deadline mặc dù store
vừa xong trước deadline. Testbench tách hai phép kiểm: deadline **hoàn tất store**
tính bằng clock tuyệt đối, và kết quả báo cáo bảo thủ của firmware tính bằng
clock tại cạnh snapshot MMIO. Không dùng RDATA/TICK_COUNT để tính expected miss.
Đối với RAM ngoài, hoàn tất store là phản hồi CPU sau AXI B; backend có thể đã
ghi RAM sớm hơn thời điểm master chấp nhận phản hồi.

Timer có thể để lại một pending bit bị mask sau khi drain. Checker yêu cầu
không còn **enabled pending**, kiểm đếm riêng cả pending Timer bị mask và tất
cả cạnh Timer đến trong lúc drain. `fst.coalesced` chỉ đếm tick thuộc giai đoạn
scheduling, được đối chiếu với clock tại snapshot cuối trừ số Timer ISR.
Trong log, `tim_coal` tổng còn bao gồm tick sau khi mask; hai số này có phạm vi khác nhau.

## Ngân sách timing độc lập

Áp dụng cho luồng thường ở cả B/C và mọi dataset, khai báo trước measurement:

| Đại lượng | Ngưỡng tại 100 MHz |
|---|---:|
| tick → IRQ take | ≤16 clock (0,16 µs) |
| tick → FIR nhận DATA_IN | ≤400 clock (4 µs) |
| tick → output store hoàn tất | ≤500 clock (5 µs) |
| Jitter của tick → accept | ≤128 clock (1,28 µs) |
| Khoảng accept liên tiếp | PERIOD ±128 clock |
| accept → FIR hoàn tất | đúng 17 clock |
| Deadline store | trước release kế tiếp (PERIOD=10000) |

Đây là ngân sách verification cố định cho backend hiện tại, dành 4%/5% chu kỳ
cho accept/store, không phải giá trị được suy ra từ min/max của chính run.
Các ca stress/delay có expectation riêng bắt buộc phát hiện trễ; checker dữ liệu,
ngữ cảnh, giao dịch, không BUSY/OVERRUN và không mất/lặp mẫu vẫn hoạt động.
Timeout chỉ tăng trong ca delay có chủ đích theo độ dài stimulus; luồng thường
vẫn giữ giới hạn giao dịch 300 clock.

## Dataset và chống reference cũ

Mỗi run 1000 mẫu gọi `gen_fir_1000_data.build(dataset)` để sinh cùng lúc
`input.mem`, `expected.mem`, `layout.mem`, `manifest.txt`, `fir_1000_data.h`.
Generator đối chiếu mô hình FIR Python với `expected.dat` nguồn. Header nằm
trong bản copy source riêng của run và GCC build image từ bản copy đó.
Testbench còn tự tính reference Verilog từ input rồi đối chiếu expected và
toàn bộ output trong SDRAM. Firmware thường đọc lại output và kiểm SUM/XOR.

`provenance.json` ghi hash source và image/fixture; `actual.dat` ghi 1000 giá trị
thực đọc từ SDRAM. Không sửa các fixture noise đang được polling firmware sử
dụng trong repo. `--no-firmware-build` bị từ chối cho Timer/FIR 1000 để tránh
dùng image với checksum/header của dataset trước.

## Reset, IRQ và fault injection

Reset B có ba điểm, C có bốn điểm: đọc RAM qua CPU/AXI đang chờ backend; ghi
output đang chờ backend; CPU trong ISR khi FIR BUSY; và cache đang chờ refill
sau word đầu tiên (C). Kiểm reset PC, hủy phản hồi CPU/AXI/backend, xóa IRQ,
DONE/BUSY, invalidate tất cả cache line và không có completion cũ trong startup.
Sau các lần abort, chạy lại toàn luồng 1000 mẫu với đầy đủ checker.
Không xóa SDRAM hay lịch sử HLS từ testbench để che lỗi reset.

IRQ/ACK kiểm 48 tổ hợp: 4 trạng thái pending × 2 nguồn cạnh mới × 2 nguồn ACK
× 3 offset (-1/0/+1 clock), thêm hai cạnh đồng thời và Timer bị gộp. Dùng
controller thật ở biên pin, 439 checks; luồng overload dùng CPU/firmware thật
kiểm hai pending cùng lúc, tick gộp và bảo toàn 1000 mẫu.

Fault CPU dùng lệnh lw/sw thật vào FIR CTRL không thẳng hàng để interconnect
trả một BRESP SLVERR và một RRESP SLVERR. CPU nhận hai completion, đọc payload
0, chạy tới sentinel DMEM và không trap; FIR không bị tác động. Backend fault
giữ ready tại biên backend ở 0 trong 2000 clock: PC/request giữ nguyên,
bus_stall giữ mức, không có completion, timeout hay tiến triển giả; reset abort
giao dịch. B/C mỗi ca 2008 checks.

Bốn expected-red mutation được chạy bằng XSim, không sửa RTL/source chính:

- Khôi phục hành vi dừng clock ở release cuối: output cuối hoàn tất sau hơn
  20000 clock, testbench đếm một miss, firmware đếm 0; checker từ chối.
- Giữ phản hồi input 400 clock: deadline 10000 vẫn đạt và firmware trả 0,
  nhưng accept/store/jitter vượt ngân sách cố định; checker từ chối.
- Giữ phản hồi input 200 clock: chỉ jitter/accept interval vượt ngưỡng; latency,
  deadline, dữ liệu và mọi giao dịch vẫn trong giới hạn thường. Công thức jitter
  tự tham chiếu cũ sẽ không phát hiện trường hợp này.
- Đổi ACK sang nguồn ưu tiên hiện tại trong bản copy controller: 76 lỗi trong
  439 checks IRQ/ACK; checker từ chối.

Các lỗi thật được xác nhận là blind spot của firmware cũ và ngưỡng jitter tự
tham chiếu của checker cũ. Các mutation khác là lỗi chủ đích để kiểm checker,
không được báo là lỗi mới đang tồn tại trong RTL chính.

## Chạy lại và bằng chứng

Từ thư mục project:

```powershell
python scripts/verify_phase41.py --vivado-root D:/vivado/2026.1/Vivado --suite matrix
python scripts/verify_phase41.py --vivado-root D:/vivado/2026.1/Vivado --suite special
python scripts/verify_phase41.py --vivado-root D:/vivado/2026.1/Vivado --suite regression
python scripts/verify_phase41.py --vivado-root D:/vivado/2026.1/Vivado --suite mutations
```

Mặc định output `outfeed/phase41`; bằng chứng của lần thực hiện này dùng
`--output outfeed/phase41_final` (đã chuyển sang `D:/SoC/verification_evidence/phase41_2026-10-21/phase41_final`). Mỗi suite có `summary.json`. Mỗi test có
`runner.log` và thư mục con chứa compile/elaborate/simulate logs, fixture,
firmware ELF/disassembly/build report và provenance. Mutation expected-red
chỉ đạt khi XSim đã chạy, có TEST FAILED và đúng thông báo phát hiện lỗi;
compile lỗi hoặc thiếu marker không được tính là đạt.

## Giới hạn trước synthesis

- CPU/master vẫn không đưa BRESP/RRESP error vào phần mềm, không trap lỗi bus,
  không có timeout. Backend treo có thể treo CPU/ISR vô hạn; bộ đếm deadline
  của firmware chỉ cập nhật khi giao dịch đã hoàn tất.
- Độ phân giải deadline firmware là một tick, với observation bảo thủ sau
  store; không tuyên bố có timestamp cycle chính xác trong firmware.
- Không IRQ lồng nhau, Timer có ưu tiên cao hơn FIR; mask Timer ở cuối release
  là cần thiết để drain backlog. Không có cơ chế phục hồi quá tải vô hạn khi
  nguồn input tiếp tục vô hạn với tốc độ vượt năng lực xử lý.
- IMEM/DMEM vẫn 1 KB. Bản 1000 thường 828 byte IMEM, stress 824; bản 32 thường
  1016, stress 1000. DMEM dữ liệu/stack: 40+256 byte (1000), 296+256 byte (32).
  Bản 32 chỉ còn 8 byte IMEM dự phòng.
- RF/DMEM, SDRAM và lịch sử HLS không có hợp đồng xóa toàn bộ dữ liệu bởi reset.
  Firmware khởi tạo stack/BSS và flush 10 mẫu; cache valid bị invalidate.
- Phép so sánh tick có dấu chỉ được kiểm trong run hữu hạn nhỏ hơn 2^31 tick;
  không xác nhận wraparound/run liên tục dài hạn.
- Backend vẫn là mô hình SDRAM mô phỏng. Chưa có PHY, timing FPGA, reset
  synchronizer, synthesis/implementation hay kiểm chứng khả năng chạy trên board.

