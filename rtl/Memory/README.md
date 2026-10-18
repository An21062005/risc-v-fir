# rtl/Memory: RAM dữ liệu ngoài (SDRAM mô phỏng + cache tùy chọn) — đề mục mở rộng

> **Phạm vi.** Đây là phần mở rộng để nghiên cứu/demo bộ nhớ ngoài. **Không** có bằng chứng FIR11
> bắt buộc phải dùng nó: FIR11 HLS giữ lịch sử mẫu trong IP và nhận từng mẫu qua thanh ghi.
> Phần mềm `sw/` **chưa có**, nên **chưa có số liệu dung lượng** chương trình/dữ liệu/stack.
> Nếu chỉ thiếu chỗ chứa dữ liệu (ví dụ 600 mẫu vào + 600 kết quả = 4 800 byte > DMEM 1 KB),
> mở rộng RAM nội bộ hoặc xử lý theo khối là lựa chọn đơn giản hơn.
> Cấu hình mặc định của `soc_top` (`ENABLE_EXT_RAM = 0`) **không dùng** gì trong thư mục này.
>
> **Trạng thái:** đã chạy regression XSim A/B/C và directed CPU test B/C;
> xem [RTL_FIX_VERIFICATION.md](../../docs/RTL_FIX_VERIFICATION.md) cho phạm vi và kết quả.
> Cấu trúc theo repo gốc: chỉ hai file `cache_controller.v` (top = `cache_top`) và `sdram.v`.
> Các mô tả hành vi dưới đây là đọc từ mã, không phải kết quả đo.

## 1. Ba cấu hình

| Cấu hình | Tham số `soc_top` | Danh sách file | Ghi chú |
|---|---|---|---|
| A (mặc định) | `ENABLE_EXT_RAM=0` | `rtl/filelist_fir11.f` | SoC FIR11 như trước, không instance gì thêm. Vùng 0x4001_xxxx không map (đọc 0, ghi bỏ qua) |
| B | `ENABLE_EXT_RAM=1 EXT_RAM_USE_CACHE=0` | `rtl/filelist_fir11.f` + `rtl/filelist_ext_ram_sim.f` | `cache_top` chế độ bypass → SDRAM mô phỏng |
| C | `ENABLE_EXT_RAM=1 EXT_RAM_USE_CACHE=1` | như B | `cache_top` có `cache_controller` → SDRAM mô phỏng |

B và C **chỉ dùng cho mô phỏng**: `sdram_top` chứa `sdram_model` (thiết bị nhớ hành vi), chưa có lớp
PHY/IO tới chip SDRAM thật. Không đưa `rtl/Memory/sdram.v` vào danh sách tổng hợp FPGA.
Cả ba cấu hình đều giữ nguyên RTL FIR11 HLS và bước chép 2 file `.dat` của IP (`scripts/prep_fir11_dat.sh`).

## 2. Kiến trúc và nối dây

Cây `rtl/Memory` dùng để biên dịch (giống cấu trúc repo gốc):

```
rtl/Memory/
├─ cache_controller.v   cache_tag_ram, cache_data_ram, main_memory (tham chiếu, không instance),
│                       cache_controller, cache_dma_arbiter, cache_top   ← top bộ nhớ
├─ sdram.v              sdram_fsm, refresh_controller, sdram_controller, sdram_top, sdram_model
└─ README.md
```

Các file của bản trước (`ext_mem_top.v`, `ext_ram_slave.v`, `model/sdram_sim.v`) đã được gộp
chức năng vào hai file trên và `rtl/AXI/AXI_Interconnect.v`, rồi xóa.

