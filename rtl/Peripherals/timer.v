`timescale 1ns/1ps
// Timer MMIO có chế độ one-shot, periodic và bộ đếm tick.
`include "soc_pkg.vh"

module timer #(

    parameter WIDTH = `DATA_WIDTH

)(

    input  wire                 clk,
    input  wire                 rst_n,

    // AXI-Lite Interface

    input  wire                 wr_en,
    input  wire                 rd_en,
    input  wire [31:0]          wr_addr,
    input  wire [31:0]          rd_addr,
    input  wire [WIDTH-1:0]     wdata,

    output reg  [WIDTH-1:0]     rdata,

    // Timer Interrupt

    output wire                 irq

);

    // Register decode (offset[5:2])

    localparam [3:0] IDX_PERIOD = 4'd1;
    localparam [3:0] IDX_CTRL   = 4'd2;
    localparam [3:0] IDX_TICK   = 4'd3;
    localparam       MIN_PERIOD = 2;

    wire [3:0] wr_idx = wr_addr[5:2];
    wire [3:0] rd_idx = rd_addr[5:2];

    wire wr_new    = (wr_idx == IDX_PERIOD) || (wr_idx == IDX_CTRL) || (wr_idx == IDX_TICK);
    wire legacy_wr = wr_en && !wr_new;
    wire period_wr = wr_en && (wr_idx == IDX_PERIOD);
    wire ctrl_wr   = wr_en && (wr_idx == IDX_CTRL);

    // LEGACY one-shot (logic gốc, chỉ đổi wr_en -> legacy_wr, irq -> irq_legacy)

    reg [WIDTH-1:0] timer_count;
    reg [WIDTH-1:0] timer_compare;
    reg             timer_enable;
    reg             irq_legacy;

    // Write Logic

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            timer_compare <= {WIDTH{1'b0}};
            timer_enable  <= 1'b0;

        end

        else begin

            if (legacy_wr) begin

                timer_compare <= wdata;
                timer_enable  <= 1'b1;


            end

            else if (timer_enable &&
              (timer_count >= timer_compare)) begin

                timer_enable <= 1'b0;

            end

        end

    end

    // Counter Logic

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n)

            timer_count <= {WIDTH{1'b0}};

        else if (timer_enable)

            timer_count <= timer_count + 1'b1;

        else

            timer_count <= {WIDTH{1'b0}};

    end

    // Interrupt Logic

    always @(posedge clk or negedge rst_n) begin

     if (!rst_n)

         irq_legacy <= 1'b0;

     else if (timer_enable &&
              (timer_count >= timer_compare))

         irq_legacy <= 1'b1;

     else

         irq_legacy <= 1'b0;

    end

    // PERIODIC / one-shot mới (PERIOD, CTRL, TICK_COUNT)

    reg [WIDTH-1:0] period_q;
    reg [WIDTH-1:0] period_cnt;     // chu kỳ đã đếm kể từ cạnh bật / tick trước
    reg [WIDTH-1:0] tick_count;
    reg             ctrl_enable;
    reg             ctrl_periodic;
    reg             tick_q;

    wire period_ok = (period_q >= MIN_PERIOD);
    wire tick_hit  = ctrl_enable && period_ok &&
                     (period_cnt >= period_q - 1'b1);

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            period_q      <= {WIDTH{1'b0}};
            period_cnt    <= {WIDTH{1'b0}};
            tick_count    <= {WIDTH{1'b0}};
            ctrl_enable   <= 1'b0;
            ctrl_periodic <= 1'b0;
            tick_q        <= 1'b0;

        end

        else begin

            tick_q <= 1'b0;

            if (period_wr)
                period_q <= wdata;

            if (ctrl_wr)
                ctrl_periodic <= wdata[1];

            if (ctrl_wr && !wdata[0]) begin
                // disable: wins over a tick in the same cycle
                ctrl_enable <= 1'b0;
                period_cnt  <= {WIDTH{1'b0}};
            end

            else if (ctrl_wr && !ctrl_enable) begin
                // 0 -> 1: this edge is E0, first tick at E0 + PERIOD
                ctrl_enable <= 1'b1;
                period_cnt  <= {WIDTH{1'b0}};
            end

            else if (tick_hit) begin
                tick_q     <= 1'b1;
                tick_count <= tick_count + 1'b1;
                period_cnt <= {WIDTH{1'b0}};
                // one-shot: stop after this tick (a CTRL write now uses the new mode)
                if (!(ctrl_wr ? wdata[1] : ctrl_periodic))
                    ctrl_enable <= 1'b0;
            end

            else if (ctrl_enable && period_ok)
                period_cnt <= period_cnt + 1'b1;

            else
                period_cnt <= {WIDTH{1'b0}};

        end

    end

    assign irq = irq_legacy | tick_q;

// Read Logic (registered on rd_en, no read side effects)

reg [WIDTH-1:0] rd_mux;

always @(*) begin

    case (rd_idx)

        IDX_PERIOD: rd_mux = period_q;
        IDX_CTRL:   rd_mux = {{(WIDTH-3){1'b0}}, ~period_ok, ctrl_periodic, ctrl_enable};
        IDX_TICK:   rd_mux = tick_count;
        default:    rd_mux = timer_count;       // LEGACY (0x00 and old aliases)

    endcase

end

always @(posedge clk or negedge rst_n) begin

    if (!rst_n)

        rdata <= {WIDTH{1'b0}};

    else if (rd_en)

        rdata <= rd_mux;

end



endmodule
