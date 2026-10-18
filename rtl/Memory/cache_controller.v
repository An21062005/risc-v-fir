`timescale 1ns/1ps

//======================================================================
// Bản sao có sửa từ tiny-riscv-soc/rtl/Memory/cache_controller.v
// (MIT, (c) 2026 Leela Shanmukh Yagneek Patnala, xem tiny-riscv-soc/LICENCE).
// Bản gốc không bị sửa.
//
// Giữ cấu trúc module của bản gốc (cùng thứ tự):
//   cache_tag_ram, cache_data_ram, main_memory, cache_controller,
//   cache_dma_arbiter, cache_top
// cache_top là top của bộ nhớ dữ liệu ngoài; axi_interconnect nối thẳng vào
// giao diện cpu_* của nó.
//
// Chính sách cache (đọc từ mã, chưa mô phỏng):
//   - Direct-mapped (1 way), 64 line x 16 byte = 1 KB, chỉ dữ liệu
//     (không có I-cache). tag = addr[31:10], index = addr[9:4],
//     word = addr[3:2].
//   - Đọc: hit trả từ line; miss -> refill 4 word bằng 4 yêu cầu đọc word
//     riêng lẻ tới backend (không burst), rồi ghi tag/line.
//   - Ghi: write-through. Hit: cập nhật line + ghi backend, chờ mem_ready.
//     Miss: write-no-allocate, chỉ ghi backend, chờ mem_ready.
//   - Không có dirty bit, không write-back, không byte-enable (chỉ word).
//   - Giao thức phía CPU: cpu_read/cpu_write lấy mẫu ở CACHE_IDLE; phải hạ
//     trước chu kỳ CACHE_IDLE kế tiếp sau cpu_ready, nếu không bị nhận lại.
//     cpu_rdata chỉ hợp lệ trong chu kỳ cpu_ready (tổ hợp ở CACHE_COMPLETE).
//     Phía bộ nhớ: mem_read/mem_write giữ mức tới mem_ready, hạ tổ hợp
//     ngay trong chu kỳ mem_ready (đã có sẵn trong bản gốc).
//
// Thay đổi so với bản gốc:
//   1. cache_tag_ram: valid bit là vector flop có reset (rst mức cao) ->
//      toàn bộ 64 line invalid ngay khi reset, trong 1 chu kỳ, không bao
//      giờ đọc hit khi valid còn X. Thêm cổng rst. tag_memory không reset
//      (chỉ có nghĩa khi valid = 1).
//   2. cache_top: backend main_memory được THAY bằng sdram_top (rtl/Memory/
//      sdram.v); main_memory giữ lại làm tham chiếu, không instance. Thêm
//      tham số USE_CACHE (generate: 1 = cache_controller, 0 = bypass nối
//      thẳng) và MODEL_DEPTH; bỏ các cổng DMA (SoC không có DMA), đầu vào
//      dma_* của cache_dma_arbiter buộc 0.
//   3. Bỏ `timescale lặp giữa các module (`include có guard); đổi CRLF -> LF.
//   Logic FSM của cache_controller, main_memory và cache_dma_arbiter giữ
//   nguyên.
//======================================================================

`include "cache_pkg.vh"

module cache_tag_ram (

    input  wire                     clk,
    input  wire                     rst,        // riscv-soc-fir-hls: invalidate all
    input  wire                     we,

    input  wire [`INDEX_BITS-1:0]   index,

    input  wire [`TAG_BITS-1:0]     tag_in,
    input  wire                     valid_in,

    output wire [`TAG_BITS-1:0]     tag_out,
    output wire                     valid_out

);

    //------------------------------------------------------------
    // Tag RAM
    //------------------------------------------------------------

    reg [`TAG_BITS-1:0] tag_memory [0:`CACHE_LINES-1];

    //------------------------------------------------------------
    // Valid Bit RAM
    //------------------------------------------------------------

    // riscv-soc-fir-hls: flop vector with reset instead of an
    // uninitialised array (original never cleared valid bits).
    reg [`CACHE_LINES-1:0] valid_memory;

    //------------------------------------------------------------
    // Write
    //------------------------------------------------------------

    always @(posedge clk) begin

        if (we)
            tag_memory[index] <= tag_in;

    end

    always @(posedge clk or posedge rst) begin

        if (rst)
            valid_memory <= {`CACHE_LINES{1'b0}};
        else if (we)
            valid_memory[index] <= valid_in;

    end

    //------------------------------------------------------------
    // Read
    //------------------------------------------------------------

    assign tag_out   = tag_memory[index];

    assign valid_out = valid_memory[index];

endmodule

//...................................................................................

module cache_data_ram (

    input  wire                      clk,
    input  wire                      we,

    input  wire [`INDEX_BITS-1:0]    index,

    input  wire [127:0]              line_in,

    output wire [127:0]              line_out

);

    //------------------------------------------------------------
    // Data RAM
    //------------------------------------------------------------

    reg [127:0] data_memory [0:`CACHE_LINES-1];

    //------------------------------------------------------------
    // Write Cache Line
    //------------------------------------------------------------

    always @(posedge clk) begin

        if (we)

            data_memory[index] <= line_in;

    end

    //------------------------------------------------------------
    // Read Cache Line
    //------------------------------------------------------------

    assign line_out = data_memory[index];

endmodule

//...................................................................................
// main_memory: giữ nguyên bản gốc, CHỈ LÀM THAM CHIẾU - không được instance
// trong dự án này (cache_top dùng sdram_top làm backend). Giới hạn của bản
// gốc: 1024 word = 4 KB, chỉ dùng addr[11:2] nên địa chỉ >= 4 KB bị alias;
// độ trễ cố định. Không nối song song với sdram_top.
//...................................................................................

module main_memory (

    //------------------------------------------------------------
    // Clock / Reset
    //------------------------------------------------------------

    input  wire         clk,
    input  wire         rst,

    //------------------------------------------------------------
    // Cache Interface
    //------------------------------------------------------------

    input  wire         mem_read,
    input  wire         mem_write,

    input  wire [31:0]  mem_addr,
    input  wire [31:0]  mem_wdata,

    output reg  [31:0]  mem_rdata,
    output reg          mem_ready

);

    //------------------------------------------------------------
    // Main Memory
    //------------------------------------------------------------

    reg [31:0] memory [0:1023];

    //------------------------------------------------------------
    // Internal Registers
    //------------------------------------------------------------

    // Word address derived from byte address
    wire [9:0] word_addr;

    // Simulated memory latency
    reg [2:0] wait_counter;

    // Memory busy flag
    reg busy;

    //------------------------------------------------------------
    // Latched Request
    //------------------------------------------------------------

    reg        read_pending;
    reg        write_pending;

    reg [31:0] addr_pending;
    reg [31:0] wdata_pending;

    //------------------------------------------------------------
    // Address Decode
    //------------------------------------------------------------

    assign word_addr = mem_addr[11:2];

    //------------------------------------------------------------
    // Memory Initialization
    //------------------------------------------------------------

    integer i;

    initial begin

        //--------------------------------------------------------
        // Clear Memory
        //--------------------------------------------------------

        for (i = 0; i < 1024; i = i + 1)
            memory[i] = 32'h00000000;

        //--------------------------------------------------------
        // Sample Data
        //--------------------------------------------------------

        memory[0] = 32'h11111111;
        memory[1] = 32'h22222222;
        memory[2] = 32'h33333333;
        memory[3] = 32'h44444444;

        memory[4] = 32'hAAAAAAAA;
        memory[5] = 32'hBBBBBBBB;
        memory[6] = 32'hCCCCCCCC;
        memory[7] = 32'hDDDDDDDD;

    end

    //------------------------------------------------------------
    // Main Memory Control
    //------------------------------------------------------------

    always @(posedge clk or posedge rst) begin

        //--------------------------------------------------------
        // Reset
        //--------------------------------------------------------

        if (rst) begin

            mem_ready    <= 1'b0;
            mem_rdata    <= 32'd0;

            busy         <= 1'b0;
            wait_counter <= 3'd0;

            read_pending  <= 1'b0;
            write_pending <= 1'b0;

            addr_pending  <= 32'd0;
            wdata_pending <= 32'd0;

        end

        //--------------------------------------------------------
        // Normal Operation
        //--------------------------------------------------------

        else begin

            //----------------------------------------------------
            // Default
            //----------------------------------------------------

            mem_ready <= 1'b0;

            //----------------------------------------------------
            // Start New Transaction
            //----------------------------------------------------

            if (!busy && (mem_read || mem_write)) begin

                busy         <= 1'b1;
                wait_counter <= 3'd2;

                read_pending  <= mem_read;
                write_pending <= mem_write;

                addr_pending  <= mem_addr;
                wdata_pending <= mem_wdata;

            end

            //----------------------------------------------------
            // Memory Busy
            //----------------------------------------------------

            else if (busy) begin

                if (wait_counter != 3'd0) begin

                    wait_counter <= wait_counter - 1'b1;

                end

                else begin

                    busy <= 1'b0;

                    mem_ready <= 1'b1;

                    //------------------------------------------------
                    // Write
                    //------------------------------------------------

                    if (write_pending)
                        memory[addr_pending[11:2]] <= wdata_pending;

                    //------------------------------------------------
                    // Read
                    //------------------------------------------------

                    if (read_pending)
                        mem_rdata <= memory[addr_pending[11:2]];

                    //------------------------------------------------
                    // Clear Pending Request
                    //------------------------------------------------

                    read_pending  <= 1'b0;
                    write_pending <= 1'b0;

                end

            end

        end

    end

endmodule

`include "cache_pkg.vh"

module cache_controller(

    //------------------------------------------------------------
    // Clock / Reset
    //------------------------------------------------------------

    input  wire                     clk,
    input  wire                     rst,

    //------------------------------------------------------------
    // CPU Interface
    //------------------------------------------------------------

    input  wire                     cpu_read,
    input  wire                     cpu_write,
    input  wire [31:0]              cpu_addr,
    input  wire [31:0]              cpu_wdata,

    output reg  [31:0]              cpu_rdata,
    output reg                      cpu_ready,

    //------------------------------------------------------------
    // Main Memory Interface
    //------------------------------------------------------------

    output reg                      mem_read,
    output reg                      mem_write,
    output reg  [31:0]              mem_addr,
    output reg  [31:0]              mem_wdata,

    input  wire [31:0]              mem_rdata,
    input  wire                     mem_ready

);


//============================================================
// FSM
//============================================================

reg [2:0] state;
reg [2:0] next_state;


//============================================================
// Saved CPU Request
//============================================================

reg [31:0] req_addr;
reg [31:0] req_wdata;

reg req_read;
reg req_write;


//============================================================
// Cache Refill Buffer
//============================================================

reg [127:0] refill_line;
reg [1:0]   refill_word;
reg         refill_done;

//------------------------------------------------------------
// Modified Cache Line
//------------------------------------------------------------

reg [127:0] updated_line;

//============================================================
// Address Decode
//============================================================

wire [`TAG_BITS-1:0]    addr_tag;
wire [`INDEX_BITS-1:0]  addr_index;
wire [`OFFSET_BITS-1:0] addr_offset;

assign addr_tag    = req_addr[31:10];
assign addr_index  = req_addr[9:4];
assign addr_offset = req_addr[3:0];


//============================================================
// Refill Address Generator
//============================================================

wire [31:0] refill_addr;

assign refill_addr =
{
    req_addr[31:4],
    refill_word,
    2'b00
};


//============================================================
// Cache Tag RAM Interface
//============================================================

reg tag_we;

wire [`TAG_BITS-1:0] tag_out;
wire                 valid_out;

wire [`TAG_BITS-1:0] tag_in;
wire [`INDEX_BITS-1:0] tag_index;

assign tag_in    = addr_tag;
assign tag_index = addr_index;


//============================================================
// Cache Data RAM Interface
//============================================================

reg data_we;

wire [`INDEX_BITS-1:0] data_index;

assign data_index = addr_index;

reg  [127:0] line_in;
wire [127:0] line_out;


//============================================================
// Cache Hit Detection
//============================================================

wire cache_hit;

assign cache_hit =
        valid_out &&
        (tag_out == addr_tag);


//============================================================
// Cache Word Selection
//============================================================

reg [31:0] cache_word;

always @(*) begin

    case(addr_offset[3:2])

        2'd0: cache_word = line_out[31:0];
        2'd1: cache_word = line_out[63:32];
        2'd2: cache_word = line_out[95:64];
        2'd3: cache_word = line_out[127:96];

        default:
            cache_word = 32'd0;

    endcase

end
//------------------------------------------------------------
// Write Hit Update Logic
//------------------------------------------------------------

always @(*) begin

    updated_line = line_out;

    if(req_write && cache_hit) begin

        case(addr_offset[3:2])

            2'd0:
                updated_line[31:0] = req_wdata;

            2'd1:
                updated_line[63:32] = req_wdata;

            2'd2:
                updated_line[95:64] = req_wdata;

            2'd3:
                updated_line[127:96] = req_wdata;

        endcase

    end

end


//============================================================
// Refill Word Selection
//============================================================

reg [31:0] refill_word_data;

always @(*) begin

    case(addr_offset[3:2])

        2'd0: refill_word_data = refill_line[31:0];
        2'd1: refill_word_data = refill_line[63:32];
        2'd2: refill_word_data = refill_line[95:64];
        2'd3: refill_word_data = refill_line[127:96];

        default:
            refill_word_data = 32'd0;

    endcase

end
//============================================================
// Next State Logic
//============================================================

always @(*) begin

    //--------------------------------------------------------
    // Default
    //--------------------------------------------------------

    next_state = state;

    case(state)

    //--------------------------------------------------------
    // CACHE_IDLE
    //--------------------------------------------------------

    `CACHE_IDLE:
    begin

        if(cpu_read || cpu_write)
            next_state = `CACHE_LOOKUP;

    end


    //--------------------------------------------------------
    // CACHE_LOOKUP
    //--------------------------------------------------------

    `CACHE_LOOKUP:
    begin

        //----------------------------------------------------
        // Cache Hit
        //----------------------------------------------------

        if(cache_hit) begin

            //--------------------------------------------------
            // Write Hit: write-through issues a real mem_write
            // to main_memory (which takes multiple cycles to
            // actually commit, per its wait_counter). Previously
            // this transitioned to CACHE_COMPLETE unconditionally
            // one cycle after issuing the write, without ever
            // confirming main_memory had latched it -- the same
            // class of bug the write-miss path below was already
            // fixed for. mem_write stays asserted combinationally
            // while cache_hit && req_write hold (see the output
            // logic), so holding here is safe: main_memory only
            // samples it once, when it transitions out of !busy.
            //--------------------------------------------------

            if(req_write) begin

                if(mem_ready)
                    next_state = `CACHE_COMPLETE;
                else
                    next_state = `CACHE_LOOKUP;

            end

            //--------------------------------------------------
            // Read Hit: no memory access needed, cache_word is
            // already available -- completes immediately.
            //--------------------------------------------------

            else
                next_state = `CACHE_COMPLETE;

        end

        //----------------------------------------------------
        // Cache Miss
        //----------------------------------------------------

        else
            next_state = `CACHE_MISS;

    end


    //--------------------------------------------------------
    // CACHE_MISS
    //--------------------------------------------------------

    `CACHE_MISS:
    begin

        //----------------------------------------------------
        // Read Miss
        //----------------------------------------------------

        if(req_read)
            next_state = `CACHE_REFILL_REQ;

        //----------------------------------------------------
        // Write Miss (write-no-allocate): wait for the real
        // memory write to actually complete (mem_ready) before
        // declaring done -- previously this transitioned to
        // CACHE_COMPLETE unconditionally one cycle after issuing
        // the write, without ever confirming SDRAM had latched
        // it. mem_write is driven combinationally off
        // (state==CACHE_MISS && req_write) below, so holding here
        // correctly keeps the write request asserted until ready.
        //----------------------------------------------------

        else begin

            if(mem_ready)
                next_state = `CACHE_COMPLETE;
            else
                next_state = `CACHE_MISS;

        end

    end


    //--------------------------------------------------------
    // CACHE_REFILL_REQ
    //--------------------------------------------------------

    `CACHE_REFILL_REQ:
    begin

        //----------------------------------------------------
        // Memory request is issued for one clock
        //----------------------------------------------------

        next_state = `CACHE_REFILL_WAIT;

    end



//========================================================
// CACHE_REFILL_WAIT
//========================================================

`CACHE_REFILL_WAIT:
begin

    if(mem_ready) begin

        if(refill_word == 2'd3)
            next_state = `CACHE_COMPLETE;
        else
            next_state = `CACHE_REFILL_REQ;
    end

end


    //--------------------------------------------------------
    // CACHE_COMPLETE
    //--------------------------------------------------------

    `CACHE_COMPLETE:
    begin

        next_state = `CACHE_IDLE;

    end


    //--------------------------------------------------------
    // Default
    //--------------------------------------------------------

    default:
    begin

        next_state = `CACHE_IDLE;

    end

    endcase

end
//============================================================
// Sequential Logic
//============================================================

always @(posedge clk or posedge rst) begin

    //--------------------------------------------------------
    // Reset
    //--------------------------------------------------------

    if(rst) begin

        state <= `CACHE_IDLE;

        req_addr   <= 32'd0;
        req_wdata  <= 32'd0;

        req_read   <= 1'b0;
        req_write  <= 1'b0;

        refill_line <= 128'd0;
        refill_word <= 2'd0;
        refill_done <= 1'b0;

    end

    //--------------------------------------------------------
    // Normal Operation
    //--------------------------------------------------------

    else begin

        //----------------------------------------------------
        // State Register
        //----------------------------------------------------

        state <= next_state;

        //----------------------------------------------------
        // Latch CPU Request
        //----------------------------------------------------

        if(state == `CACHE_IDLE) begin

            if(cpu_read || cpu_write) begin

                req_addr  <= cpu_addr;
                req_wdata <= cpu_wdata;

                req_read  <= cpu_read;
                req_write <= cpu_write;

            end

        end

        //----------------------------------------------------
        // Initialize Refill
        //----------------------------------------------------

        if(state == `CACHE_MISS) begin

            if(req_read) begin

                refill_word <= 2'd0;
                refill_line <= 128'd0;
                refill_done <= 1'b0;

            end

        end

        //----------------------------------------------------
        // Receive Memory Word
        //----------------------------------------------------

        if(state == `CACHE_REFILL_WAIT) begin

            if(mem_ready) begin

                case(refill_word)

                    2'd0:
                        refill_line[31:0] <= mem_rdata;

                    2'd1:
                        refill_line[63:32] <= mem_rdata;

                    2'd2:
                        refill_line[95:64] <= mem_rdata;

                    2'd3:
                        refill_line[127:96] <= mem_rdata;

                endcase

                //------------------------------------------------
                // Last Word?
                //------------------------------------------------

                if(refill_word == 2'd3) begin

                    refill_done <= 1'b1;

                end
                else begin

                    refill_word <= refill_word + 1'b1;

                end

            end

        end

        //----------------------------------------------------
        // Clear Refill Flag
        //----------------------------------------------------

        if(state == `CACHE_COMPLETE) begin

           refill_word <= 2'd0;
           refill_done <= 1'b0;

           req_read    <= 1'b0;
           req_write   <= 1'b0;

        end

    end

end
//============================================================
// Output Logic
//============================================================

always @(*) begin

    //--------------------------------------------------------
    // Default Outputs
    //--------------------------------------------------------

    cpu_ready = 1'b0;
    cpu_rdata = 32'd0;

    mem_read  = 1'b0;
    mem_write = 1'b0;

    mem_addr  = 32'd0;
    mem_wdata = req_wdata;

    tag_we    = 1'b0;
    data_we   = 1'b0;

    line_in   = refill_line;

    //--------------------------------------------------------
    // FSM Outputs
    //--------------------------------------------------------

    case(state)

    //========================================================
    // CACHE_IDLE
    //========================================================

    `CACHE_IDLE:
    begin
        // Nothing
    end


    //========================================================
    // CACHE_LOOKUP
    //========================================================

    `CACHE_LOOKUP:
begin

    if(cache_hit) begin

        //--------------------------------------------------
        // READ HIT
        //--------------------------------------------------
        // No cpu_ready here — the transaction completes once,
        // in CACHE_COMPLETE, using cache_word.
        //--------------------------------------------------

        //--------------------------------------------------
        // WRITE HIT
        //--------------------------------------------------

        if(req_write) begin

            // Write-through to memory. Gated with !mem_ready for the
            // same reason as CACHE_MISS/CACHE_REFILL_REQ/WAIT: drop
            // the request combinationally the instant mem_ready
            // pulses, so sdram_controller's SDRAM_IDLE state doesn't
            // see it still held on that same cycle and misread it as
            // a brand-new request.
            if (!mem_ready) begin
                mem_write = 1'b1;
                mem_addr  = req_addr;
                mem_wdata = req_wdata;
            end

            // Update cache line
            data_we = 1'b1;
            line_in = updated_line;

        end

    end

end


    //========================================================
    // CACHE_MISS
    //========================================================

    `CACHE_MISS:
    begin

        //----------------------------------------------------
        // Write-No-Allocate
        //----------------------------------------------------

        // BUG FIX: only hold mem_write while !mem_ready. mem_ready
        // is now a genuine one-shot completion pulse from sdram_
        // controller (see that module's `ready` generation). If we
        // kept driving mem_write=1 for the entire CACHE_MISS cycle
        // -- including the very cycle mem_ready fires -- sdram_
        // controller's SDRAM_IDLE state (which returns to IDLE on
        // that exact same cycle) would see write_req still held
        // and misread it as a brand-new request, re-triggering a
        // spurious duplicate transaction. Dropping it combinationally
        // the instant mem_ready is seen (rather than one cycle later,
        // once the state register catches up to CACHE_COMPLETE)
        // avoids that race.

        if(req_write && !mem_ready) begin

            mem_write = 1'b1;
            mem_addr  = req_addr;
            mem_wdata = req_wdata;

        end

    end


    //========================================================
    // CACHE_REFILL_REQ
    //========================================================

    `CACHE_REFILL_REQ:
    begin

        // See the CACHE_MISS note above: drop the request
        // combinationally the instant mem_ready pulses, so
        // sdram_controller's SDRAM_IDLE state doesn't mistake the
        // still-held level (from the cycle we haven't yet reacted
        // to) for a new request.
        if (!mem_ready) begin
            mem_read = 1'b1;
            mem_addr = refill_addr;
        end

    end


    //========================================================
    // CACHE_REFILL_WAIT
    //========================================================

`CACHE_REFILL_WAIT:
begin

    // BUG FIX: CACHE_REFILL_REQ only pulses mem_read for a single
    // cycle before unconditionally moving here. If SDRAM wasn't in
    // SDRAM_IDLE on that exact cycle (e.g. still finishing a
    // previous transaction), sdram_fsm's start_read -- wired
    // directly to this live, unlatched mem_read -- would never see
    // it, so SDRAM's FSM would never actually leave IDLE to service
    // this request. The request was silently dropped, yet this
    // state still went on to accept whatever stale mem_ready/
    // mem_rdata eventually showed up for unrelated reasons.
    //
    // Keep asserting the request here too, so it stays held at the
    // level until SDRAM genuinely accepts and completes it. But drop
    // it combinationally the instant mem_ready pulses (rather than
    // one cycle later once the FSM state register catches up to
    // CACHE_COMPLETE) -- otherwise sdram_controller's SDRAM_IDLE
    // state, which returns to IDLE on that exact same cycle, would
    // see the request still held and misread it as a brand-new one,
    // re-triggering a spurious duplicate transaction.

    if (!mem_ready) begin
        mem_read = 1'b1;
        mem_addr = refill_addr;
    end

end


    //========================================================
    // CACHE_COMPLETE
    //========================================================

`CACHE_COMPLETE:
begin

    //----------------------------------------------------
    // Write completed refill into cache
    //----------------------------------------------------

    if(refill_done) begin

        tag_we  = 1'b1;
        data_we = 1'b1;

        line_in = refill_line;

    end

    //----------------------------------------------------
    // CPU response
    //----------------------------------------------------

    cpu_ready = 1'b1;

    if(req_read) begin

        // cache_hit is still valid here: for a genuine hit the
        // tag/data RAMs were never written this cycle, and for a
        // just-finished refill the RAM write above hasn't landed
        // yet (it's a registered write), so cache_hit still
        // correctly reads as 0 for that case.
        if(cache_hit)
            cpu_rdata = cache_word;
        else
            cpu_rdata = refill_word_data;

    end
    else
        cpu_rdata = 32'd0;

end


    //========================================================
    // Default
    //========================================================

    default:
    begin

    end

    endcase

end
//============================================================
// Cache Tag RAM
//============================================================

cache_tag_ram u_cache_tag_ram (

    .clk       (clk),
    .rst       (rst),
    .we        (tag_we),

    .index     (tag_index),

    .tag_in    (tag_in),
    .valid_in  (`VALID_BIT),

    .tag_out   (tag_out),
    .valid_out (valid_out)

);


//============================================================
// Cache Data RAM
//============================================================

cache_data_ram u_cache_data_ram (

    .clk      (clk),
    .we       (data_we),

    .index    (data_index),

    .line_in  (line_in),
    .line_out (line_out)

);


endmodule

//...................................................................................
// cache_dma_arbiter: giữ nguyên bản gốc (ưu tiên DMA > cache, một master mỗi
// lúc, nhả quyền khi mem_ready). Dự án không có DMA: cache_top buộc mọi đầu
// vào dma_* = 0, nên arbiter luôn chọn cache (thêm 1 chu kỳ MASTER_NONE ->
// MASTER_CACHE cho mỗi giao dịch backend, như bản gốc).
//...................................................................................

module cache_dma_arbiter(

    //------------------------------------------------------------
    // Clock / Reset
    //------------------------------------------------------------

    input wire clk,
    input wire rst,

    //------------------------------------------------------------
    // Cache Master
    //------------------------------------------------------------

    input  wire        cache_mem_read,
    input  wire        cache_mem_write,
    input  wire [31:0] cache_mem_addr,
    input  wire [31:0] cache_mem_wdata,

    output reg  [31:0] cache_mem_rdata,
    output reg         cache_mem_ready,

    //------------------------------------------------------------
    // DMA Master
    //------------------------------------------------------------

    input  wire        dma_mem_read,
    input  wire        dma_mem_write,

    input  wire [31:0] dma_mem_read_addr,
    input  wire [31:0] dma_mem_write_addr,
    input  wire [31:0] dma_mem_wdata,

    output reg  [31:0] dma_mem_rdata,
    output reg         dma_mem_ready,

    //------------------------------------------------------------
    // Main Memory
    //------------------------------------------------------------

    output reg         mem_read,
    output reg         mem_write,

    output reg [31:0]  mem_addr,
    output reg [31:0]  mem_wdata,

    input  wire [31:0]  mem_rdata,
    input  wire         mem_ready

);

    //------------------------------------------------------------
    // Master Encoding
    //------------------------------------------------------------

    localparam MASTER_NONE  = 2'd0;
    localparam MASTER_CACHE = 2'd1;
    localparam MASTER_DMA   = 2'd2;

    reg [1:0] active_master;


    //------------------------------------------------------------
    // Arbitration FSM
    //------------------------------------------------------------

    always @(posedge clk or posedge rst)
    begin

        if(rst)
        begin
            active_master <= MASTER_NONE;
        end

        else
        begin

            case(active_master)

                //------------------------------------------------
                // No active transaction
                //------------------------------------------------

                MASTER_NONE:
                begin

                    // DMA has priority
                    if(dma_mem_read || dma_mem_write)
                    begin
                        active_master <= MASTER_DMA;
                    end

                    // Otherwise cache
                    else if(cache_mem_read || cache_mem_write)
                    begin
                        active_master <= MASTER_CACHE;
                    end
                end


                //------------------------------------------------
                // Cache transaction
                //------------------------------------------------

                MASTER_CACHE:
                begin

                    if(mem_ready)
                        active_master <= MASTER_NONE;

                end


                //------------------------------------------------
                // DMA transaction
                //------------------------------------------------

                MASTER_DMA:
                begin

                    if(mem_ready)
                        active_master <= MASTER_NONE;

                end


                //------------------------------------------------
                // Safety
                //------------------------------------------------

                default:
                begin
                    active_master <= MASTER_NONE;
                end

            endcase

        end

    end


    //------------------------------------------------------------
    // Memory Routing
    //------------------------------------------------------------

    always @(*)
    begin

        //--------------------------------------------------------
        // Defaults
        //--------------------------------------------------------

        mem_read  = 1'b0;
        mem_write = 1'b0;

        mem_addr  = 32'd0;
        mem_wdata = 32'd0;

        cache_mem_rdata = 32'd0;
        cache_mem_ready = 1'b0;

        dma_mem_rdata   = 32'd0;
        dma_mem_ready   = 1'b0;


        //--------------------------------------------------------
        // CACHE
        //--------------------------------------------------------

        if(active_master == MASTER_CACHE)
        begin

            mem_read  = cache_mem_read;
            mem_write = cache_mem_write;

            mem_addr  = cache_mem_addr;
            mem_wdata = cache_mem_wdata;

            cache_mem_rdata = mem_rdata;
            cache_mem_ready = mem_ready;

        end


        //--------------------------------------------------------
        // DMA
        //--------------------------------------------------------

        else if(active_master == MASTER_DMA)
        begin

            mem_read  = dma_mem_read;
            mem_write = dma_mem_write;

            if(dma_mem_read)
                mem_addr = dma_mem_read_addr;
            else
                mem_addr = dma_mem_write_addr;

            mem_wdata = dma_mem_wdata;

            dma_mem_rdata = mem_rdata;
            dma_mem_ready = mem_ready;

        end

    end

endmodule

//...................................................................................
// cache_top: top bộ nhớ dữ liệu ngoài.
//
//   USE_CACHE = 1 : cpu_* -> cache_controller -> cache_dma_arbiter -> sdram_top
//   USE_CACHE = 0 : cpu_* ---------------------> cache_dma_arbiter -> sdram_top
//
// Cả hai chế độ dùng CÙNG đường arbiter + backend sdram_top, nên so sánh cache
// bật/tắt chỉ khác ở lớp cache. sdram_top chứa sdram_model (thiết bị nhớ hành
// vi), nên cache_top chỉ dùng cho MÔ PHỎNG; không có cổng ra chip SDRAM thật.
//
// Giao diện cpu_* (do axi_interconnect điều khiển): cpu_read/cpu_write giữ mức
// kèm cpu_addr/cpu_wdata ổn định tới cpu_ready và hạ tổ hợp ngay trong chu kỳ
// cpu_ready; cpu_rdata chỉ được lấy đúng chu kỳ cpu_ready. cpu_addr là offset
// trong cửa sổ RAM ngoài (địa chỉ bus - EXT_RAM_BASE). Reset rst mức cao
// (style bản gốc; soc_top nối rst = ~rst_n).
//...................................................................................

`include "cache_pkg.vh"

module cache_top #(

    parameter USE_CACHE   = 1,        // 1: cache_controller, 0: bypass (no cache)
    parameter MODEL_DEPTH = 32768     // halfwords allocated in sdram_model (64 KB)

)(

    //------------------------------------------------------------
    // Clock / Reset
    //------------------------------------------------------------

    input wire clk,
    input wire rst,

    //------------------------------------------------------------
    // CPU Interface
    //------------------------------------------------------------

    input  wire        cpu_read,
    input  wire        cpu_write,

    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,

    output wire [31:0] cpu_rdata,
    output wire        cpu_ready

    // riscv-soc-fir-hls: DMA interface (dma_read/dma_write/dma_*_addr/
    // dma_write_data/dma_read_data/dma_ready/dma_active) removed - no DMA.

);


    //------------------------------------------------------------
    // Cache Controller -> Arbiter
    //------------------------------------------------------------

    wire        cache_mem_read;
    wire        cache_mem_write;

    wire [31:0] cache_mem_addr;
    wire [31:0] cache_mem_wdata;

    wire [31:0] cache_mem_rdata;
    wire        cache_mem_ready;


    //------------------------------------------------------------
    // Arbiter -> Main Memory (sdram_top)
    //------------------------------------------------------------

    wire        arb_mem_read;
    wire        arb_mem_write;

    wire [31:0] arb_mem_addr;
    wire [31:0] arb_mem_wdata;

    wire [31:0] arb_mem_rdata;
    wire        arb_mem_ready;


    //------------------------------------------------------------
    // Cache Controller (or bypass)
    //------------------------------------------------------------

    generate
        if (USE_CACHE != 0) begin : g_cache

            cache_controller U_CACHE_CONTROLLER(

                .clk(clk),
                .rst(rst),

                //------------------------------------------------
                // CPU
                //------------------------------------------------

                .cpu_read(cpu_read),
                .cpu_write(cpu_write),

                .cpu_addr(cpu_addr),
                .cpu_wdata(cpu_wdata),

                .cpu_rdata(cpu_rdata),
                .cpu_ready(cpu_ready),

                //------------------------------------------------
                // Main Memory
                //------------------------------------------------

                .mem_read(cache_mem_read),
                .mem_write(cache_mem_write),

                .mem_addr(cache_mem_addr),
                .mem_wdata(cache_mem_wdata),

                .mem_rdata(cache_mem_rdata),
                .mem_ready(cache_mem_ready)

            );

        end else begin : g_bypass

            // riscv-soc-fir-hls: no cache, same arbiter + backend path
            assign cache_mem_read  = cpu_read;
            assign cache_mem_write = cpu_write;

            assign cache_mem_addr  = cpu_addr;
            assign cache_mem_wdata = cpu_wdata;

            assign cpu_rdata = cache_mem_rdata;
            assign cpu_ready = cache_mem_ready;

        end
    endgenerate


    //------------------------------------------------------------
    // Cache / DMA Arbiter (DMA inputs tied off: no DMA in this SoC)
    //------------------------------------------------------------

    cache_dma_arbiter U_ARBITER(

        .clk(clk),
        .rst(rst),

        //--------------------------------------------------------
        // Cache
        //--------------------------------------------------------

        .cache_mem_read(cache_mem_read),
        .cache_mem_write(cache_mem_write),

        .cache_mem_addr(cache_mem_addr),
        .cache_mem_wdata(cache_mem_wdata),

        .cache_mem_rdata(cache_mem_rdata),
        .cache_mem_ready(cache_mem_ready),

        //--------------------------------------------------------
        // DMA (unused)
        //--------------------------------------------------------

        .dma_mem_read(1'b0),
        .dma_mem_write(1'b0),

        .dma_mem_read_addr(32'd0),
        .dma_mem_write_addr(32'd0),

        .dma_mem_wdata(32'd0),

        .dma_mem_rdata(),
        .dma_mem_ready(),

        //--------------------------------------------------------
        // Main Memory
        //--------------------------------------------------------

        .mem_read(arb_mem_read),
        .mem_write(arb_mem_write),

        .mem_addr(arb_mem_addr),
        .mem_wdata(arb_mem_wdata),

        .mem_rdata(arb_mem_rdata),
        .mem_ready(arb_mem_ready)

    );


    //------------------------------------------------------------
    // Main Memory: sdram_top (replaces the original main_memory
    // instance; main_memory is kept above as reference only)
    //------------------------------------------------------------

    sdram_top #(

        .MODEL_DEPTH(MODEL_DEPTH)

    ) U_SDRAM(

        .clk(clk),
        .rst(rst),

        .read_req(arb_mem_read),
        .write_req(arb_mem_write),

        .address(arb_mem_addr),
        .write_data(arb_mem_wdata),

        .read_data(arb_mem_rdata),
        .ready(arb_mem_ready)

    );

endmodule
