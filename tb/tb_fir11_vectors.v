`timescale 1ns/1ps

//======================================================================
// tb_fir11_vectors : kiểm chứng fir11_wrapper + FIR11 HLS thật bằng 6 bộ
//                    vector tham chiếu trong data_test/fir_test/output/
//======================================================================
// Mỗi test <name> (1000 mẫu, số nguyên thập phân có dấu, 1 mẫu/dòng):
//   <VEC_DIR>/<name>/input.dat     x[n]
//   <VEC_DIR>/<name>/expected.dat  y[n] = sum c[k]*x[n-k], lịch sử = 0, wrap 32-bit
//   -> ghi <OUT_DIR>/<name>/actual.dat (DATA_OUT đọc được, cùng định dạng)
//
// Trình tự mỗi test:
//   1. Xả lịch sử: 10 giao dịch x = 0 qua wrapper (kiểm giao thức, bỏ output).
//      KHÔNG dựa vào ap_rst: shift_reg của IP nằm trong RAM, ap_rst không xóa.
//      Kiểm thêm (white-box) ram[0..9] của shift_reg_U = 0 sau khi xả.
//   2. Mỗi mẫu = một giao dịch hoàn chỉnh (fir_txn):
//        STATUS == IDLE (không busy/done/overrun)  -> không gửi khi BUSY
//        ghi DATA_IN; đúng 1 lần wrapper nhận mẫu
//        STATUS: busy=1, done=0
//        poll STATUS tới done=1 (timeout MAX_POLL lần đọc); khi done: busy=0,
//          overrun=0, irq=1; đúng 1 ap_done của IP cho giao dịch này
//        đọc DATA_OUT; irq về 0
//      Output ghép với input theo giao dịch vừa hoàn tất (không dò độ trễ).
//      Monitor độc lập chốt (x_q, y) ở chu kỳ y_ap_vld để đối chiếu cặp.
//   3. So sánh chính xác 32 bit với expected.dat; sai -> in test, n, x, exp, act.
//
// Plusargs: +VEC_DIR=<thư mục output của generator>  (mặc định ../../data_test/fir_test/output)
//           +OUT_DIR=<thư mục ghi actual.dat>          (mặc định .; cần có sẵn <OUT_DIR>/<name>/)
// Hai file ROM/RAM .dat của HLS phải nằm ở thư mục làm việc của simulator
// (scripts/prep_fir11_dat.sh hoặc scripts/run_rtl_tests.py tự chép).
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_fir11_vectors
//======================================================================

module tb_fir11_vectors;

    localparam [31:0] A_DATA_IN  = 32'h0000_0200;
    localparam [31:0] A_DATA_OUT = 32'h0000_0204;
    localparam [31:0] A_STATUS   = 32'h0000_0208;

    localparam [31:0] ST_DONE    = 32'h01;
    localparam [31:0] ST_IDLE    = 32'h02;
    localparam [31:0] ST_BUSY    = 32'h08;
    localparam [31:0] ST_OVERRUN = 32'h10;

    localparam TAPS        = 11;
    localparam HIST        = TAPS - 1;   // 10 mẫu lịch sử
    localparam NUM_SAMPLES = 1000;
    localparam NUM_TESTS   = 6;
    localparam MAX_POLL    = 100;        // lần đọc STATUS tối đa mỗi giao dịch
    localparam MAX_SHOW    = 20;         // số dòng lệch in chi tiết mỗi test
    localparam CLK_PERIOD  = 10;

    //------------------------------------------------------------
    // DUT
    //------------------------------------------------------------

    reg         clk;
    reg         rst_n;
    reg         wr_en;
    reg         rd_en;
    reg  [31:0] wr_addr;
    reg  [31:0] rd_addr;
    reg  [31:0] wdata;
    wire [31:0] rdata;
    wire        irq;

    fir11_wrapper dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (wr_en),
        .rd_en   (rd_en),
        .wr_addr (wr_addr),
        .rd_addr (rd_addr),
        .wdata   (wdata),
        .rdata   (rdata),
        .irq     (irq)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    //------------------------------------------------------------
    // Scoreboard helpers (protocol checks)
    //------------------------------------------------------------

    integer errors;
    integer checks;

    task check_eq;
        input [31:0]  got;
        input [31:0]  exp;
        input [255:0] what;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s: got 0x%08h, exp 0x%08h", $time, what, got, exp);
            end
        end
    endtask

    //------------------------------------------------------------
    // Monitors (hierarchical refs into wrapper / HLS IP)
    //------------------------------------------------------------

    integer    n_accept;       // DATA_IN accepted by the wrapper
    integer    n_ip_done;      // ap_done of the IP while ap_rst = 0
    integer    n_overrun_wr;   // DATA_IN writes while busy (must stay 0)
    reg [31:0] mon_x;          // x_q latched by the IP at y_ap_vld
    reg [31:0] mon_y;          // y produced by the IP at y_ap_vld

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.accept)
                n_accept = n_accept + 1;
            if (!dut.ap_rst && dut.ap_done)
                n_ip_done = n_ip_done + 1;
            if (dut.wr_data_in && dut.busy_q)
                n_overrun_wr = n_overrun_wr + 1;
            if (dut.hls_y_take) begin
                mon_x = dut.x_q;
                mon_y = dut.hls_y;
            end
        end
    end

    //------------------------------------------------------------
    // Bus model (same timing as tb_fir11_wrapper / axi_interconnect)
    //------------------------------------------------------------

    task bus_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = addr;
            wdata   = data;
            @(negedge clk);
            wr_en   = 1'b0;
        end
    endtask

    task bus_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            rd_en   = 1'b1;           // READ_DATA
            rd_addr = addr;
            @(negedge clk);
            rd_en   = 1'b0;           // snapshot is now registered
            data    = rdata;
            @(negedge clk);           // READ_RESP
        end
    endtask

    task idle_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    //------------------------------------------------------------
    // One complete FIR transaction through the wrapper registers
    //------------------------------------------------------------

    reg [31:0] txn_y;
    reg        txn_ok;           // 0: timeout / protocol failure in this txn
    integer    txn_polls;

    task fir_txn;
        input [31:0] x;
        reg   [31:0] st;
        integer      acc0, done0, err0;
        begin
            err0   = errors;
            txn_ok = 1'b1;
            txn_y  = 32'hxxxx_xxxx;

            // never write DATA_IN while BUSY in normal data verification
            bus_read(A_STATUS, st);
            check_eq(st, ST_IDLE, "STATUS idle before DATA_IN");
            if (st & ST_BUSY) begin
                $display("[%0t] ERROR BUSY before DATA_IN, sample not sent", $time);
                errors = errors + 1;
                txn_ok = 1'b0;
            end

            if (txn_ok) begin
                acc0  = n_accept;
                done0 = n_ip_done;
                bus_write(A_DATA_IN, x);
                check_eq(n_accept - acc0, 1, "one accept per DATA_IN");

                bus_read(A_STATUS, st);
                check_eq(st & (ST_BUSY | ST_DONE | ST_OVERRUN), ST_BUSY,
                         "STATUS busy, not done, no overrun after DATA_IN");

                txn_polls = 0;
                while (!(st & ST_DONE) && txn_polls < MAX_POLL) begin
                    bus_read(A_STATUS, st);
                    txn_polls = txn_polls + 1;
                    check_eq(st & ST_OVERRUN, 32'd0, "no overrun while polling");
                end

                if (!(st & ST_DONE)) begin
                    errors = errors + 1;
                    txn_ok = 1'b0;
                    $display("[%0t] ERROR TIMEOUT: DONE not set after %0d STATUS polls (x=%0d)",
                             $time, MAX_POLL, $signed(x));
                end else begin
                    check_eq(st & (ST_BUSY | ST_OVERRUN), 32'd0, "STATUS busy=0 overrun=0 at done");
                    check_eq(irq, 1'b1, "irq high while done");
                    check_eq(n_ip_done - done0, 1, "one ap_done per DATA_IN");
                    bus_read(A_DATA_OUT, txn_y);
                    check_eq(irq, 1'b0, "irq cleared by DATA_OUT read");
                    check_eq(mon_x, x, "IP x_q at y_ap_vld == sample sent");
                    check_eq(txn_y, mon_y, "DATA_OUT == IP y at y_ap_vld");
                end
            end
            if (errors != err0)
                txn_ok = 1'b0;
        end
    endtask

    //------------------------------------------------------------
    // Vector files
    //------------------------------------------------------------

    reg [8*512-1:0] vec_dir;
    reg [8*512-1:0] out_dir;
    reg [8*600-1:0] path;

    integer vec_x   [0:NUM_SAMPLES-1];
    integer vec_y   [0:NUM_SAMPLES-1];

    // Read NUM_SAMPLES signed decimal integers; returns count read, -1 on open error.
    task read_vec;
        input  [8*600-1:0] fname;
        input              is_expected;
        output integer     count;
        integer fd, code, v;
        begin
            count = 0;
            fd = $fopen(fname, "r");
            if (fd == 0) begin
                count = -1;
            end else begin
                code = $fscanf(fd, " %d", v);
                while (code == 1) begin
                    if (count < NUM_SAMPLES) begin
                        if (is_expected) vec_y[count] = v;
                        else             vec_x[count] = v;
                    end
                    count = count + 1;
                    code = $fscanf(fd, " %d", v);
                end
                $fclose(fd);
            end
        end
    endtask

    //------------------------------------------------------------
    // Run one vector test
    //------------------------------------------------------------

    integer total_match;
    integer total_samples;
    integer tests_pass;

    task run_vector_test;
        input [8*32-1:0] name;
        integer    n, nx, ny, fa, mism, shown, k, err0;
        reg        file_ok;
        reg [31:0] y;
        begin
            err0    = errors;
            file_ok = 1'b1;
            mism    = 0;
            shown   = 0;
            $display("[%0t] INFO VEC %0s: start", $time, name);

            $sformat(path, "%0s/%0s/input.dat", vec_dir, name);
            read_vec(path, 1'b0, nx);
            if (nx != NUM_SAMPLES) begin
                $display("ERROR %0s: %0s -> %0d samples (need %0d, -1 = cannot open)",
                         name, path, nx, NUM_SAMPLES);
                errors = errors + 1; file_ok = 1'b0;
            end
            $sformat(path, "%0s/%0s/expected.dat", vec_dir, name);
            read_vec(path, 1'b1, ny);
            if (ny != NUM_SAMPLES) begin
                $display("ERROR %0s: %0s -> %0d samples (need %0d, -1 = cannot open)",
                         name, path, ny, NUM_SAMPLES);
                errors = errors + 1; file_ok = 1'b0;
            end
            $sformat(path, "%0s/%0s/actual.dat", out_dir, name);
            fa = $fopen(path, "w");
            if (fa == 0) begin
                $display("ERROR %0s: cannot create %0s", name, path);
                errors = errors + 1; file_ok = 1'b0;
            end

            if (file_ok) begin
                // 1. flush the 10-sample history with zeros, outputs discarded
                for (k = 0; k < HIST; k = k + 1)
                    fir_txn(32'd0);
                for (k = 0; k < HIST; k = k + 1)
                    check_eq(dut.u_fir11.grp_fir_Pipeline_Shift_Accum_Loop_fu_55.shift_reg_U.ram[k],
                             32'd0, "shift_reg history zero after flush");

                // 2./3. data samples
                for (n = 0; n < NUM_SAMPLES; n = n + 1) begin
                    fir_txn(vec_x[n]);
                    y = txn_y;
                    $fdisplay(fa, "%0d", $signed(y));
                    if (y !== vec_y[n]) begin
                        mism = mism + 1;
                        if (shown < MAX_SHOW) begin
                            shown = shown + 1;
                            $display("ERROR MISMATCH test=%0s n=%0d input=%0d expected=%0d actual=%0d (0x%08h)",
                                     name, n, vec_x[n], vec_y[n], $signed(y), y);
                        end
                    end
                end
                $fclose(fa);
                if (mism > shown)
                    $display("ERROR %0s: %0d more mismatches not printed (all counted)",
                             name, mism - shown);
            end else begin
                mism = NUM_SAMPLES;
                if (fa != 0) $fclose(fa);
            end

            total_samples = total_samples + NUM_SAMPLES;
            total_match   = total_match + (NUM_SAMPLES - mism);
            if (mism == 0 && errors == err0) begin
                tests_pass = tests_pass + 1;
                $display("INFO VEC %0s: PASS %0d/%0d samples match", name, NUM_SAMPLES - mism, NUM_SAMPLES);
            end else begin
                $display("INFO VEC %0s: FAIL %0d/%0d samples match, %0d protocol errors",
                         name, NUM_SAMPLES - mism, NUM_SAMPLES, errors - err0);
            end
        end
    endtask

    //------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------

    integer i;
    integer c_exp [0:TAPS-1];

    initial begin : watchdog
        #50_000_000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

    initial begin
        errors = 0; checks = 0;
        n_accept = 0; n_ip_done = 0; n_overrun_wr = 0;
        mon_x = 32'd0; mon_y = 32'd0;
        total_match = 0; total_samples = 0; tests_pass = 0;
        wr_en = 1'b0; rd_en = 1'b0; wr_addr = 32'd0; rd_addr = 32'd0; wdata = 32'd0;

        if (!$value$plusargs("VEC_DIR=%s", vec_dir))
            vec_dir = "../../data_test/fir_test/output";
        if (!$value$plusargs("OUT_DIR=%s", out_dir))
            out_dir = ".";
        $display("INFO VEC VEC_DIR=%0s", vec_dir);
        $display("INFO VEC OUT_DIR=%0s", out_dir);

        // ROM .dat must be in the simulator working directory (content not modified)
        c_exp[0] = 54;  c_exp[1] = 0; c_exp[2] = -92; c_exp[3] = 0; c_exp[4] = 313;
        c_exp[5] = 500; c_exp[6] = 313; c_exp[7] = 0; c_exp[8] = -92; c_exp[9] = 0; c_exp[10] = 54;

        rst_n = 1'b0;
        idle_cycles(5);
        for (i = 0; i < TAPS; i = i + 1)
            check_eq(dut.u_fir11.grp_fir_Pipeline_Shift_Accum_Loop_fu_55.fir_int_int_c_U.rom0[i],
                     c_exp[i], "ROM coefficient (.dat loaded?)");
        for (i = 0; i < TAPS; i = i + 1)
            check_eq(dut.u_fir11.grp_fir_Pipeline_Shift_Accum_Loop_fu_55.shift_reg_U.ram[i],
                     32'd0, "shift_reg RAM initial (.dat loaded?)");
        if (errors != 0) begin
            $display("TEST FAILED: HLS ROM/RAM .dat not loaded, run scripts/prep_fir11_dat.sh <sim dir>");
            $finish;
        end

        @(negedge clk);
        rst_n = 1'b1;
        idle_cycles(3);

        run_vector_test("test_01_low");
        run_vector_test("test_02_high");
        run_vector_test("test_03_mixed");
        run_vector_test("test_04_noise");
        run_vector_test("test_05_impulse");
        run_vector_test("test_06_step");

        check_eq(n_overrun_wr, 0, "no DATA_IN write while busy");
        check_eq(n_accept, n_ip_done, "accepts == IP completions");
        check_eq(n_accept, NUM_TESTS * (NUM_SAMPLES + HIST), "total transactions");

        idle_cycles(5);
        $display("INFO VEC TOTAL: %0d/%0d tests PASS, %0d/%0d samples match, %0d mismatch",
                 tests_pass, NUM_TESTS, total_match, total_samples, total_samples - total_match);
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0 && total_match == NUM_TESTS * NUM_SAMPLES && tests_pass == NUM_TESTS)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d errors, %0d sample mismatches)",
                     errors, total_samples - total_match);
        $finish;
    end

endmodule
