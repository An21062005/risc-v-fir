`timescale 1ns/1ps

//======================================================================
// tb_cpu_firmware : CPU RISC-V chạy firmware C do GCC biên dịch
//======================================================================
// Firmware: firmware/main.c + startup.S + linker.ld, build bằng
//   python scripts/build_firmware.py  -> firmware/build/program.mem, data.mem
// IMEM/DMEM của CPU tự nạp program.mem / data.mem bằng $readmemh ("./<tên>",
// thư mục làm việc của simulator). Testbench KHÔNG ghi lệnh vào IMEM; nó đọc
// lại 2 file đó vào mảng riêng để kiểm tra image đã được nạp và không bị sửa.
//
// SoC thật: soc_top cấu hình mặc định (A: CPU + AXI + Timer + IRQ + FIR11),
// clock 100 MHz, rst_n mức thấp.
//
// Signature (firmware/main.c, struct sig tại 0x1000_0000 = DMEM word 0):
//   [0] status  [1] halt  [2] exit_code  [3] checks_total  [4] checks_failed
//   [5] first_failed  [6..17] result[0..11]
// Hoàn tất khi startup.S ghi halt = "HALT" sau khi main trả về.
// PASS chỉ khi: status = PASS, exit_code = 0, 12/12 check của firmware đạt,
//   12 kết quả khớp giá trị testbench tính độc lập, image IMEM/DMEM nạp đúng,
//   IMEM không đổi, không truy cập bus, không truy cập dữ liệu ngoài DMEM,
//   PC luôn trong IMEM, không lệnh ngoài tập hỗ trợ ở ID, không timeout.
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_cpu_firmware
//======================================================================

module tb_cpu_firmware;

    localparam IMEM_WORDS  = 256;
    localparam DMEM_WORDS  = 256;
    localparam MAX_CYCLES  = 100000;
    localparam NUM_RESULTS = 12;

    localparam [31:0] IMEM_END   = 32'h0000_0400;
    localparam [31:0] DMEM_BASE  = 32'h1000_0000;
    localparam [31:0] DMEM_END   = 32'h1000_0400;
    localparam [31:0] NOP        = 32'h0000_0013;

    localparam [31:0] ST_RUNNING = 32'h5255_4E31;
    localparam [31:0] ST_PASS    = 32'h600D_C0DE;
    localparam [31:0] ST_FAIL    = 32'hBAD0_0000;
    localparam [31:0] HALT_MAGIC = 32'h4841_4C54;   // "HALT"

    localparam W_STATUS = 0, W_HALT = 1, W_EXIT = 2, W_TOTAL = 3, W_FAILED = 4,
               W_FIRST = 5, W_RESULT = 6;

    //------------------------------------------------------------
    // DUT
    //------------------------------------------------------------
    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire cpu_irq;
    always #5 clk = ~clk;

    soc_top dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .cpu_irq (cpu_irq)
    );

    //------------------------------------------------------------
    // Scoreboard
    //------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;

    task check_eq;
        input [31:0]  got;
        input [31:0]  exp;
        input [319:0] what;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: got 0x%08h (%0d), exp 0x%08h (%0d)",
                         what, got, $signed(got), exp, $signed(exp));
            end
        end
    endtask

    function [31:0] sigw;               // đọc signature trực tiếp từ DMEM
        input integer idx;
        begin sigw = dut.u_cpu.DMEM.memory[idx]; end
    endfunction

    //------------------------------------------------------------
    // Tập lệnh CPU giải mã đúng (giống scripts/build_firmware.py)
    //------------------------------------------------------------
    function supported;
        input [31:0] w;
        reg [6:0] op; reg [2:0] f3; reg [6:0] f7;
        begin
            op = w[6:0]; f3 = w[14:12]; f7 = w[31:25];
            case (op)
                7'b0110111, 7'b0010111, 7'b1101111: supported = 1'b1;            // LUI AUIPC JAL
                7'b1100111: supported = (f3 == 3'b000);                          // JALR
                7'b1100011: supported = (f3 == 3'b000) || (f3 == 3'b001) ||
                                        (f3 == 3'b100) || (f3 == 3'b101);        // BEQ BNE BLT BGE
                7'b0000011, 7'b0100011: supported = (f3 == 3'b010);              // LW SW
                7'b0010011: supported = (f3 == 3'b001) ? (f7 == 7'h00) :
                                        (f3 == 3'b101) ? (f7 == 7'h00 || f7 == 7'h20) :
                                        (f3 != 3'b011);                          // không SLTIU
                7'b0110011: supported = (f7 == 7'h00 && f3 != 3'b011) ||         // không SLTU
                                        (f7 == 7'h20 && (f3 == 3'b000 || f3 == 3'b101));
                default:    supported = 1'b0;
            endcase
        end
    endfunction

    //------------------------------------------------------------
    // Image tham chiếu (cùng file CPU nạp)
    //------------------------------------------------------------
    reg [31:0] prog_ref [0:IMEM_WORDS-1];
    reg [31:0] data_ref [0:DMEM_WORDS-1];
    integer    i;

    initial begin
        for (i = 0; i < IMEM_WORDS; i = i + 1) prog_ref[i] = 32'hxxxx_xxxx;
        for (i = 0; i < DMEM_WORDS; i = i + 1) data_ref[i] = 32'hxxxx_xxxx;
        $readmemh("program.mem", prog_ref);
        $readmemh("data.mem", data_ref);
    end

    //------------------------------------------------------------
    // Monitors (sau reset)
    //------------------------------------------------------------
    integer    cycles = 0;
    integer    bus_accesses = 0;
    integer    dmem_range_err = 0;
    integer    pc_range_err = 0;
    integer    illegal_err = 0;
    integer    status_running_seen = 0;
    reg [31:0] last_pc [0:7];           // 8 PC gần nhất ở ID (debug)
    integer    k;

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            for (k = 7; k > 0; k = k - 1) last_pc[k] = last_pc[k-1];
            last_pc[0] = dut.u_cpu.if_id_pc;

            if (dut.u_cpu.pc >= IMEM_END && pc_range_err < 5) begin
                pc_range_err = pc_range_err + 1;
                $display("ERROR [cycle %0d] PC 0x%08h outside 1 KB IMEM", cycles, dut.u_cpu.pc);
            end
            // if_id_reg resets instr_out to 0x00000000 (flush gives NOP): that bubble
            // is only legal in the first cycle after reset.
            if (!supported(dut.u_cpu.if_id_instruction) &&
                !(cycles == 1 && dut.u_cpu.if_id_instruction == 32'd0) && illegal_err < 5) begin
                illegal_err = illegal_err + 1;
                $display("ERROR [cycle %0d] unsupported instruction in ID: PC 0x%08h instr 0x%08h",
                         cycles, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction);
            end
            if ((dut.bus_rd || dut.bus_wr) && bus_accesses < 5) begin
                $display("ERROR [cycle %0d] unexpected bus access: %0s addr 0x%08h (ID PC 0x%08h)",
                         cycles, dut.bus_wr ? "write" : "read", dut.bus_addr, dut.u_cpu.if_id_pc);
            end
            if (dut.bus_rd || dut.bus_wr)
                bus_accesses = bus_accesses + 1;
            if ((dut.u_cpu.dmem_read || dut.u_cpu.dmem_write) &&
                (dut.u_cpu.ex_mem_alu_result < DMEM_BASE || dut.u_cpu.ex_mem_alu_result >= DMEM_END)) begin
                if (dmem_range_err < 5)
                    $display("ERROR [cycle %0d] DMEM %0s at 0x%08h outside window 0x%08h-0x%08h",
                             cycles, dut.u_cpu.dmem_write ? "write" : "read",
                             dut.u_cpu.ex_mem_alu_result, DMEM_BASE, DMEM_END - 1);
                dmem_range_err = dmem_range_err + 1;
            end
            if (sigw(W_STATUS) === ST_RUNNING)
                status_running_seen = 1;
        end
    end

    //------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------
    integer    expected [0:NUM_RESULTS-1];
    integer    done_cycle;
    integer    img_mismatch;
    reg [31:0] snap [0:W_RESULT + NUM_RESULTS - 1];

    task dump_state;
        begin
            $display("  PC = 0x%08h, ID: PC 0x%08h instr 0x%08h, sp = 0x%08h, ra = 0x%08h",
                     dut.u_cpu.pc, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction,
                     dut.u_cpu.RF.registers[2], dut.u_cpu.RF.registers[1]);
            $display("  last 8 ID PCs (0 = bubble): %h %h %h %h %h %h %h %h", last_pc[0], last_pc[1],
                     last_pc[2], last_pc[3], last_pc[4], last_pc[5], last_pc[6], last_pc[7]);
            $display("  signature: status 0x%08h halt 0x%08h exit %0d checks %0d failed %0d first %0d",
                     sigw(W_STATUS), sigw(W_HALT), $signed(sigw(W_EXIT)), sigw(W_TOTAL),
                     sigw(W_FAILED), sigw(W_FIRST));
        end
    endtask

    initial begin : watchdog
        #((MAX_CYCLES + 1000) * 10);
        $display("TEST FAILED: watchdog");
        $finish;
    end

    initial begin
        expected[0]  = 1801;  expected[1]  = 667;   expected[2]  = -667;  expected[3]  = 5050;
        expected[4]  = 6765;  expected[5]  = 30;    expected[6]  = 2000;  expected[7]  = 1781;
        expected[8]  = 2468;  expected[9]  = -78;   expected[10] = 55;    expected[11] = 3;
        for (k = 0; k < 8; k = k + 1) last_pc[k] = 32'd0;

        // readmemh của IMEM/DMEM chạy ở t = 0
        #1;
        // ---- image nạp đúng, đúng file GCC build ----
        if (prog_ref[0] === 32'hxxxx_xxxx || data_ref[0] === 32'hxxxx_xxxx) begin
            $display("TEST FAILED: cannot read program.mem / data.mem in the simulation directory");
            $finish;
        end
        check_eq(prog_ref[0] !== NOP, 1, "program.mem holds firmware (word 0 is not NOP)");
        img_mismatch = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) img_mismatch = img_mismatch + 1;
        check_eq(img_mismatch, 0, "IMEM == program.mem before reset");
        img_mismatch = 0;
        for (i = 0; i < DMEM_WORDS; i = i + 1)
            if (dut.u_cpu.DMEM.memory[i] !== data_ref[i]) img_mismatch = img_mismatch + 1;
        check_eq(img_mismatch, 0, "DMEM == data.mem before reset");
        check_eq(sigw(W_STATUS), 0, "signature.status = 0 before the CPU runs");

        // ---- reset rồi chạy ----
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        while (sigw(W_HALT) !== HALT_MAGIC && cycles < MAX_CYCLES)
            @(negedge clk);
        done_cycle = cycles;

        if (sigw(W_HALT) !== HALT_MAGIC) begin
            errors = errors + 1;
            $display("ERROR TIMEOUT: firmware did not write HALT within %0d cycles (CPU hung or misexecuted)",
                     MAX_CYCLES);
            dump_state;
        end else begin
            $display("INFO firmware HALT after %0d cycles (%0d ns at 100 MHz)", done_cycle, done_cycle * 10);
            // signature phải giữ nguyên sau HALT (CPU đứng ở vòng lặp halt)
            for (i = 0; i < W_RESULT + NUM_RESULTS; i = i + 1) snap[i] = sigw(i);
            repeat (200) @(negedge clk);
            img_mismatch = 0;
            for (i = 0; i < W_RESULT + NUM_RESULTS; i = i + 1)
                if (sigw(i) !== snap[i]) img_mismatch = img_mismatch + 1;
            check_eq(img_mismatch, 0, "signature stable after HALT (CPU parked in halt loop)");
        end

        // ---- signature ----
        check_eq(status_running_seen, 1, "firmware wrote status = RUNNING (main started)");
        check_eq(sigw(W_STATUS), ST_PASS, "signature.status = PASS");
        check_eq(sigw(W_EXIT), 0, "main() returned 0");
        check_eq(sigw(W_TOTAL), NUM_RESULTS, "firmware ran all 12 checks");
        check_eq(sigw(W_FAILED), 0, "firmware: 0 failed checks");
        check_eq(sigw(W_FIRST), 0, "firmware: no first failed check");
        for (i = 0; i < NUM_RESULTS; i = i + 1) begin
            checks = checks + 1;
            if (sigw(W_RESULT + i) !== expected[i]) begin
                errors = errors + 1;
                $display("ERROR result[%0d] (DMEM word %0d): actual %0d (0x%08h), expected %0d",
                         i, W_RESULT + i, $signed(sigw(W_RESULT + i)), sigw(W_RESULT + i), expected[i]);
            end
        end
        $display("INFO results: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 $signed(sigw(6)), $signed(sigw(7)), $signed(sigw(8)), $signed(sigw(9)),
                 $signed(sigw(10)), $signed(sigw(11)), $signed(sigw(12)), $signed(sigw(13)),
                 $signed(sigw(14)), $signed(sigw(15)), $signed(sigw(16)), $signed(sigw(17)));

        // ---- an toàn thực thi ----
        img_mismatch = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) img_mismatch = img_mismatch + 1;
        check_eq(img_mismatch, 0, "IMEM unchanged after the run");
        check_eq(pc_range_err, 0, "PC always inside IMEM");
        check_eq(illegal_err, 0, "no unsupported instruction reached ID");
        check_eq(bus_accesses, 0, "firmware made no peripheral bus access");
        check_eq(dmem_range_err, 0, "all DMEM load/store inside 0x10000000-0x100003FF");

        if (errors != 0) begin
            $display("State at end of test:");
            dump_state;
        end
        $display("Checks: %0d, errors: %0d, cycles to HALT: %0d", checks, errors, done_cycle);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
