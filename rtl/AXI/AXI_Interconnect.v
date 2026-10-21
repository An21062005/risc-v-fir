`timescale 1ns/1ps
//--------------------------------------------------------------------------
//                         axi_interconnect
//--------------------------------------------------------------------------
// Dựa trên AXI_Interconnect.v của tiny-riscv-soc (MIT). Thay đổi trong dự án
// riscv-soc-fir-hls:
//   - Tinh gọn: chỉ còn 3 slave đang dùng là TIMER (0x080), INTERRUPT (0x1C0)
//     và FIR (0x200, thêm mới). Bỏ RAM bus, GPIO, UART, SPI, I2C, DMA cùng
//     cổng ram_ready (SoC không có RAM trên bus, bản trước nối cứng ram_ready=1).
//   - Giữ cấu trúc của 3 FSM gốc (decoder, write FSM,
//     read FSM). Địa chỉ không thuộc slave nào: ghi bị bỏ qua, đọc ra 0,
//     BRESP/RRESP = DECERR (A1, 2026-10-21; bản gốc trả OKAY). Bus không treo.
//   - A2 (2026-10-21): RAM ngoài có thể không trả lời (backend treo). Write FSM
//     (WRITE_RESP) và read FSM (READ_WAIT) đếm chu kỳ chờ done; tới
//     EXT_RAM_TIMEOUT thì hạ yêu cầu và trả SLVERR (RDATA = 0). Arbiter đánh dấu
//     yêu cầu bị bỏ là "orphan": vẫn giữ mem_read/mem_write + địa chỉ/dữ liệu đã
//     chốt tới khi backend trả mem_ready rồi NUỐT completion đó (không báo done
//     cho giao dịch sau). Khi orphan còn treo, yêu cầu mới không được cấp và cũng
//     hết hạn -> mọi giao dịch đều kết thúc trong thời gian chặn trên.
// Giao thức với ngoại vi (regression: docs/RTL_FIX_VERIFICATION.md):
//   - Ghi: *_wr_en là xung 1 chu kỳ, write_addr/write_data hợp lệ đúng chu kỳ đó.
//   - Đọc: *_rd_en là xung 1 chu kỳ sau READ_DATA; ngoại vi chốt ở cạnh
//     READ_WAIT, interconnect lấy rdata ở cạnh READ_RESP kế tiếp.
//     Mỗi giao dịch chỉ gây một lần tác dụng phụ khi đọc.
//   - Ngoại vi nhiều thanh ghi chọn thanh ghi bằng addr[5:2].
// Mở rộng RAM dữ liệu ngoài (tham số ENABLE_EXT_RAM, mặc định 0):
//   - ENABLE_EXT_RAM = 0: decoder không bao giờ chọn EXT_RAM, mọi FSM chạy
//     y như trước (0x0001_0000-0x0001_FFFF là địa chỉ không map).
//   - ENABLE_EXT_RAM = 1: vùng EXT_RAM_BASE..EXT_RAM_END đi thẳng tới giao
//     diện cpu_* của cache_top (rtl/Memory/cache_controller.v) qua cổng
//     ext_ram_read/write/addr/wdata/rdata/ready. Phần chốt yêu cầu, giữ yêu
//     cầu tới completion và tuần tự hóa (trước đây ở ext_ram_slave) nằm ở:
//       axi_write_fsm : ở bắt tay W chốt offset (địa chỉ - EXT_RAM_BASE) và
//         WDATA, kiểm WSTRB/căn lề; bật ext_ram_wr_req (mức) tới
//         ext_ram_wr_done. WRITE_RESP chỉ bật BVALID khi có ext_ram_wr_done.
//       axi_read_fsm  : ở READ_DATA chốt offset, kiểm căn lề; bật
//         ext_ram_rd_req (mức) tới ext_ram_rd_done, chốt rdata đúng chu kỳ
//         done. READ_WAIT chờ done rồi mới sang READ_RESP.
//       axi_ext_ram_arbiter : một backend dùng chung -> mỗi lúc một yêu cầu,
//         ghi trước đọc sau; cpu_read/cpu_write giữ mức, hạ tổ hợp ngay trong
//         chu kỳ cpu_ready; done chỉ khi cpu_ready tới lúc đang phục vụ
//         đúng yêu cầu đó (ready rảnh không được tính).
//     Lựa chọn slave RAM được chốt lúc nhận AW/AR và giữ suốt giao dịch.
//     Giới hạn truy cập (CPU chỉ có lw/sw): chỉ word căn 4 byte, WSTRB =
//     1111. Ghi từng phần / lệch: không ghi gì, BRESP = SLVERR. Đọc lệch:
//     RDATA = 0, RRESP = SLVERR. Cả hai không tạo yêu cầu tới bộ nhớ.
//   - AW/AR chỉ được nhận khi IDLE; W chỉ được nhận sau AW. READY hạ
//     ngay sau cạnh nhận, không báo nhận thêm giao dịch khi FSM đang bận.
//   - MMIO Timer/Interrupt/FIR: chỉ word căn 4 byte. WSTRB=1111 ghi word,
//     WSTRB=0000 là no-op. Ghi từng phần hoặc truy cập lệch trả SLVERR,
//     không tạo wr_en/rd_en (không có tác dụng phụ).
//--------------------------------------------------------------------------

//--------------------------------------------------------------------------
//                     AXI Address Decoder
//--------------------------------------------------------------------------

`include "soc_pkg.vh"

