`timescale 1ns/1ps
`include "soc_pkg.vh"
`include "interrupt_pkg.vh"

//======================================================================
// soc_top : SoC RISC-V 5 giai đoạn + IP FIR (HLS) + bộ điều khiển ngắt
//======================================================================
// Đường dữ liệu:
//   rvcore32_pipeline_soc --(bus_*)--> cpu_axi_master --(AXI4-Lite)-->
//   axi_interconnect --(wr_en/rd_en, write_addr/read_addr, write_data)-->
//     { timer (0x080), interrupt_axi_wrapper (0x1C0), fir11_wrapper (0x200) }
//
// FIR: fir11_wrapper instance trực tiếp module `fir` do Vitis HLS v2024.1 sinh
//   ra (FIR11, bản sao trong rtl/Peripherals/FIR11/). Không còn tham số chọn
//   stub/FIR51; danh sách file: rtl/filelist_fir11.f. Cần chép 2 file .dat của
//   FIR11 vào thư mục chạy mô phỏng (xem rtl/Peripherals/FIR11/README.md).
//
// Ngắt: irq_in = {fir_irq, timer_irq}  (IRQ_TIMER = 0, IRQ_FIR = 1)
//   interrupt_controller.interrupt -> irq của CPU.
//
// Reset: ngõ vào rst_n (mức thấp). CPU và interrupt_controller dùng
//   rst = ~rst_n (mức cao). AXI master, interconnect và các ngoại vi dùng rst_n.
//   TODO(xác minh): rst_n đưa thẳng vào, chưa có reset synchronizer
//   (chấp nhận được cho mô phỏng; khi lên FPGA nên thêm).
//
// Bus có 3 slave (Timer, Interrupt, FIR). Địa chỉ không map: ghi bị bỏ
//   qua, đọc ra 0, bus không treo (xem axi_interconnect).
//
// Mở rộng (đề mục riêng, mặc định TẮT): RAM dữ liệu ngoài 64 KB
//   ENABLE_EXT_RAM = 0 (mặc định): cấu hình A, giống hệt SoC FIR11 trước đó;
//     không instance gì thêm, vùng 0x0001_0000-0x0001_FFFF không map.
//   ENABLE_EXT_RAM = 1: thêm slave thứ 4
//     axi_interconnect --(cpu_read/cpu_write/cpu_addr/cpu_wdata/cpu_rdata/
//       cpu_ready)--> cache_top #(USE_CACHE = EXT_RAM_USE_CACHE)
//       EXT_RAM_USE_CACHE = 0 : cấu hình B, bypass -> arbiter -> sdram_top
//       EXT_RAM_USE_CACHE = 1 : cấu hình C, cache_controller -> arbiter -> sdram_top
//     (chốt/giữ yêu cầu và tuần tự hóa đọc/ghi nằm trong axi_interconnect)
//     CPU thấy RAM ở 0x4001_0000-0x4001_FFFF (bus 0x0001_0000-0x0001_FFFF);
//     cpu_soc đã đưa mọi địa chỉ addr[31:30]==01 ra bus nên không sửa CPU.
//     Chỉ tăng dung lượng DỮ LIỆU; lệnh vẫn lấy từ IMEM 1 KB, DMEM 1 KB giữ
//     nguyên. sdram_top chứa mô hình thiết bị (sdram_model): B/C chỉ dùng
//     cho mô phỏng, không nối tới chip SDRAM thật.
//   Danh sách file: A = rtl/filelist_fir11.f;
//     B/C = rtl/filelist_fir11.f + rtl/filelist_ext_ram_sim.f.
//
// Regression XSim: CPU/FIR/IRQ/RAM B/C; xem docs/RTL_FIX_VERIFICATION.md.
//======================================================================

module soc_top #(
    parameter ENABLE_EXT_RAM    = 0,   // 0: config A (default), 1: add external data RAM
    parameter EXT_RAM_USE_CACHE = 0    // with ENABLE_EXT_RAM=1: 0 = config B (bypass), 1 = config C (cache)
) (
    input  wire clk,
    input  wire rst_n,

    output wire cpu_irq                // quan sát: yêu cầu ngắt tới CPU
);

    wire rst = ~rst_n;

    //------------------------------------------------------------
    // CPU <-> AXI master
    //------------------------------------------------------------
    wire        bus_rd;
    wire        bus_wr;
    wire [31:0] bus_addr;
    wire [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire        bus_ready;

    rvcore32_pipeline_soc u_cpu (
        .clk       (clk),
        .rst       (rst),
        .irq       (cpu_irq),
        .bus_rd    (bus_rd),
        .bus_wr    (bus_wr),
        .bus_addr  (bus_addr),
        .bus_wdata (bus_wdata),
        .bus_rdata (bus_rdata),
        .bus_ready (bus_ready)
    );

    //------------------------------------------------------------
    // AXI4-Lite master <-> interconnect
    //------------------------------------------------------------
    wire [31:0] axi_awaddr;
    wire        axi_awvalid;
    wire        axi_awready;
    wire [31:0] axi_wdata;
    wire [3:0]  axi_wstrb;
    wire        axi_wvalid;
    wire        axi_wready;
    wire [1:0]  axi_bresp;
    wire        axi_bvalid;
    wire        axi_bready;
    wire [31:0] axi_araddr;
    wire        axi_arvalid;
    wire        axi_arready;
    wire [31:0] axi_rdata;
    wire [1:0]  axi_rresp;
    wire        axi_rvalid;
    wire        axi_rready;

    cpu_axi_master u_axi_master (
        .clk           (clk),
        .rst_n         (rst_n),
        .mem_read      (bus_rd),
        .mem_write     (bus_wr),
        .mem_addr      (bus_addr),
        .mem_wdata     (bus_wdata),
        .mem_rdata     (bus_rdata),
        .mem_ready     (bus_ready),
        .M_AXI_AWADDR  (axi_awaddr),
        .M_AXI_AWVALID (axi_awvalid),
        .M_AXI_AWREADY (axi_awready),
        .M_AXI_WDATA   (axi_wdata),
        .M_AXI_WSTRB   (axi_wstrb),
        .M_AXI_WVALID  (axi_wvalid),
        .M_AXI_WREADY  (axi_wready),
        .M_AXI_BRESP   (axi_bresp),
        .M_AXI_BVALID  (axi_bvalid),
        .M_AXI_BREADY  (axi_bready),
        .M_AXI_ARADDR  (axi_araddr),
        .M_AXI_ARVALID (axi_arvalid),
        .M_AXI_ARREADY (axi_arready),
        .M_AXI_RDATA   (axi_rdata),
        .M_AXI_RRESP   (axi_rresp),
        .M_AXI_RVALID  (axi_rvalid),
        .M_AXI_RREADY  (axi_rready)
    );

    //------------------------------------------------------------
    // Interconnect <-> peripherals
    //------------------------------------------------------------
    wire [31:0] write_addr;
    wire [31:0] write_data;
    wire [31:0] read_addr;

    wire        timer_wr_en, timer_rd_en;
    wire [31:0] timer_rdata;
    wire        timer_irq;

    wire        interrupt_wr_en, interrupt_rd_en;
    wire [31:0] interrupt_rdata;

    wire        fir_wr_en, fir_rd_en;
    wire [31:0] fir_rdata;
    wire        fir_irq;

    // External data RAM: interconnect <-> cache_top cpu_*
    wire        ext_ram_read, ext_ram_write;
    wire [31:0] ext_ram_addr, ext_ram_wdata;
    wire [31:0] ext_ram_rdata;
    wire        ext_ram_ready;

    axi_interconnect #(
        .ENABLE_EXT_RAM (ENABLE_EXT_RAM)
    ) u_interconnect (
        .clk             (clk),
        .rst_n           (rst_n),
        // from AXI master
        .s_axi_awaddr    (axi_awaddr),
        .s_axi_awvalid   (axi_awvalid),
        .s_axi_awready   (axi_awready),
        .s_axi_wdata     (axi_wdata),
        .s_axi_wstrb     (axi_wstrb),
        .s_axi_wvalid    (axi_wvalid),
        .s_axi_wready    (axi_wready),
        .s_axi_bresp     (axi_bresp),
        .s_axi_bvalid    (axi_bvalid),
        .s_axi_bready    (axi_bready),
        .s_axi_araddr    (axi_araddr),
        .s_axi_arvalid   (axi_arvalid),
        .s_axi_arready   (axi_arready),
        .s_axi_rdata     (axi_rdata),
        .s_axi_rresp     (axi_rresp),
        .s_axi_rvalid    (axi_rvalid),
        .s_axi_rready    (axi_rready),
        // peripherals
        .timer_rdata     (timer_rdata),
        .interrupt_rdata (interrupt_rdata),
        .fir_rdata       (fir_rdata),
        .timer_wr_en     (timer_wr_en),
        .timer_rd_en     (timer_rd_en),
        .interrupt_wr_en (interrupt_wr_en),
        .interrupt_rd_en (interrupt_rd_en),
        .fir_wr_en       (fir_wr_en),
        .fir_rd_en       (fir_rd_en),
        .write_addr      (write_addr),
        .write_data      (write_data),
        .read_addr       (read_addr),
        // external data RAM
        .ext_ram_read    (ext_ram_read),
        .ext_ram_write   (ext_ram_write),
        .ext_ram_addr    (ext_ram_addr),
        .ext_ram_wdata   (ext_ram_wdata),
        .ext_ram_rdata   (ext_ram_rdata),
        .ext_ram_ready   (ext_ram_ready)
    );

    //------------------------------------------------------------
    // External data RAM (0x0001_0000, optional, simulation only)
    //------------------------------------------------------------
    generate
        if (ENABLE_EXT_RAM != 0) begin : g_ext_ram
            // cache_top: cache_controller (or bypass) -> cache_dma_arbiter
            // (DMA inputs tied 0) -> sdram_top (controller + sdram_model)
            cache_top #(
                .USE_CACHE (EXT_RAM_USE_CACHE)
            ) u_ext_mem (
                .clk       (clk),
                .rst       (rst),
                .cpu_read  (ext_ram_read),
                .cpu_write (ext_ram_write),
                .cpu_addr  (ext_ram_addr),
                .cpu_wdata (ext_ram_wdata),
                .cpu_rdata (ext_ram_rdata),
                .cpu_ready (ext_ram_ready)
            );
        end else begin : g_no_ext_ram
            // config A: decoder never selects EXT_RAM; tie the responses off
            assign ext_ram_rdata = 32'd0;
            assign ext_ram_ready = 1'b0;
        end
    endgenerate

    //------------------------------------------------------------
    // Timer (0x080): 1 register, write = compare & start, read = count
    //------------------------------------------------------------
    timer u_timer (
        .clk    (clk),
        .rst_n  (rst_n),
        .wr_en  (timer_wr_en),
        .rd_en  (timer_rd_en),
        .wdata  (write_data),
        .rdata  (timer_rdata),
        .irq    (timer_irq)
    );

    //------------------------------------------------------------
    // FIR11 HLS peripheral (0x200)
    //------------------------------------------------------------
    fir11_wrapper u_fir (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (fir_wr_en),
        .rd_en   (fir_rd_en),
        .wr_addr (write_addr),
        .rd_addr (read_addr),
        .wdata   (write_data),
        .rdata   (fir_rdata),
        .irq     (fir_irq)
    );

    //------------------------------------------------------------
    // Interrupt block (0x1C0): register wrapper + controller
    //------------------------------------------------------------
    wire [`NUM_INTERRUPTS-1:0] irq_in = {fir_irq, timer_irq};   // [IRQ_FIR, IRQ_TIMER]
    wire [`NUM_INTERRUPTS-1:0] irq_enable;
    wire [`NUM_INTERRUPTS-1:0] irq_pending;
    wire                       irq_ack;
    wire [`INT_ID_WIDTH-1:0]   irq_ack_id;
    wire [`INT_ID_WIDTH-1:0]   irq_id;

    interrupt_axi_wrapper u_int_regs (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (interrupt_wr_en),
        .rd_en        (interrupt_rd_en),
        .wr_addr      (write_addr),
        .rd_addr      (read_addr),
        .wdata        (write_data),
        .rdata        (interrupt_rdata),
        .irq_enable   (irq_enable),
        .ack          (irq_ack),
        .ack_id       (irq_ack_id),
        .pending      (irq_pending),
        .interrupt    (cpu_irq),
        .interrupt_id (irq_id)
    );

    interrupt_controller u_int_ctrl (
        .clk          (clk),
        .rst          (rst),
        .irq_in       (irq_in),
        .irq_enable   (irq_enable),
        .ack          (irq_ack),
        .ack_id       (irq_ack_id),
        .pending      (irq_pending),
        .interrupt    (cpu_irq),
        .interrupt_id (irq_id)
    );

endmodule
