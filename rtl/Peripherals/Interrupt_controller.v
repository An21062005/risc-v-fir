`timescale 1ns/1ps
`include "interrupt_pkg.vh"

// Điều khiển IRQ Timer/FIR: giữ pending, chọn ưu tiên và xử lý claim/ACK.

module interrupt_controller(

    // Clock / Reset

    input wire clk,
    input wire rst,

    // Raw Interrupt Inputs

    input wire [`NUM_INTERRUPTS-1:0] irq_in,

    // Interrupt Enable Mask

    input wire [`NUM_INTERRUPTS-1:0] irq_enable,

    // CPU Acknowledge

    input wire ack,

    input wire [`INT_ID_WIDTH-1:0] ack_id,   // nguồn cần xóa khi ack=1 (thêm mới)

    input wire claim,                        // FIX I1: CPU đọc STATUS ở chu kỳ này

    // Pending Interrupts

    output reg [`NUM_INTERRUPTS-1:0] pending,

    // CPU Interrupt Output

    output reg interrupt,

    output reg [`INT_ID_WIDTH-1:0] interrupt_id

);


    // Previous IRQ State

    reg [`NUM_INTERRUPTS-1:0] irq_in_d;


    // Rising Edge Detection

    wire [`NUM_INTERRUPTS-1:0] irq_rising;

    assign irq_rising =
        irq_in & ~irq_in_d;


    // IRQ Input History

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            irq_in_d <=
                {`NUM_INTERRUPTS{1'b0}};

        end

        else begin

            irq_in_d <= irq_in;

        end

    end


    // Pending Register

    integer i;

    // FIX I1: newer[i] = cạnh mới đến khi pending[i] đã = 1, sau lần CPU đọc STATUS
    reg [`NUM_INTERRUPTS-1:0] newer;
    integer r;
    always @(posedge clk or posedge rst) begin
        if (rst)
            newer <= {`NUM_INTERRUPTS{1'b0}};
        else
            for (r = 0; r < `NUM_INTERRUPTS; r = r + 1)
                if (irq_rising[r] && pending[r])
                    newer[r] <= 1'b1;
                else if ((ack && (ack_id == r)) ||
                         (claim && interrupt && (interrupt_id == r)))
                    newer[r] <= 1'b0;
    end

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            pending <=
                {`NUM_INTERRUPTS{1'b0}};

        end

        else begin

            for (i = 0;
                 i < `NUM_INTERRUPTS;
                 i = i + 1) begin


                // NEW INTERRUPT

                if (irq_rising[i]) begin

                    pending[i] <= 1'b1;

                end


                // ACKNOWLEDGE

                else if (
                    ack &&
                    (ack_id == i)          // trước đây: interrupt && (interrupt_id == i)
                ) begin

                    pending[i] <= newer[i] & irq_in[i];   // FIX I1

                end

            end

        end

    end


    // Active Interrupts

    wire [`NUM_INTERRUPTS-1:0] active;

    assign active =
        pending & irq_enable;


    // Fixed Priority Encoder

    integer j;

    always @(*) begin

        interrupt = 1'b0;

        interrupt_id =
            {`INT_ID_WIDTH{1'b0}};


        // Scan from LOW priority to HIGH priority.

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

// INTERRUPT TOP

module interrupt_top(

    // Clock / Reset

    input wire clk,
    input wire rst,

    // Raw IRQ Inputs

    input wire [`NUM_INTERRUPTS-1:0] irq_in,

    // Enable

    input wire [`NUM_INTERRUPTS-1:0] irq_enable,

    // Acknowledge

    input wire ack,

    // Status

    output wire [`NUM_INTERRUPTS-1:0] pending,

    // CPU Interrupt

    output wire interrupt,

    output wire [`INT_ID_WIDTH-1:0] interrupt_id

);


    // Interrupt Controller

    interrupt_controller CTRL (

        .clk(clk),

        .rst(rst),

        .irq_in(irq_in),

        .irq_enable(irq_enable),

        .ack(ack),

        .ack_id(interrupt_id),   // giữ hành vi gốc của interrupt_top

        .claim(1'b0),

        .pending(pending),

        .interrupt(interrupt),

        .interrupt_id(interrupt_id)

    );


endmodule