```
 IF: PC -> IMEM 1 KB (program.mem)          (không đổi; không có I-cache, không chạy lệnh từ SDRAM)
 MEM: addr[31:30] != 01 -> DMEM 1 KB          (không đổi)
      addr[31:30] == 01 -> cpu_axi_master -> axi_interconnect #(ENABLE_EXT_RAM)
            ├─ 0x080 timer, 0x1C0 interrupt_axi_wrapper, 0x200 fir11_wrapper   (không đổi)
            └─ 0x0001_0000..0x0001_FFFF (chỉ khi ENABLE_EXT_RAM=1)
                 WRITE_FSM (ext_ram_wr_req, giữ addr/data) ─┐
                 READ_FSM  (ext_ram_rd_req, giữ addr)    ───┴─► EXT_RAM_ARB (axi_ext_ram_arbiter)
                                                                   │ cpu_read/cpu_write/cpu_addr/cpu_wdata
                                                                   ▼ cpu_rdata/cpu_ready
                 g_ext_ram.u_ext_mem = cache_top #(USE_CACHE = EXT_RAM_USE_CACHE)
                    ├─ USE_CACHE=1: g_cache.U_CACHE_CONTROLLER (cache_controller)
                    └─ USE_CACHE=0: g_bypass (nối thẳng)
                         ▼ cache_mem_*
                    U_ARBITER (cache_dma_arbiter, dma_* = 0)
                         ▼ arb_mem_*
                    U_SDRAM (sdram_top) = REFRESH + FSM + CONTROLLER + MEMORY (sdram_model)
```

| Từ | Tín hiệu | Tới | Ghi chú |
|---|---|---|---|
| `u_interconnect` (`EXT_RAM_ARB`) | `ext_ram_read/ext_ram_write` (mức), `ext_ram_addr`, `ext_ram_wdata` | `g_ext_ram.u_ext_mem.cpu_read/cpu_write/cpu_addr/cpu_wdata` | giữ mức tới `cpu_ready`, hạ tổ hợp trong chu kỳ `cpu_ready`; `addr` = bus − `EXT_RAM_BASE` |
| `u_ext_mem` | `cpu_rdata`, `cpu_ready` | `u_interconnect.ext_ram_rdata/ext_ram_ready` | `cpu_rdata` chỉ được lấy đúng chu kỳ `cpu_ready` |
| `u_ext_mem.U_CACHE_CONTROLLER` hoặc bypass | `cache_mem_*` | `U_ARBITER.cache_mem_*` | |
| hằng 0 | `dma_mem_read/write/read_addr/write_addr/wdata` | `U_ARBITER` | SoC không có DMA; `dma_mem_rdata/ready` để hở |
| `U_ARBITER` | `arb_mem_*` | `U_SDRAM.read_req/write_req/address/write_data/read_data/ready` | thay instance `main_memory` của bản gốc |
| `soc_top.rst` (= `~rst_n`) | `rst` | `cache_top` | mức cao, style bản gốc; interconnect dùng `rst_n` |

Khi `ENABLE_EXT_RAM=0`, nhánh `g_no_ext_ram` buộc `ext_ram_rdata = 0`, `ext_ram_ready = 0`; decoder
không bao giờ chọn RAM nên FSM không bao giờ bật yêu cầu.

## 3. Bản đồ địa chỉ

| Vùng | Địa chỉ CPU | Địa chỉ bus | Đích |
|---|---|---|---|
| Timer | 0x4000_0080–0x4000_00BF | 0x080–0x0BF | `timer` (không đổi) |
| Bộ ngắt | 0x4000_01C0–0x4000_01FF | 0x1C0–0x1FF | `interrupt_axi_wrapper` (không đổi) |
| FIR11 | 0x4000_0200–0x4000_023F | 0x200–0x23F | `fir11_wrapper` (không đổi) |
| **RAM ngoài 64 KB** | **0x4001_0000–0x4001_FFFF** | **0x0001_0000–0x0001_FFFF** | `cache_top` qua interconnect (B/C); không map (A) |

`soc_pkg.vh`: `EXT_RAM_BASE = 32'h0001_0000`, `EXT_RAM_END = 32'h0001_FFFF`, `SEL_EXT_RAM = 4'd10`
(mã còn trống; không dùng lại `SEL_RAM = 1` của RAM bus 64 byte trong bản gốc). Mã và địa chỉ
Timer/Interrupt/FIR giữ nguyên. Không sửa CPU: `cpu_soc` đã đưa mọi địa chỉ `addr[31:30]==01` ra bus.
RAM ngoài **chỉ tăng dung lượng dữ liệu**; IMEM vẫn 1 KB.