module axi_address_decoder #(
    parameter ENABLE_EXT_RAM = 0
) (

    input  wire [`ADDR_WIDTH-1:0] addr,

    output reg                    timer_sel,
    output reg                    interrupt_sel,
    output reg                    fir_sel,
    output reg                    ext_ram_sel,

    output reg [3:0]              slave_id

);

    always @(*) begin

        timer_sel     = 1'b0;
        interrupt_sel = 1'b0;
        fir_sel       = 1'b0;
        ext_ram_sel   = 1'b0;
        slave_id      = `SEL_NONE;

        // TIMER
        if ((addr >= `TIMER_BASE) &&
            (addr <= `TIMER_END)) begin
            timer_sel = 1'b1;
            slave_id  = `SEL_TIMER;
        end

        // Interrupt Controller
        else if ((addr >= `INTERRUPT_BASE) &&
                 (addr <= `INTERRUPT_END)) begin
            interrupt_sel = 1'b1;
            slave_id      = `SEL_INTERRUPT;
        end

        // FIR Filter Accelerator
        else if ((addr >= `FIR_BASE) &&
                 (addr <= `FIR_END)) begin
            fir_sel  = 1'b1;
            slave_id = `SEL_FIR;
        end

        // External data RAM (only when enabled)
        else if ((ENABLE_EXT_RAM != 0) &&
                 (addr >= `EXT_RAM_BASE) &&
                 (addr <= `EXT_RAM_END)) begin
            ext_ram_sel = 1'b1;
            slave_id    = `SEL_EXT_RAM;
        end

    end

endmodule

//--------------------------------------------------------------------------
//                     AXI Write FSM
//--------------------------------------------------------------------------

`include "soc_pkg.vh"

module axi_write_fsm #(
    parameter EXT_RAM_TIMEOUT = 1024     // A2: chu kỳ chờ ext_ram_wr_done tối đa
) (

    input wire clk,
    input wire rst_n,

    // Master Side (CPU AXI Master)
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    output reg [1:0]   s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    // Slave Select (decoded from s_axi_awaddr)
    input wire         timer_sel,
    input wire         interrupt_sel,
    input wire         fir_sel,
    input wire         ext_ram_sel,

    // Peripheral Control
    output reg         timer_wr_en,
    output reg         interrupt_wr_en,
    output reg         fir_wr_en,
    output reg [31:0]  write_addr,
    output reg [31:0]  write_data,

    // External RAM: request held from the W handshake until ext_ram_wr_done
    output reg         ext_ram_wr_req,
    output reg [31:0]  ext_ram_wr_addr,     // offset in the RAM window
    output reg [31:0]  ext_ram_wr_data,
    input  wire        ext_ram_wr_done

);

    localparam IDLE       = 2'b00;
    localparam WRITE_DATA = 2'b01;
    localparam WRITE_RESP = 2'b10;

    reg [1:0] state;
    reg [1:0] next_state;

    // READY reflects actual receive capacity, including the cycle directly
    // after a handshake. Registered IDLE outputs used to acknowledge and lose
    // a second AW/W while the state had already advanced.
    always @(*) begin
        s_axi_awready = rst_n && (state == IDLE);
        s_axi_wready  = rst_n && (state == WRITE_DATA);
    end

    reg [31:0] saved_awaddr;
    reg        saved_timer_sel;
    reg        saved_interrupt_sel;
    reg        saved_fir_sel;
    reg        saved_ext_ram_sel;
    reg        ext_ram_wr_err;      // rejected RAM write (no memory request)
    reg        mmio_wr_err;
    reg [15:0] wr_wait;             // A2: cycles waiting for ext_ram_wr_done

    wire saved_none = !(saved_timer_sel || saved_interrupt_sel || saved_fir_sel || saved_ext_ram_sel);
    wire wr_timeout = ext_ram_wr_req && !ext_ram_wr_done && (wr_wait == EXT_RAM_TIMEOUT - 1);

    wire mmio_wr_bad = (saved_awaddr[1:0] != 2'b00) ||
                       ((s_axi_wstrb != 4'b1111) && (s_axi_wstrb != 4'b0000));

    // RAM write check: word-aligned, full WSTRB, inside the window
    wire ext_ram_wr_bad = (saved_awaddr < `EXT_RAM_BASE) || (saved_awaddr > `EXT_RAM_END) ||
                          (saved_awaddr[1:0] != 2'b00) || (s_axi_wstrb != 4'b1111);

    // State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // Next-State Logic
    always @(*) begin
        next_state = state;
        case (state)
            IDLE:
                if (s_axi_awvalid && s_axi_awready)
                    next_state = WRITE_DATA;
            WRITE_DATA:
                if (s_axi_wvalid && s_axi_wready)
                    next_state = WRITE_RESP;
            WRITE_RESP:
                if (s_axi_bvalid && s_axi_bready)
                    next_state = IDLE;
            default:
                next_state = IDLE;
        endcase
    end

    // Output Logic
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            s_axi_bvalid        <= 1'b0;
            s_axi_bresp         <= `AXI_RESP_OKAY;
            timer_wr_en         <= 1'b0;
            interrupt_wr_en     <= 1'b0;
            fir_wr_en           <= 1'b0;
            write_addr          <= 32'd0;
            write_data          <= 32'd0;
            saved_awaddr        <= 32'd0;
            saved_timer_sel     <= 1'b0;
            saved_interrupt_sel <= 1'b0;
            saved_fir_sel       <= 1'b0;
            saved_ext_ram_sel   <= 1'b0;
            ext_ram_wr_err      <= 1'b0;
            mmio_wr_err         <= 1'b0;
            ext_ram_wr_req      <= 1'b0;
            ext_ram_wr_addr     <= 32'd0;
            ext_ram_wr_data     <= 32'd0;
            wr_wait             <= 16'd0;
        end

        else begin

            // Default: write enables are one-cycle pulses
            timer_wr_en     <= 1'b0;
            interrupt_wr_en <= 1'b0;
            fir_wr_en       <= 1'b0;

            case (state)

                IDLE: begin
                    s_axi_bvalid  <= 1'b0;
                    mmio_wr_err   <= 1'b0;
                    if (s_axi_awvalid && s_axi_awready) begin
                        saved_awaddr        <= s_axi_awaddr;
                        saved_timer_sel     <= timer_sel;
                        saved_interrupt_sel <= interrupt_sel;
                        saved_fir_sel       <= fir_sel;
                        saved_ext_ram_sel   <= ext_ram_sel;
                    end
                end

                WRITE_DATA: begin
                    wr_wait <= 16'd0;
                    if (s_axi_wvalid && s_axi_wready) begin
                        write_addr <= saved_awaddr;
                        write_data <= s_axi_wdata;
                        if (saved_timer_sel || saved_interrupt_sel || saved_fir_sel) begin
                            mmio_wr_err <= mmio_wr_bad;
                            if (!mmio_wr_bad && (s_axi_wstrb == 4'b1111)) begin
                                timer_wr_en     <= saved_timer_sel;
                                interrupt_wr_en <= saved_interrupt_sel;
                                fir_wr_en       <= saved_fir_sel;
                            end
                        end
                        else if (saved_ext_ram_sel) begin
                            if (ext_ram_wr_bad) begin
                                ext_ram_wr_err  <= 1'b1;    // nothing is written
                            end else begin
                                // exactly one request per AXI write, latched
                                // and held stable until ext_ram_wr_done
                                ext_ram_wr_err  <= 1'b0;
                                ext_ram_wr_req  <= 1'b1;
                                ext_ram_wr_addr <= saved_awaddr - `EXT_RAM_BASE;
                                ext_ram_wr_data <= s_axi_wdata;
                            end
                        end
                        // no slave selected: write is dropped, response DECERR
                    end
                end

                WRITE_RESP: begin
                    if (!s_axi_bvalid) begin
                        if (saved_none) begin
                            // unmapped address: nothing written
                            s_axi_bvalid <= 1'b1;
                            s_axi_bresp  <= `AXI_RESP_DECERR;
                        end
                        else if (!saved_ext_ram_sel) begin
                            // register peripherals are always-ready
                            s_axi_bvalid <= 1'b1;
                            s_axi_bresp  <= mmio_wr_err ? `AXI_RESP_SLVERR : `AXI_RESP_OKAY;
                        end
                        else if (ext_ram_wr_err) begin
                            // rejected (partial / unaligned): no memory access
                            s_axi_bvalid <= 1'b1;
                            s_axi_bresp  <= `AXI_RESP_SLVERR;
                        end
                        else if (ext_ram_wr_done) begin
                            // RAM: respond only after this write really completed
                            ext_ram_wr_req <= 1'b0;
                            s_axi_bvalid   <= 1'b1;
                            s_axi_bresp    <= `AXI_RESP_OKAY;
                        end
                        else if (wr_timeout) begin
                            // A2: backend did not answer -> give up, SLVERR
                            ext_ram_wr_req <= 1'b0;
                            s_axi_bvalid   <= 1'b1;
                            s_axi_bresp    <= `AXI_RESP_SLVERR;
                        end
                        else if (ext_ram_wr_req)
                            wr_wait <= wr_wait + 16'd1;
                    end
                    else if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                    end
                end

                default: ;

            endcase

        end

    end

endmodule

//--------------------------------------------------------------------------
//                     AXI Read FSM
//--------------------------------------------------------------------------

`include "soc_pkg.vh"

module axi_read_fsm #(
    parameter EXT_RAM_TIMEOUT = 1024     // A2: chu kỳ chờ ext_ram_rd_done tối đa
) (

    input wire clk,
    input wire rst_n,

    // AXI Read Address Channel
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    // AXI Read Data Channel
    output reg [31:0]  s_axi_rdata,
    output reg [1:0]   s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // Slave Selects (decoded from s_axi_araddr)
    input wire         timer_sel,
    input wire         interrupt_sel,
    input wire         fir_sel,
    input wire         ext_ram_sel,

    // Peripheral Read Data
    input wire [31:0]  timer_rdata,
    input wire [31:0]  interrupt_rdata,
    input wire [31:0]  fir_rdata,

    // Peripheral Read Enables
    output reg         timer_rd_en,
    output reg         interrupt_rd_en,
    output reg         fir_rd_en,

    output reg [31:0]  read_addr,

    // External RAM: request held from READ_DATA until ext_ram_rd_done;
    // ext_ram_rdata is only sampled in the ext_ram_rd_done cycle
    output reg         ext_ram_rd_req,
    output reg [31:0]  ext_ram_rd_addr,     // offset in the RAM window
    input  wire [31:0] ext_ram_rdata,
    input  wire        ext_ram_rd_done

);

    localparam IDLE      = 2'b00;
    localparam READ_DATA = 2'b01;
    localparam READ_WAIT = 2'b10;
    localparam READ_RESP = 2'b11;

    reg [1:0] state;
    reg [1:0] next_state;

    reg [31:0] saved_araddr;
    reg        saved_timer_sel;
    reg        saved_interrupt_sel;
    reg        saved_fir_sel;
    reg        saved_ext_ram_sel;   // latched with the AR handshake
    reg        ext_ram_rd_err;      // rejected RAM read (no memory request)
    reg [31:0] ext_ram_rdata_q;     // RAM data captured at ext_ram_rd_done
    reg [15:0] rd_wait;             // A2: cycles waiting for ext_ram_rd_done
    reg        ext_ram_rd_tmo;      // A2: this read timed out

    wire saved_none = !(saved_timer_sel || saved_interrupt_sel || saved_fir_sel || saved_ext_ram_sel);
    wire rd_timeout = ext_ram_rd_req && !ext_ram_rd_done && (rd_wait == EXT_RAM_TIMEOUT - 1);

    wire mmio_rd_bad = (saved_timer_sel || saved_interrupt_sel || saved_fir_sel) &&
                       (saved_araddr[1:0] != 2'b00);

    always @(*) begin
        s_axi_arready = rst_n && (state == IDLE);
    end

    // RAM read check: word-aligned, inside the window
    wire ext_ram_rd_bad = (saved_araddr < `EXT_RAM_BASE) || (saved_araddr > `EXT_RAM_END) ||
                          (saved_araddr[1:0] != 2'b00);

    // State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // Next-State Logic
    always @(*) begin
        next_state = state;
        case (state)
            IDLE:
                if (s_axi_arvalid && s_axi_arready)
                    next_state = READ_DATA;
            READ_DATA:
                next_state = READ_WAIT;
            READ_WAIT:
                // RAM: stay until its own completion for this request
                if (!saved_ext_ram_sel || ext_ram_rd_err || ext_ram_rd_done || rd_timeout)
                    next_state = READ_RESP;
            READ_RESP:
                if (s_axi_rvalid && s_axi_rready)
                    next_state = IDLE;
            default:
                next_state = IDLE;
        endcase
    end

    // Output / FSM Logic
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            s_axi_rdata     <= 32'd0;
            s_axi_rresp     <= `AXI_RESP_OKAY;
            s_axi_rvalid    <= 1'b0;
            timer_rd_en     <= 1'b0;
            interrupt_rd_en <= 1'b0;
            fir_rd_en       <= 1'b0;
            read_addr       <= 32'd0;
            saved_araddr    <= 32'd0;
            saved_timer_sel <= 1'b0;
            saved_interrupt_sel <= 1'b0;
            saved_fir_sel <= 1'b0;
            saved_ext_ram_sel <= 1'b0;
            ext_ram_rd_err  <= 1'b0;
            ext_ram_rd_req  <= 1'b0;
            ext_ram_rd_addr <= 32'd0;
            ext_ram_rdata_q <= 32'd0;
            rd_wait         <= 16'd0;
            ext_ram_rd_tmo  <= 1'b0;
        end

        else begin

            // Exactly one peripheral read/snapshot/side effect per AXI AR.
            timer_rd_en     <= 1'b0;
            interrupt_rd_en <= 1'b0;
            fir_rd_en       <= 1'b0;

            case (state)

                IDLE: begin
                    s_axi_rvalid  <= 1'b0;
                    if (s_axi_arvalid && s_axi_arready) begin
                        saved_araddr      <= s_axi_araddr;
                        saved_timer_sel   <= timer_sel;
                        saved_interrupt_sel <= interrupt_sel;
                        saved_fir_sel     <= fir_sel;
                        saved_ext_ram_sel <= ext_ram_sel;
                    end
                end

                READ_DATA: begin
                    read_addr      <= saved_araddr;
                    rd_wait        <= 16'd0;
                    ext_ram_rd_tmo <= 1'b0;
                    if (saved_timer_sel && !mmio_rd_bad)
                        timer_rd_en <= 1'b1;
                    else if (saved_interrupt_sel && !mmio_rd_bad)
                        interrupt_rd_en <= 1'b1;
                    else if (saved_fir_sel && !mmio_rd_bad)
                        fir_rd_en <= 1'b1;
                    else if (saved_ext_ram_sel) begin
                        if (ext_ram_rd_bad) begin
                            ext_ram_rd_err  <= 1'b1;        // nothing is read
                        end else begin
                            // exactly one request per AXI read, latched and
                            // held stable until ext_ram_rd_done
                            ext_ram_rd_err  <= 1'b0;
                            ext_ram_rd_req  <= 1'b1;
                            ext_ram_rd_addr <= saved_araddr - `EXT_RAM_BASE;
                        end
                    end
                end

                READ_WAIT: begin
                    // Peripheral consumes the single rd_en pulse at this edge.
                    // RAM: no second request; next-state logic waits for done.
                    if (ext_ram_rd_done) begin
                        ext_ram_rd_req  <= 1'b0;
                        ext_ram_rdata_q <= ext_ram_rdata;   // valid only this cycle (cache mode)
                    end
                    else if (rd_timeout) begin
                        // A2: backend did not answer -> give up, SLVERR, RDATA 0
                        ext_ram_rd_req  <= 1'b0;
                        ext_ram_rd_tmo  <= 1'b1;
                    end
                    else if (ext_ram_rd_req)
                        rd_wait <= rd_wait + 16'd1;
                end

                READ_RESP: begin
                    if (!s_axi_rvalid) begin
                        if (mmio_rd_bad)
                            s_axi_rdata <= 32'd0;
                        else if (saved_timer_sel)
                            s_axi_rdata <= timer_rdata;
                        else if (saved_interrupt_sel)
                            s_axi_rdata <= interrupt_rdata;
                        else if (saved_fir_sel)
                            s_axi_rdata <= fir_rdata;
                        else if (saved_ext_ram_sel)
                            s_axi_rdata <= (ext_ram_rd_err || ext_ram_rd_tmo) ? 32'd0 : ext_ram_rdata_q;
                        else
                            s_axi_rdata <= 32'd0;     // unmapped address reads 0
                        s_axi_rvalid <= 1'b1;
                        s_axi_rresp  <= saved_none ? `AXI_RESP_DECERR :
                                        (mmio_rd_bad || (saved_ext_ram_sel && (ext_ram_rd_err || ext_ram_rd_tmo)))
                                            ? `AXI_RESP_SLVERR : `AXI_RESP_OKAY;
                    end
                    else if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                    end
                end

            endcase

        end

    end

endmodule

//--------------------------------------------------------------------------
//                     External RAM request arbiter
//--------------------------------------------------------------------------
// riscv-soc-fir-hls: serialises the held requests of axi_write_fsm and
// axi_read_fsm onto the single cpu_* port of cache_top (one request at a
// time, write before read if both are waiting; none is lost because each
// FSM keeps its request until its own done).
//   mem_read/mem_write : held while the granted request is in flight and
//     dropped combinationally in the mem_ready cycle, so the backend's idle
//     state (CACHE_IDLE / SDRAM_IDLE) never sees it as a new request.
//   wr_done / rd_done  : = mem_ready while that request is granted. An idle
//     or stale mem_ready (nothing granted) is never reported as completion.
//   The requesting FSM clears its *_req on the same edge as active returns
//   to ARB_NONE, so the request is not granted twice.
//   A2: address/data are latched at grant (a later request cannot change them
//   under an in-flight backend operation). If the FSM drops its request before
//   mem_ready (timeout), the grant becomes an orphan: the backend request stays
//   held until mem_ready, which is then swallowed (no wr_done/rd_done).
//--------------------------------------------------------------------------

module axi_ext_ram_arbiter (

    input wire clk,
    input wire rst_n,

    // from axi_write_fsm
    input  wire        wr_req,
    input  wire [31:0] wr_addr,
    input  wire [31:0] wr_data,
    output wire        wr_done,

    // from axi_read_fsm
    input  wire        rd_req,
    input  wire [31:0] rd_addr,
    output wire        rd_done,

    // to cache_top cpu_* interface
    output wire        mem_read,
    output wire        mem_write,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    input  wire        mem_ready

);

    localparam [1:0] ARB_NONE = 2'd0;
    localparam [1:0] ARB_WR   = 2'd1;
    localparam [1:0] ARB_RD   = 2'd2;

    reg [1:0]  active;
    reg        orphan;              // A2: requester gave up (timeout)
    reg [31:0] addr_q, wdata_q;     // A2: latched at grant

    wire       cur_req = (active == ARB_WR) ? wr_req : (active == ARB_RD) ? rd_req : 1'b0;

    assign mem_write = (active == ARB_WR) && !mem_ready;
    assign mem_read  = (active == ARB_RD) && !mem_ready;
    assign mem_addr  = addr_q;
    assign mem_wdata = wdata_q;

    assign wr_done   = (active == ARB_WR) && mem_ready && wr_req && !orphan;
    assign rd_done   = (active == ARB_RD) && mem_ready && rd_req && !orphan;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active  <= ARB_NONE;
            orphan  <= 1'b0;
            addr_q  <= 32'd0;
            wdata_q <= 32'd0;
        end else begin
            case (active)
                ARB_NONE: begin
                    orphan <= 1'b0;
                    if (wr_req) begin
                        active  <= ARB_WR;
                        addr_q  <= wr_addr;
                        wdata_q <= wr_data;
                    end
                    else if (rd_req) begin
                        active  <= ARB_RD;
                        addr_q  <= rd_addr;
                    end
                end
                ARB_WR,
                ARB_RD:
                    if (mem_ready) begin
                        active <= ARB_NONE;
                        orphan <= 1'b0;
                    end
                    else if (!cur_req)
                        orphan <= 1'b1;
                default:
                    active <= ARB_NONE;
            endcase
        end
    end

endmodule

//--------------------------------------------------------------------------
//                     AXI Interconnect (top)
//--------------------------------------------------------------------------

`include "soc_pkg.vh"

module axi_interconnect #(
    parameter ENABLE_EXT_RAM  = 0,
    parameter EXT_RAM_TIMEOUT = 1024     // A2: max cycles waiting for the external RAM
) (

    input wire clk,
    input wire rst_n,

    // AXI Master Interface (from cpu_axi_master)
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // Peripheral Interface
    input  wire [31:0] timer_rdata,
    input  wire [31:0] interrupt_rdata,
    input  wire [31:0] fir_rdata,

    output wire        timer_wr_en,
    output wire        timer_rd_en,
    output wire        interrupt_wr_en,
    output wire        interrupt_rd_en,
    output wire        fir_wr_en,
    output wire        fir_rd_en,

    output wire [31:0] write_addr,
    output wire [31:0] write_data,
    output wire [31:0] read_addr,

    // External data RAM -> cache_top cpu_* (tie ext_ram_rdata/ext_ram_ready
    // to 0 when ENABLE_EXT_RAM = 0). ext_ram_addr = bus address - EXT_RAM_BASE.
    output wire        ext_ram_read,
    output wire        ext_ram_write,
    output wire [31:0] ext_ram_addr,
    output wire [31:0] ext_ram_wdata,
    input  wire [31:0] ext_ram_rdata,
    input  wire        ext_ram_ready

);

    // Held RAM requests (FSMs) <-> arbiter
    wire        ext_ram_wr_req, ext_ram_rd_req;
    wire [31:0] ext_ram_wr_addr, ext_ram_wr_data, ext_ram_rd_addr;
    wire        ext_ram_wr_done, ext_ram_rd_done;

    // Write / Read decoder outputs
    wire timer_wr_sel, interrupt_wr_sel, fir_wr_sel, ext_ram_wr_sel;
    wire timer_rd_sel, interrupt_rd_sel, fir_rd_sel, ext_ram_rd_sel;

    axi_address_decoder #(
        .ENABLE_EXT_RAM (ENABLE_EXT_RAM)
    ) WRITE_DECODER (
        .addr          (s_axi_awaddr),
        .timer_sel     (timer_wr_sel),
        .interrupt_sel (interrupt_wr_sel),
        .fir_sel       (fir_wr_sel),
        .ext_ram_sel   (ext_ram_wr_sel),
        .slave_id      ()                 // not used
    );

    axi_address_decoder #(
        .ENABLE_EXT_RAM (ENABLE_EXT_RAM)
    ) READ_DECODER (
        .addr          (s_axi_araddr),
        .timer_sel     (timer_rd_sel),
        .interrupt_sel (interrupt_rd_sel),
        .fir_sel       (fir_rd_sel),
        .ext_ram_sel   (ext_ram_rd_sel),
        .slave_id      ()                 // not used
    );

    axi_write_fsm #(
        .EXT_RAM_TIMEOUT (EXT_RAM_TIMEOUT)
    ) WRITE_FSM (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axi_awaddr    (s_axi_awaddr),
        .s_axi_awvalid   (s_axi_awvalid),
        .s_axi_awready   (s_axi_awready),
        .s_axi_wdata     (s_axi_wdata),
        .s_axi_wstrb     (s_axi_wstrb),
        .s_axi_wvalid    (s_axi_wvalid),
        .s_axi_wready    (s_axi_wready),
        .s_axi_bresp     (s_axi_bresp),
        .s_axi_bvalid    (s_axi_bvalid),
        .s_axi_bready    (s_axi_bready),
        .timer_sel       (timer_wr_sel),
        .interrupt_sel   (interrupt_wr_sel),
        .fir_sel         (fir_wr_sel),
        .ext_ram_sel     (ext_ram_wr_sel),
        .timer_wr_en     (timer_wr_en),
        .interrupt_wr_en (interrupt_wr_en),
        .fir_wr_en       (fir_wr_en),
        .write_addr      (write_addr),
        .write_data      (write_data),
        .ext_ram_wr_req  (ext_ram_wr_req),
        .ext_ram_wr_addr (ext_ram_wr_addr),
        .ext_ram_wr_data (ext_ram_wr_data),
        .ext_ram_wr_done (ext_ram_wr_done)
    );

    axi_read_fsm #(
        .EXT_RAM_TIMEOUT (EXT_RAM_TIMEOUT)
    ) READ_FSM (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axi_araddr    (s_axi_araddr),
        .s_axi_arvalid   (s_axi_arvalid),
        .s_axi_arready   (s_axi_arready),
        .s_axi_rdata     (s_axi_rdata),
        .s_axi_rresp     (s_axi_rresp),
        .s_axi_rvalid    (s_axi_rvalid),
        .s_axi_rready    (s_axi_rready),
        .timer_sel       (timer_rd_sel),
        .interrupt_sel   (interrupt_rd_sel),
        .fir_sel         (fir_rd_sel),
        .ext_ram_sel     (ext_ram_rd_sel),
        .timer_rdata     (timer_rdata),
        .interrupt_rdata (interrupt_rdata),
        .fir_rdata       (fir_rdata),
        .timer_rd_en     (timer_rd_en),
        .interrupt_rd_en (interrupt_rd_en),
        .fir_rd_en       (fir_rd_en),
        .read_addr       (read_addr),
        .ext_ram_rd_req  (ext_ram_rd_req),
        .ext_ram_rd_addr (ext_ram_rd_addr),
        .ext_ram_rdata   (ext_ram_rdata),
        .ext_ram_rd_done (ext_ram_rd_done)
    );

    axi_ext_ram_arbiter EXT_RAM_ARB (
        .clk       (clk),
        .rst_n     (rst_n),
        .wr_req    (ext_ram_wr_req),
        .wr_addr   (ext_ram_wr_addr),
        .wr_data   (ext_ram_wr_data),
        .wr_done   (ext_ram_wr_done),
        .rd_req    (ext_ram_rd_req),
        .rd_addr   (ext_ram_rd_addr),
        .rd_done   (ext_ram_rd_done),
        .mem_read  (ext_ram_read),
        .mem_write (ext_ram_write),
        .mem_addr  (ext_ram_addr),
        .mem_wdata (ext_ram_wdata),
        .mem_ready (ext_ram_ready)
    );

endmodule
