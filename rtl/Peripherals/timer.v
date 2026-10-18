`timescale 1ns/1ps
//--------------------------------------------------------------------------
// timer : tách nguyên văn từ rtl/Peripherals/peripheral.v của tiny-riscv-soc (MIT).
// riscv-soc-fir-hls chỉ dùng timer; gpio, uart, data_ram, instruction_rom
// trong peripheral.v gốc không dùng nên không đưa vào dự án.
// Hành vi (đọc từ mã): 1 thanh ghi duy nhất. Ghi = nạp compare và bắt đầu đếm;
// đọc = timer_count; irq = xung 1 chu kỳ khi count >= compare, rồi tự dừng.
//--------------------------------------------------------------------------
`include "soc_pkg.vh"

module timer #(

    parameter WIDTH = `DATA_WIDTH

)(

    input  wire                 clk,
    input  wire                 rst_n,

    //---------------------------------------------------------
    // AXI-Lite Interface
    //---------------------------------------------------------

    input  wire                 wr_en,
    input  wire                 rd_en,
    input  wire [WIDTH-1:0]     wdata,

    output reg  [WIDTH-1:0]     rdata,

    //---------------------------------------------------------
    // Timer Interrupt
    //---------------------------------------------------------

    output reg                  irq

);

    //---------------------------------------------------------
    // Timer Registers
    //---------------------------------------------------------

    reg [WIDTH-1:0] timer_count;
    reg [WIDTH-1:0] timer_compare;
    reg             timer_enable;

    //---------------------------------------------------------
    // Write Logic
    //---------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            timer_compare <= {WIDTH{1'b0}};
            timer_enable  <= 1'b0;

        end

        else begin

            if (wr_en) begin

                timer_compare <= wdata;
                timer_enable  <= 1'b1;


            end

            else if (timer_enable &&
              (timer_count >= timer_compare)) begin

                timer_enable <= 1'b0;

            end

        end

    end

    //---------------------------------------------------------
    // Counter Logic
    //---------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n)

            timer_count <= {WIDTH{1'b0}};

        else if (timer_enable)

            timer_count <= timer_count + 1'b1;

        else

            timer_count <= {WIDTH{1'b0}};

    end

    //---------------------------------------------------------
    // Interrupt Logic
    //---------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

     if (!rst_n)

         irq <= 1'b0;

     else if (timer_enable &&
              (timer_count >= timer_compare))

         irq <= 1'b1;

     else

         irq <= 1'b0;

    end

//---------------------------------------------------------
// Read Logic
//---------------------------------------------------------

always @(posedge clk or negedge rst_n) begin

    if (!rst_n)

        rdata <= {WIDTH{1'b0}};

    else if (rd_en)

        rdata <= timer_count;

end



endmodule