Truy cập: chỉ word căn 4 byte với `WSTRB = 1111` (CPU chỉ có `lw/sw`). Ghi từng phần hoặc địa chỉ lệch
→ **không ghi gì**, BRESP = SLVERR; đọc địa chỉ lệch → RDATA = 0, RRESP = SLVERR. Không hỗ trợ
byte-enable. Lưu ý `cpu_axi_master` hiện bỏ qua BRESP/RRESP, nên phần mềm không thấy lỗi này.

## 4. Giao thức

**Interconnect** (`rtl/AXI/AXI_Interconnect.v`, tham số `ENABLE_EXT_RAM`). Phần chốt yêu cầu, giữ
yêu cầu tới completion và tuần tự hóa trước đây ở `ext_ram_slave` nay nằm ở:
- `axi_write_fsm`: ở bắt tay W, nếu slave đã chốt là RAM: kiểm cửa sổ/căn lề/`WSTRB`; hợp lệ thì chốt
  `ext_ram_wr_addr` (offset) và `ext_ram_wr_data`, bật `ext_ram_wr_req` (mức). WRITE_RESP chỉ bật
  BVALID khi có `ext_ram_wr_done` (cùng cạnh hạ `ext_ram_wr_req`); BRESP giữ tới BREADY.
- `axi_read_fsm`: ở READ_DATA kiểm cửa sổ/căn lề, chốt `ext_ram_rd_addr`, bật `ext_ram_rd_req`.
  READ_WAIT ở lại tới `ext_ram_rd_done`, chốt `ext_ram_rdata` đúng chu kỳ đó (ở chế độ cache
  `cpu_rdata` là tổ hợp, chỉ hợp lệ trong chu kỳ `cpu_ready`). READ_RESP trả dữ liệu đã chốt,
  RVALID/RDATA giữ tới RREADY.
- `axi_ext_ram_arbiter` (module mới trong cùng file): `active` = NONE/WR/RD. NONE → WR nếu có
  `wr_req`, ngược lại RD nếu có `rd_req` (**ghi trước, đọc sau**). `cpu_write = (active==WR) && !cpu_ready`,
  `cpu_read = (active==RD) && !cpu_ready`; `wr_done/rd_done = cpu_ready && active` tương ứng. FSM hạ
  `*_req` cùng cạnh `active` về NONE nên không yêu cầu nào bị cấp hai lần; yêu cầu còn lại vẫn chờ
  tới lượt, không bị mất. `cpu_ready` khi `active==NONE` (ready rảnh/cũ) bị bỏ qua.
- Lựa chọn RAM được chốt cùng AW/AR (`saved_ext_ram_sel`) và giữ suốt giao dịch.
- Nhánh Timer/Interrupt/FIR: `rd_en` và `wr_en` đều một xung/giao dịch.
  Read select được chốt ở AR handshake; đọc/gán cờ chỉ xảy ra một lần.
  MMIO chỉ hỗ trợ word căn 4 byte: ghi từng phần/lệch và đọc lệch trả SLVERR,
  không phát enable. Ghi căn lề với WSTRB=0000 là no-op/OKAY.

Truy cập bị từ chối (ghi `WSTRB != 1111`, ghi/đọc lệch, ngoài cửa sổ) **không tạo yêu cầu** tới
`cache_top`: BRESP = SLVERR; đọc trả RDATA = 0, RRESP = SLVERR.

**cache_top**: arbiter `cache_dma_arbiter` cần 1 chu kỳ MASTER_NONE → MASTER_CACHE trước mỗi giao dịch
backend (cả B và C), và nhả quyền khi `mem_ready`. `cache_controller` và `sdram_controller` đều hạ
yêu cầu tổ hợp trong chu kỳ ready (có sẵn trong bản gốc).

**Contract một outstanding:** `cpu_axi_master` chỉ có một giao dịch (chờ B/R rồi mới nhận yêu cầu mới),
nên thực tế không có đọc và ghi RAM chồng nhau; arbiter vẫn tuần tự hóa nếu có (testbench T9 ép
chồng nhau bằng BFM).

