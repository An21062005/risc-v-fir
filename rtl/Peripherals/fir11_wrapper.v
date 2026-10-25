`timescale 1ns/1ps
`default_nettype none

// Thanh ghi MMIO cho FIR11 HLS; giữ một mẫu đang xử lý và báo IRQ khi có kết quả.

module fir11_wrapper (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        wr_en,
    input  wire        rd_en,
    input  wire [31:0] wr_addr,
    input  wire [31:0] rd_addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    output wire        irq
);

    // Register index = offset[5:2]

    localparam [3:0] IDX_DATA_IN  = 4'd0;   // 0x00
    localparam [3:0] IDX_DATA_OUT = 4'd1;   // 0x04
    localparam [3:0] IDX_STATUS   = 4'd2;   // 0x08
    localparam [3:0] IDX_CTRL     = 4'd3;   // 0x0C
    localparam [3:0] IDX_CYC_CNT  = 4'd4;   // 0x10

    wire [3:0] wr_idx = wr_addr[5:2];
    wire [3:0] rd_idx = rd_addr[5:2];

    // FIR11 HLS IP (ap_ctrl_hs, x: ap_none, y: ap_vld)

    wire        ap_rst;
    reg         ap_start;
    wire        ap_done;
    wire        ap_idle;
    wire        ap_ready;
    wire [31:0] hls_y;
    wire        hls_y_ap_vld;
    reg  [31:0] x_q;

    reg         soft_rst_q;
    assign ap_rst = ~rst_n | soft_rst_q;

    fir u_fir11 (
        .ap_clk   (clk),
        .ap_rst   (ap_rst),
        .ap_start (ap_start),
        .ap_done  (ap_done),
        .ap_idle  (ap_idle),
        .ap_ready (ap_ready),
        .y        (hls_y),
        .y_ap_vld (hls_y_ap_vld),
        .x        (x_q)
    );

    // Bus decode

    reg busy_q;               // from DATA_IN accepted until ap_done
    reg done_q;
    reg overrun_q;

    wire wr_data_in   = wr_en && (wr_idx == IDX_DATA_IN);
    wire accept       = wr_data_in && !busy_q;
    wire wr_ctrl      = wr_en && (wr_idx == IDX_CTRL);
    wire clr_by_ctrl  = wr_ctrl && wdata[0];
    wire soft_rst_req = wr_ctrl && wdata[1];
    wire rd_data_out  = rd_en && (rd_idx == IDX_DATA_OUT);

    // Only events of the transaction in flight count; busy_q is already 0
    wire hls_finish   = busy_q && ap_done      && !soft_rst_req;
    wire hls_y_take   = busy_q && hls_y_ap_vld && !soft_rst_req;

    // Control: ap_start held high until ap_ready

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_q        <= 32'd0;
            ap_start   <= 1'b0;
            busy_q     <= 1'b0;
            soft_rst_q <= 1'b0;
        end else begin
            soft_rst_q <= soft_rst_req;
            if (soft_rst_req) begin
                ap_start <= 1'b0;
                busy_q   <= 1'b0;
            end else if (accept) begin
                x_q      <= wdata;
                ap_start <= 1'b1;
                busy_q   <= 1'b1;
            end else begin
                if (ap_start && (ap_ready || hls_finish))
                    ap_start <= 1'b0;
                if (hls_finish)
                    busy_q <= 1'b0;
            end
        end
    end

    // Result, done flag, overrun flag, cycle counter

    reg [31:0] y_q;
    reg [31:0] cyc_cnt_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_q       <= 32'd0;
            done_q    <= 1'b0;
            overrun_q <= 1'b0;
            cyc_cnt_q <= 32'd0;
        end else begin
            if (hls_y_take)
                y_q <= hls_y;

            // soft reset > finish > ordinary clear
            if (soft_rst_req)
                done_q <= 1'b0;
            else if (hls_finish)
                done_q <= 1'b1;
            else if (accept || rd_data_out || clr_by_ctrl)
                done_q <= 1'b0;

            if (soft_rst_req || clr_by_ctrl)
                overrun_q <= 1'b0;
            else if (wr_data_in && busy_q)
                overrun_q <= 1'b1;

            if (accept)
                cyc_cnt_q <= 32'd0;
            else if (busy_q && !soft_rst_req)
                cyc_cnt_q <= cyc_cnt_q + 32'd1;
        end
    end

    assign irq = done_q;

    // Read data: one snapshot and side effect per single-cycle rd_en.

    reg [31:0] rd_mux;

    always @(*) begin
        rd_mux = 32'd0;
        case (rd_idx)
            IDX_DATA_OUT: rd_mux = y_q;
            IDX_STATUS:   rd_mux = {27'd0, overrun_q, busy_q, ap_ready, ap_idle, done_q};
            IDX_CYC_CNT:  rd_mux = cyc_cnt_q;
            default:      rd_mux = 32'd0;      // DATA_IN, CTRL (write-only) and unmapped
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rdata <= 32'd0;
        else if (rd_en)
            rdata <= rd_mux;
    end

endmodule

`default_nettype wire
