`timescale 1ns/1ps

// Backend SDRAM mô phỏng; nguồn tiny-riscv-soc (MIT, (c) 2026 Leela Shanmukh Yagneek Patnala).

`include "sdram_pkg.vh"

module sdram_fsm(

    // Clock / Reset

    input wire clk,
    input wire rst,


    // Control Inputs

    input wire start_read,
    input wire start_write,

    input wire refresh_request,

    input wire timer_done,

    // Saved Operation Type

    input wire op_is_read,


    // State Outputs

    output reg [3:0] state,
    output reg [3:0] next_state

);


// STATE REGISTER

always @(posedge clk or posedge rst)
begin

    if (rst)

        state <= `SDRAM_RESET;

    else

        state <= next_state;

end


// NEXT STATE LOGIC

always @(*)
begin

    // Default

    next_state = state;


    case(state)


        // RESET

        `SDRAM_RESET:
        begin

            if(timer_done)

                next_state = `SDRAM_PRECHARGE;

        end


        // INITIAL PRECHARGE

        `SDRAM_PRECHARGE:
        begin

            if(timer_done)

                next_state = `SDRAM_REFRESH1;

        end


        // REFRESH #1

        `SDRAM_REFRESH1:
        begin

            if(timer_done)

                next_state = `SDRAM_REFRESH2;

        end


        // REFRESH #2

        `SDRAM_REFRESH2:
        begin

            if(timer_done)

                next_state = `SDRAM_MODE;

        end


        // MODE REGISTER

        `SDRAM_MODE:
        begin

            if(timer_done)

                next_state = `SDRAM_IDLE;

        end


        // IDLE

        `SDRAM_IDLE:
        begin

            // Refresh has highest priority

            if(refresh_request)

                next_state = `SDRAM_REFRESH1;


            // New READ transaction

            else if(start_read)

                next_state = `SDRAM_ACTIVATE;


            // New WRITE transaction

            else if(start_write)

                next_state = `SDRAM_ACTIVATE;

        end


        // ACTIVATE

        `SDRAM_ACTIVATE:
        begin

            if(timer_done)
            begin

                // Saved transaction was READ

                if(op_is_read)

                    next_state = `SDRAM_READ;


                // Saved transaction was WRITE

                else

                    next_state = `SDRAM_WRITE;

            end

        end


        // READ

        `SDRAM_READ:
        begin

            if(timer_done)

                next_state = `SDRAM_PRECHARGE_ROW;

        end


        // WRITE

        `SDRAM_WRITE:
        begin

            if(timer_done)

                next_state = `SDRAM_PRECHARGE_ROW;

        end


        // PRECHARGE AFTER READ / WRITE

        `SDRAM_PRECHARGE_ROW:
        begin

            if(timer_done)

                next_state = `SDRAM_IDLE;

        end


        // WAIT

        `SDRAM_WAIT:
        begin

            if(timer_done)

                next_state = `SDRAM_IDLE;

        end


        // DEFAULT

        default:
        begin

            next_state = `SDRAM_RESET;

        end


    endcase

end


endmodule

`include "sdram_pkg.vh"