**CPU khi chờ lâu** (rà soát, không sửa): `bus_stall = (bus_rd|bus_wr) & ~bus_ready` giữ PC và cả 4
thanh ghi pipeline, nên địa chỉ/dữ liệu ở EX/MEM ổn định suốt lúc chờ; `cpu_axi_master` không có
timeout. `irq_take` có điều kiện `!bus_stall`, nên ngắt Timer/FIR tới lúc CPU đang chờ RAM được
**trì hoãn** tới khi `lw/sw` hoàn tất. Thanh ghi MMIO không đi qua cache (cache chỉ nằm trong `cache_top`).

## 5. Nguồn, giấy phép và thay đổi

Nguồn: `D:/SoC/tiny-riscv-soc` (MIT, © 2026 Leela Shanmukh Yagneek Patnala, file `LICENCE`). Repo
tham chiếu **không bị sửa**. Bản sao đổi CRLF → LF.

| Module (file dự án) | So với bản gốc |
|---|---|
| `cache_tag_ram` (`cache_controller.v`) | valid bit thành vector flop có reset (thêm cổng `rst`) → invalidate toàn bộ trong lúc reset, không đọc hit khi valid còn X |
| `cache_data_ram` | không đổi |
| `main_memory` | không đổi, **chỉ tham chiếu, không instance** (4 KB, cắt `addr[11:2]` → alias ≥ 4 KB) |
| `cache_controller` | không đổi ngoài nối `.rst` vào `cache_tag_ram` |
| `cache_dma_arbiter` | không đổi |
| `cache_top` | backend `main_memory` → **`sdram_top`**; thêm `USE_CACHE` (generate cache/bypass, cùng arbiter + backend) và `MODEL_DEPTH`; bỏ cổng DMA, đầu vào `dma_*` của arbiter buộc 0 |
| `sdram_fsm`, `refresh_controller` (`sdram.v`) | không đổi |
| `sdram_controller` | sửa ánh xạ địa chỉ (mục 6) |
| `sdram_top` | thêm tham số `MODEL_DEPTH` |
| `sdram_model` | tham số `DEPTH` (mặc định 32 768 halfword = 64 KB), truy cập ngoài DEPTH in `** Error`; khai báo `active_row/active_bank/row_open` trước khi dùng (bản gốc: Questa vlog-2730) |
| `rtl/packages/cache_pkg.vh` | bỏ `ADDR_WIDTH/DATA_WIDTH` (trùng `soc_pkg.vh`) |
| `rtl/packages/sdram_pkg.vh` | không đổi nội dung |
| `axi_write_fsm`, `axi_read_fsm`, `axi_ext_ram_arbiter` (`rtl/AXI/AXI_Interconnect.v`) | nhận chức năng của `ext_ram_slave` (mục 4) |

## 6. Cache và SDRAM (đọc từ mã)

**Cache** (`cache_controller`): direct-mapped **1 way**, 64 line × 16 byte = 1 KB, chỉ dữ liệu.
tag = `addr[31:10]`, index = `addr[9:4]`, word = `addr[3:2]`. Đọc hit: không truy cập backend (IDLE → LOOKUP → COMPLETE). Đọc miss: refill
4 word bằng **4 yêu cầu đọc word riêng** (không burst). Ghi: **write-through**; hit cập nhật line + ghi
backend; miss **write-no-allocate**. Không có dirty bit, không I-cache, không 2-way.

**SDRAM** (`sdram_controller` + `sdram_fsm` + `refresh_controller`): bus dữ liệu 16 bit, mỗi word =
ACTIVATE → READ/WRITE 2 halfword → PRECHARGE (đóng row sau mỗi truy cập, không burst). Refresh mỗi
780 chu kỳ, chỉ chạy khi FSM ở IDLE; yêu cầu tới lúc refresh được giữ mức và phục vụ sau. Init:
PRECHARGE → REFRESH ×2 → LOAD MODE → IDLE (không có chờ 100 µs). `ready` là xung 1 chu kỳ khi rời
PRECHARGE_ROW.

**Lỗi ánh xạ đã sửa trong bản sao.** Bản gốc: `row = addr[23:11]`, `column = {addr[10:2],1'b0}` gán vào
reg 9 bit → mất `addr[10]` → **0x000 và 0x400 trùng ô nhớ**. Suy lại từ hình học `sdram_pkg`
(512 cột × 16 bit, 8192 row, 4 bank):

