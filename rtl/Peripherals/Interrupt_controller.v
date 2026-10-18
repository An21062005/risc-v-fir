`timescale 1ns/1ps
`include "interrupt_pkg.vh"

//======================================================================
// INTERRUPT CONTROLLER
//======================================================================
// NOTE: reviewed cycle-by-cycle against the 7 Phase 6D properties.
// No functional changes needed here - edge detection, sticky pending,
// enable-mask, and fixed-priority encoding all behave correctly.
//
// Thay đổi trong dự án riscv-soc-fir-hls (bản sao, bản gốc giữ nguyên):
//   Thêm cổng ack_id. ACK xóa pending[ack_id] (nguồn do phần mềm chỉ định)
//   thay vì pending[interrupt_id] (nguồn ưu tiên cao nhất TẠI LÚC ACK).
//   Lý do: ISR đọc STATUS thấy FIR (id 1), nếu Timer (id 0) lên trước khi
//   ISR ghi ACK thì bản gốc sẽ xóa nhầm Timer và để lại FIR -> mất ngắt Timer
//   và phục vụ FIR hai lần. Muốn giữ hành vi cũ: nối ack_id = interrupt_id
//   (interrupt_top bên dưới làm đúng như vậy).
//======================================================================

module interrupt_controller(

    //------------------------------------------------------------
    // Clock / Reset
    //------------------------------------------------------------

    input wire clk,
    input wire rst,

    //------------------------------------------------------------
    // Raw Interrupt Inputs
    //------------------------------------------------------------

    input wire [`NUM_INTERRUPTS-1:0] irq_in,

    //------------------------------------------------------------
    // Interrupt Enable Mask
    //------------------------------------------------------------

    input wire [`NUM_INTERRUPTS-1:0] irq_enable,

    //------------------------------------------------------------
    // CPU Acknowledge
    //------------------------------------------------------------

    input wire ack,

    input wire [`INT_ID_WIDTH-1:0] ack_id,   // nguồn cần xóa khi ack=1 (thêm mới)

    //------------------------------------------------------------
    // Pending Interrupts
    //------------------------------------------------------------

    output reg [`NUM_INTERRUPTS-1:0] pending,

    //------------------------------------------------------------
    // CPU Interrupt Output
    //------------------------------------------------------------

    output reg interrupt,

    output reg [`INT_ID_WIDTH-1:0] interrupt_id

);


    //------------------------------------------------------------
    // Previous IRQ State
    //------------------------------------------------------------

    reg [`NUM_INTERRUPTS-1:0] irq_in_d;


    //------------------------------------------------------------
    // Rising Edge Detection
    //------------------------------------------------------------

    wire [`NUM_INTERRUPTS-1:0] irq_rising;

    assign irq_rising =
        irq_in & ~irq_in_d;


    //------------------------------------------------------------
    // IRQ Input History
    //------------------------------------------------------------

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            irq_in_d <=
                {`NUM_INTERRUPTS{1'b0}};

        end

        else begin

            irq_in_d <= irq_in;

        end

    end


    //------------------------------------------------------------
    // Pending Register
    //------------------------------------------------------------
    //
    // New interrupt request:
    //
    //     rising edge -> pending = 1
    //
    // CPU acknowledgement:
    //
    //     ack + selected interrupt -> pending = 0
    //
    // New request has priority over clear.
    //------------------------------------------------------------

    integer i;

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            pending <=
                {`NUM_INTERRUPTS{1'b0}};

        end

        else begin

            for (i = 0;
                 i < `NUM_INTERRUPTS;
                 i = i + 1) begin


                //------------------------------------------------
                // NEW INTERRUPT
                //------------------------------------------------

                if (irq_rising[i]) begin

                    pending[i] <= 1'b1;

                end


                //------------------------------------------------
                // ACKNOWLEDGE
                //------------------------------------------------

                else if (
                    ack &&
                    (ack_id == i)          // trước đây: interrupt && (interrupt_id == i)
                ) begin

                    pending[i] <= 1'b0;

                end

            end

        end

    end


    //------------------------------------------------------------
    // Active Interrupts
    //------------------------------------------------------------

    wire [`NUM_INTERRUPTS-1:0] active;

    assign active =
        pending & irq_enable;


    //------------------------------------------------------------
    // Fixed Priority Encoder
    //------------------------------------------------------------
    //
    // IRQ0 has highest priority.
    //
    // IRQ0 > IRQ1 > IRQ2 > ...
    //------------------------------------------------------------

    integer j;

    always @(*) begin

        interrupt = 1'b0;

        interrupt_id =
            {`INT_ID_WIDTH{1'b0}};


        //--------------------------------------------------------
        // Scan from LOW priority to HIGH priority.
        //
        // Because later assignments overwrite earlier ones,
        // IRQ0 ultimately wins.
        //--------------------------------------------------------

        for (
            j = `NUM_INTERRUPTS - 1;
            j >= 0;
            j = j - 1
        ) begin

            if (active[j]) begin

                interrupt = 1'b1;

                interrupt_id =
                    j[`INT_ID_WIDTH-1:0];

            end

        end

    end


endmodule

`timescale 1ns/1ps
`include "interrupt_pkg.vh"

//======================================================================
// INTERRUPT TOP
//======================================================================

module interrupt_top(

    //------------------------------------------------------------
    // Clock / Reset
    //------------------------------------------------------------

    input wire clk,
    input wire rst,

    //------------------------------------------------------------
    // Raw IRQ Inputs
    //------------------------------------------------------------

    input wire [`NUM_INTERRUPTS-1:0] irq_in,

    //------------------------------------------------------------
    // Enable
    //------------------------------------------------------------

    input wire [`NUM_INTERRUPTS-1:0] irq_enable,

    //------------------------------------------------------------
    // Acknowledge
    //------------------------------------------------------------

    input wire ack,

    //------------------------------------------------------------
    // Status
    //------------------------------------------------------------

    output wire [`NUM_INTERRUPTS-1:0] pending,

    //------------------------------------------------------------
    // CPU Interrupt
    //------------------------------------------------------------

    output wire interrupt,

    output wire [`INT_ID_WIDTH-1:0] interrupt_id

);


    //------------------------------------------------------------
    // Interrupt Controller
    //------------------------------------------------------------

    interrupt_controller CTRL (

        .clk(clk),

        .rst(rst),

        .irq_in(irq_in),

        .irq_enable(irq_enable),

        .ack(ack),

        .ack_id(interrupt_id),   // giữ hành vi gốc của interrupt_top

        .pending(pending),

        .interrupt(interrupt),

        .interrupt_id(interrupt_id)

    );


endmodule