module refresh_controller(

    // Clock / Reset

    input wire clk,
    input wire rst,

    // Refresh Acknowledge

    input wire refresh_done,

    // Refresh Request

    output reg refresh_request

);

    // Refresh Counter

    reg [15:0] refresh_counter;

    // Counter Logic

    always @(posedge clk or posedge rst)
    begin

        if(rst)
        begin

            refresh_counter <= 16'd0;

            refresh_request <= 1'b0;

        end

        else
        begin

            // Waiting for Refresh Interval

            if(refresh_counter == (`REFRESH_PERIOD-1))
            begin

                refresh_counter <= 16'd0;

                refresh_request <= 1'b1;

            end

            // Counting

            else
            begin

                refresh_counter <= refresh_counter + 16'd1;

            end

            // Refresh Completed

            if(refresh_done)

                refresh_request <= 1'b0;

        end

    end

endmodule

`include "sdram_pkg.vh"

module sdram_controller(

    // Clock / Reset

    input wire clk,
    input wire rst,

    // CPU Interface

    input wire read_req,
    input wire write_req,

    input wire [31:0] address,
    input wire [31:0] write_data,

    output reg [31:0] read_data,

    output reg ready,

    // Refresh Controller

    input wire refresh_request,

    output reg refresh_done,

    // SDRAM FSM

    input wire [3:0] state,

    // FIX: needed so the timing-counter reload below can key off the
    input wire [3:0] next_state,

    // FIX: timer_done is now an OUTPUT of the controller so sdram_top
    output wire timer_done,

    // FIX: tells the FSM whether the in-flight transaction is a read or
    output wire op_is_read,

    // SDRAM Signals

    output reg cs_n,
    output reg ras_n,
    output reg cas_n,
    output reg we_n,

    output reg [12:0] sdram_addr,

    output reg [1:0] bank_addr,

    output reg [15:0] dq_out,

    input wire [15:0] dq_in,

    output reg dq_oe

);

// Saved CPU Request

reg [31:0] saved_address;
reg [31:0] saved_write_data;
reg saved_read;
reg saved_write;

// FIX: exposed so sdram_fsm can tell READ from WRITE once it actually
assign op_is_read = saved_read;

// Row / Column Decode

reg [12:0] row_address;
reg [8:0]  column_address;
reg [1:0]  bank;

// riscv-soc-fir-hls: mapping re-derived from the declared geometry,
always @(*) begin

    row_address = saved_address[22:10];

    column_address = {saved_address[9:2], 1'b0};

    bank = saved_address[24:23];

end
  
// Save CPU Request

always @(posedge clk or posedge rst)
begin
    if(rst)
    begin
        saved_address    <= 32'd0;
        saved_write_data <= 32'd0;
        saved_read       <= 1'b0;
        saved_write      <= 1'b0;
    end
    else
    begin
        if(read_req || write_req)
        begin
            saved_address    <= address;
            saved_write_data <= write_data;
            saved_read       <= read_req;
            saved_write      <= write_req;
        end
    end
end

// Timing Counter (single driver)

reg [3:0] timing_counter;

assign timer_done = (timing_counter == 4'd0);

always @(posedge clk or posedge rst)
begin
    if(rst)
        timing_counter <= 4'd0;
    else
    begin
        if(timing_counter != 4'd0)
            timing_counter <= timing_counter - 4'd1;
        else
        begin
            // FIX: this reload used to key off `state`. Since both this
            case(next_state)
                `SDRAM_ACTIVATE:
                    timing_counter <= `tRCD;

                `SDRAM_READ:
                    timing_counter <= `CAS_LATENCY + 2;

                // FIX: WRITE previously had no entry here, so
                `SDRAM_WRITE:
                    timing_counter <= `tWR;

                `SDRAM_PRECHARGE,
                `SDRAM_PRECHARGE_ROW:
                    timing_counter <= `tRP;

                `SDRAM_REFRESH1,
                `SDRAM_REFRESH2:
                    timing_counter <= `tRFC;

                `SDRAM_MODE:
                    timing_counter <= `tMRD;

                default:
                    timing_counter <= 4'd0;
     
              
            endcase
        end
    end
end

// Read Data Capture

reg [31:0] read_buffer;
reg        read_valid;

always @(posedge clk or posedge rst)
begin

    if(rst)
    begin

        read_buffer <= 32'd0;
        read_data   <= 32'd0;
        read_valid  <= 1'b0;

    end

    else
    begin

        read_valid <= 1'b0;

        if(state == `SDRAM_READ)
        begin

            // Capture LOW 16-bit half

            if(timing_counter == (`CAS_LATENCY - 1))
            begin

                read_buffer[15:0] <= dq_in;

            end

            // Capture HIGH 16-bit half

            if(timing_counter == 4'd0)
            begin

                read_data <= {
                    dq_in,
                    read_buffer[15:0]
                };

                read_valid <= 1'b1;

            end

        end

    end

end

// Write Half Select (single driver, sequential only -- no longer

reg write_half;

always @(posedge clk or posedge rst)
begin
    if(rst)
        write_half <= 1'b0;
    else if(state == `SDRAM_WRITE)
        write_half <= ~write_half;
    else
        write_half <= 1'b0;
end

// SDRAM Command / Output Generator

always @(*) begin

    // Defaults
    cs_n       = 1'b1;
    ras_n      = 1'b1;
    cas_n      = 1'b1;
    we_n       = 1'b1;

    sdram_addr = 13'd0;
    bank_addr  = 2'd0;

    dq_out     = 16'd0;
    dq_oe      = 1'b0;

    refresh_done = 1'b0;

    case(state)

        `SDRAM_RESET:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b1;
            cas_n = 1'b1;
            we_n  = 1'b1;
        end

        `SDRAM_PRECHARGE:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b0;
            cas_n = 1'b1;
            we_n  = 1'b0;
            sdram_addr[10] = 1'b1;
        end

        `SDRAM_REFRESH1,
        `SDRAM_REFRESH2:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b0;
            cas_n = 1'b0;
            we_n  = 1'b1;

            if(state == `SDRAM_REFRESH2 && timer_done)
                refresh_done = 1'b1;
        end

        `SDRAM_MODE:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b0;
            cas_n = 1'b0;
            we_n  = 1'b0;

            sdram_addr =
            {
                3'b000,
                3'd3,
                1'b0,
                3'b010
            };
        end

        `SDRAM_IDLE:
        begin
            // No transaction in flight here; `ready` (a genuine
        end

        `SDRAM_ACTIVATE:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b0;
            cas_n = 1'b1;
            we_n  = 1'b1;

            sdram_addr = row_address;
            bank_addr  = bank;
        end

        `SDRAM_READ:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b1;
            cas_n = 1'b0;
            we_n  = 1'b1;

            // FIX: hold column_address for the low half, then step to
            if(timing_counter >= (`CAS_LATENCY - 1))
                sdram_addr[8:0] = column_address;
            else
                sdram_addr[8:0] = column_address + 9'd1;

            bank_addr = bank;
        end

        `SDRAM_WRITE:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b1;
            cas_n = 1'b0;
            we_n  = 1'b0;

            // FIX: writes take effect the same cycle the model sees them
            if(!write_half)
                sdram_addr[8:0] = column_address;
            else
                sdram_addr[8:0] = column_address + 9'd1;

            bank_addr = bank;

            dq_oe = 1'b1;
            if(!write_half)
                dq_out = saved_write_data[15:0];
            else
                dq_out = saved_write_data[31:16];

           
        end

        `SDRAM_PRECHARGE_ROW:
        begin
            cs_n  = 1'b0;
            ras_n = 1'b0;
            cas_n = 1'b1;
            we_n  = 1'b0;
        end

        default:
        begin
            // NOP
        end

    endcase



end

// `ready` -- genuine one-shot completion pulse

always @(posedge clk or posedge rst)
begin

    if(rst)

        ready <= 1'b0;

    else

        ready <= (state == `SDRAM_PRECHARGE_ROW) && timer_done;

end

endmodule

`include "sdram_pkg.vh"

module sdram_top #(
    parameter MODEL_DEPTH = 32768     // halfwords allocated in sdram_model
)(

    // Clock / Reset

    input wire clk,
    input wire rst,

    // CPU Interface

    input wire read_req,
    input wire write_req,

    input wire [31:0] address,
    input wire [31:0] write_data,

    output wire [31:0] read_data,

    output wire ready

);

// Internal Signals

wire refresh_request;
wire refresh_done;

wire [3:0] state;
wire [3:0] next_state;

wire timer_done;
wire op_is_read;

// SDRAM Physical Interface (internal only -- no longer external

wire cs_n;
wire ras_n;
wire cas_n;
wire we_n;

wire [12:0] sdram_addr;
wire [1:0]  bank_addr;

wire [15:0] dq_out;
wire [15:0] dq_in;

wire dq_oe;

// Refresh Controller

refresh_controller REFRESH(
    .clk(clk),
    .rst(rst),
    .refresh_done(refresh_done),
    .refresh_request(refresh_request)
);

// SDRAM FSM

sdram_fsm FSM(
    .clk(clk),
    .rst(rst),

    .start_read(read_req),
    .start_write(write_req),

    .refresh_request(refresh_request),

    .timer_done(timer_done),
    .op_is_read(op_is_read),

    .state(state),
    .next_state(next_state)
);

// SDRAM Controller

sdram_controller CONTROLLER(
    .clk(clk),
    .rst(rst),

    // CPU

    .read_req(read_req),
    .write_req(write_req),

    .address(address),
    .write_data(write_data),

    .read_data(read_data),

    .ready(ready),

    // Refresh

    .refresh_request(refresh_request),
    .refresh_done(refresh_done),

    // FSM

    .state(state),
    .next_state(next_state),

    .timer_done(timer_done),
    .op_is_read(op_is_read),

    // SDRAM Pins (now internal wires, connected to sdram_model below

    .cs_n(cs_n),
    .ras_n(ras_n),
    .cas_n(cas_n),
    .we_n(we_n),

    .sdram_addr(sdram_addr),
    .bank_addr(bank_addr),

    .dq_out(dq_out),
    .dq_in(dq_in),

    .dq_oe(dq_oe)
);

// SDRAM Memory Device

sdram_model #(
    .DEPTH(MODEL_DEPTH)
) MEMORY(
    .clk(clk),

    .cs_n(cs_n),
    .ras_n(ras_n),
    .cas_n(cas_n),
    .we_n(we_n),

    .addr(sdram_addr),
    .bank(bank_addr),

    .dq_in(dq_out),
    .dq_out(dq_in),

    .dq_oe(dq_oe)
);

endmodule

`include "sdram_pkg.vh"

module sdram_model #(
    parameter DEPTH = 32768           // riscv-soc-fir-hls: allocated halfwords
)(

    // Clock

    input wire clk,

    // SDRAM Commands

    input wire cs_n,
    input wire ras_n,
    input wire cas_n,
    input wire we_n,

    // Address

    input wire [12:0] addr,

    input wire [1:0] bank,

    // Data Bus

    input wire [15:0] dq_in,

    output reg [15:0] dq_out,

    input wire dq_oe

);
  
// SDRAM Memory

// riscv-soc-fir-hls: full geometry would be
localparam SDRAM_DEPTH = DEPTH;

reg [15:0] memory [0:SDRAM_DEPTH-1];

// Active Row (riscv-soc-fir-hls: declared before first use; the original

reg [12:0] active_row;
reg [1:0] active_bank;
reg row_open;

// Physical SDRAM Address

wire [23:0] memory_index;

assign memory_index =
    {
        active_bank,
        active_row,
        addr[8:0]
    };

wire in_range = ({8'd0, memory_index} < SDRAM_DEPTH);
  
// Initialize

integer i;

initial
begin

    row_open = 1'b0;

    dq_out = 16'd0;

    for(i = 0; i < SDRAM_DEPTH; i = i + 1)

        memory[i]=16'd0;

end
// Command Decode

always @(posedge clk)
begin

    if(!cs_n)
    begin

        // ACTIVE

if(!ras_n && cas_n && we_n)
begin

    active_row  <= addr;
    active_bank <= bank;

    row_open <= 1'b1;

end
        // READ

        else if(ras_n && !cas_n && we_n)
        begin

            if(row_open) begin
                if (in_range)
                    dq_out <= memory[memory_index];
                else begin
                    dq_out <= 16'hxxxx;
                    $display("** Error: sdram_model read outside DEPTH, index %0d (%m)", memory_index);
                end
            end

        end

        // WRITE

        else if(ras_n && !cas_n && !we_n)
        begin

            if(row_open && dq_oe) begin
                if (in_range)
                    memory[memory_index] <= dq_in;
                else
                    $display("** Error: sdram_model write outside DEPTH, index %0d (%m)", memory_index);
            end

        end

        // PRECHARGE

        else if(!ras_n && cas_n && !we_n)
        begin

            row_open <= 1'b0;

        end

    end

end
endmodule