| Bit địa chỉ byte | Trường |
|---|---|
| `[0]` | byte trong halfword (luôn 0) |
| `[9:1]` | column; word dùng cột `{addr[9:2],0}` và `{addr[9:2],1}` |
| `[22:10]` | row |
| `[24:23]` | bank |

Chỉ số halfword `{bank,row,col} = addr[24:1]`: tuyến tính, không mất bit, không alias trong 32 MB; hai
halfword của một word luôn ở hai cột liền nhau **cùng row** (word căn 4 byte không vượt ranh giới
row/bank). Cửa sổ 64 KB = bank 0, row 0–63. `addr[31:25]` bị bỏ qua (chỉ offset < 64 KB tới được đây).

**Giới hạn của model** (giữ từ bản gốc): đọc trả dữ liệu sau 1 cạnh clock, không mô phỏng CAS latency
thật — thời điểm chốt dữ liệu trong controller được căn theo model, không theo datasheet; không kiểm
tRCD/tRP/tRFC hay đủ refresh; bỏ qua LOAD MODE. `refresh_controller`: nếu bộ đếm chạm chu kỳ đúng lúc
`refresh_done` thì yêu cầu refresh đó bị xóa (chỉ xảy ra nếu refresh bị chặn đúng 780 chu kỳ; giao
dịch dài nhất khoảng 15 chu kỳ nên thực tế không gặp) — chưa sửa, ghi nhận.

## 7. Lệnh build (đã chạy: chỉ biên dịch + elaborate)

Từ thư mục dự án:
```bash
vlib work
vlog -lint -f rtl/filelist_fir11.f -f rtl/filelist_ext_ram_sim.f
vopt +acc soc_top -o socA                                           # A
vopt +acc soc_top -GENABLE_EXT_RAM=1 -GEXT_RAM_USE_CACHE=0 -o socB  # B
vopt +acc soc_top -GENABLE_EXT_RAM=1 -GEXT_RAM_USE_CACHE=1 -o socC  # C
```
`vlog` liệt kê `main_memory` là top-level không dùng — đúng ý đồ (chỉ tham chiếu).
Cấu hình A cũng elaborate được chỉ với `rtl/filelist_fir11.f` (nhánh generate không dùng không cần module RAM trong Questa).

## 8. Testbench

| File | Phạm vi |
|---|---|
| `tb/axi_lite_bfm.vh` | BFM AXI4-Lite master (backpressure BREADY/RREADY ngẫu nhiên, seed) + protocol checker VALID/payload giữ tới READY |
| `tb/tb_ext_ram_axi.v` | B/C (`-GUSE_CACHE=0/1`): interconnect + `cache_top` + interrupt_axi_wrapper thật. T0 yêu cầu lúc SDRAM init, đọc đầu sau reset là miss; T1 ranh giới 0, 4, 0x3FC, 0x400, 0x404, 0x7FC, 0x800, 0x8000, 0xFFF8, 0xFFFC + vị trí halfword trong model; T2 quét 0x000–0x80F; T3 4 word/line, read miss/refill, hit, write hit/miss, thay line cùng index khác tag, dữ liệu backend đúng **lúc BVALID**; T4 yêu cầu đúng lúc `refresh_request`; T5 mỗi giao dịch đúng 1 sườn lên `cpu_read/cpu_write` tới `cache_top`, đúng 1 done, số giao dịch backend so với mô hình cache trong TB, monitor `cpu_addr/cpu_wdata` không đổi khi chờ và `cpu_ready` không tới khi không có yêu cầu; T6 300 truy cập ngẫu nhiên; T7 WSTRB/lệch → SLVERR, không có yêu cầu bộ nhớ; T8 MMIO không chạm backend; T9 ghi và đọc RAM chồng nhau |
| `tb/tb_ext_ram_cfgA.v` | A: 0x0001_0000 đọc 0/OKAY, không có `ext_ram_read/write`; FIR `wr_en` và `rd_en` đều 1 xung |
| `tb/tb_axi_fir.v` | Interconnect + FIR HLS thật: yêu cầu liên tiếp, đổi địa chỉ sau handshake, WSTRB/lệch và đọc trùng hoàn tất |
| `tb/tb_cpu_bus.v` | CPU thật + AXI master + FIR + RAM B/C: stall, forwarding, không ghi trùng, Timer IRQ trong khi chờ RAM và MRET |

Đường dẫn phân cấp TB dùng: `u_mem.U_SDRAM.{state,refresh_request,refresh_done,CONTROLLER.saved_read,MEMORY.memory}`,
`u_mem.arb_mem_ready`, `u_ic.ext_ram_wr_done/rd_done`, `u_ic.EXT_RAM_ARB.active`
(trong `soc_top`: `g_ext_ram.u_ext_mem.U_SDRAM...`).

Chạy (Questa, từ thư mục dự án; không cần `.dat` FIR):
```bash
mkdir -p sim_ext && cd sim_ext && vlib work
vlog +incdir+../rtl/packages +incdir+../tb ../rtl/AXI/AXI_Interconnect.v \
     ../rtl/Peripherals/interrupt_axi_wrapper.v \
     ../rtl/Memory/cache_controller.v ../rtl/Memory/sdram.v \
     ../tb/tb_ext_ram_axi.v ../tb/tb_ext_ram_cfgA.v
vsim -c tb_ext_ram_axi -GUSE_CACHE=0 +seed=1 -do "run -all; quit -f"    # B
vsim -c tb_ext_ram_axi -GUSE_CACHE=1 +seed=1 -do "run -all; quit -f"    # C
vsim -c tb_ext_ram_axi -GUSE_CACHE=1 +seed=7 -do "run -all; quit -f"
vsim -c tb_ext_ram_cfgA -do "run -all; quit -f"                         # A
```
PASS chỉ khi log có `TEST PASSED`, không có `TEST FAILED`, `** Error` hoặc `** Fatal`.

`tb_cpu_bus.v` dùng fixture lệnh trực tiếp trong testbench, không phải firmware ứng dụng.
Đã kiểm Timer IRQ khi CPU chờ RAM B/C. FIR IRQ được bắt pending nhưng bị mask trong fixture này.
Chưa có firmware/linker/startup thực tế hoặc bài so sánh hiệu năng A/B/C.

## 9. Đánh giá hiệu năng (khi có phần mềm)

- Không khẳng định cache làm nhanh hơn trước khi đo.
- Cache bật/tắt: cùng backend `sdram_top`, cùng chương trình, cùng trạng thái định nghĩa trước
  (cold = ngay sau reset, valid đã xóa; warm = chạy lại vòng đo lần hai không reset).
- FIR phần mềm vs phần cứng: cùng tập mẫu, cùng nơi chứa buffer (DMEM hoặc RAM ngoài), ghi rõ có tính
  thời gian chép dữ liệu vào/ra hay không. `CYC_CNT` của FIR11 chỉ đo từ lúc nhận DATA_IN tới `ap_done`,
  không gồm giao dịch bus, truy cập RAM hay ISR; dùng Timer để đo đầu-cuối.
- Mỗi lần đọc qua bus tới ngoại vi thanh ghi mất khoảng 6–7 chu kỳ CPU (ước lượng từ FSM); RAM ngoài
  thêm thời gian SDRAM (khoảng 12 chu kỳ/word ghi, 15 chu kỳ/word đọc theo FSM SDRAM, chưa đo), cộng
  1 chu kỳ `cache_dma_arbiter` và 1 chu kỳ cấp quyền của `axi_ext_ram_arbiter` mỗi giao dịch, hoặc refill 4 word khi miss.

## 10. Chưa kiểm chứng

Chưa kiểm chứng ISA đầy đủ, firmware ứng dụng, mọi tổ hợp ngắt/reset, Icarus,
tổng hợp/implementation SoC hoặc lớp PHY SDRAM thật cho FPGA (chưa có).
Các regression XSim đã chạy và giới hạn của chúng được ghi trong
[RTL_FIX_VERIFICATION.md](../../docs/RTL_FIX_VERIFICATION.md).
