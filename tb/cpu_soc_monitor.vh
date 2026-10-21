//======================================================================
// cpu_soc_monitor.vh : checker dùng chung cho testbench firmware trên soc_top
//======================================================================
// `include bên trong module testbench, SAU instance `soc_top dut`. Gom các
// checker của tb_cpu_fir_stream (Bước 3) và thêm giao diện RAM ngoài.
//
// Testbench include phải khai báo trước:
//   localparam TXN_TIMEOUT, MAX_ERR_MSG, SIG_WORDS
//   reg [31:0] stack_limit, stack_top        (đặt trước khi thả reset)
//   reg        rst_n
//   function   dmem_wr_allowed(input [31:0] a)  -> 1 nếu được ghi DMEM tại a
//              (signature và stack đã được cho phép sẵn ở đây)
//   task       on_txn(input is_wr, input [31:0] addr, input [31:0] data)
//              gọi mỗi khi một giao dịch AXI hoàn tất (B hoặc R), addr = bus
//
// Phân biệt 4 mức của mỗi giao dịch bus:
//   requested : CPU bắt đầu một yêu cầu bus_rd/bus_wr mới (giữ nguyên khi stall
//               không bị đếm lại)
//   accepted  : bắt tay AW / AR ở cổng cpu_axi_master
//   completed : bắt tay B / R
//   responded : CPU nhận bus_ready
// Mỗi giao dịch AXI phải tạo đúng một tác động ở đích:
//   FIR  (bus 0x200-0x23F)    : đúng 1 xung fir_wr_en / fir_rd_en, không chạm RAM
//   RAM  (bus 0x1_0000-0x1_FFFF): đúng 1 yêu cầu ext_ram_read/write tới cache_top
//                               + 1 ext_ram_ready, addr = bus - 0x1_0000, dữ liệu khớp
//   khác: lỗi (firmware chỉ dùng FIR và RAM ngoài)
//======================================================================

    localparam [31:0] MON_IMEM_END  = 32'h0000_0400;
    localparam [31:0] MON_DMEM_BASE = 32'h1000_0000;
    localparam [31:0] MON_DMEM_END  = 32'h1000_0400;
    localparam [31:0] MON_SIG_END   = 32'h1000_0000 + 4 * SIG_WORDS;
    localparam [31:0] MON_FIR_LO    = 32'h0000_0200;
    localparam [31:0] MON_FIR_HI    = 32'h0000_023F;
    localparam [31:0] MON_RAM_LO    = 32'h0001_0000;
    localparam [31:0] MON_RAM_HI    = 32'h0001_FFFF;

    //------------------------------------------------------------
    // Báo lỗi
    //------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;
    integer cycles = 0;
    integer mon_errors = 0;

    task check_eq;
        input [31:0]     got;
        input [31:0]     exp;
        input [8*96-1:0] what;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: got 0x%08h (%0d), exp 0x%08h (%0d)",
                         what, got, $signed(got), exp, $signed(exp));
            end
        end
    endtask

    task mon_fail;
        input [8*96-1:0] what;
        input [31:0]     a;
        input [31:0]     b;
        begin
            mon_errors = mon_errors + 1;
            if (mon_errors <= MAX_ERR_MSG)
                $display("ERROR [cycle %0d] %0s (0x%08h, 0x%08h)", cycles, what, a, b);
        end
    endtask

    function [31:0] sigw;
        input integer idx;
        begin sigw = dut.u_cpu.DMEM.memory[idx]; end
    endfunction

    function is_fir;
        input [31:0] a;
        begin is_fir = (a >= MON_FIR_LO) && (a <= MON_FIR_HI); end
    endfunction

    function is_ram;
        input [31:0] a;
        begin is_ram = (a >= MON_RAM_LO) && (a <= MON_RAM_HI); end
    endfunction

    function supported;                 // giống scripts/build_firmware.py
        input [31:0] w;
        reg [6:0] op; reg [2:0] f3; reg [6:0] f7;
        begin
            op = w[6:0]; f3 = w[14:12]; f7 = w[31:25];
            case (op)
                7'b0110111, 7'b0010111, 7'b1101111: supported = 1'b1;
                7'b1100111: supported = (f3 == 3'b000);
                7'b1100011: supported = (f3 == 3'b000) || (f3 == 3'b001) ||
                                        (f3 == 3'b100) || (f3 == 3'b101);
                7'b0000011, 7'b0100011: supported = (f3 == 3'b010);
                7'b0010011: supported = (f3 == 3'b001) ? (f7 == 7'h00) :
                                        (f3 == 3'b101) ? (f7 == 7'h00 || f7 == 7'h20) :
                                        (f3 != 3'b011);
                7'b0110011: supported = (f7 == 7'h00 && f3 != 3'b011) ||
                                        (f7 == 7'h20 && (f3 == 3'b000 || f3 == 3'b101));
                default:    supported = 1'b0;
            endcase
        end
    endfunction

    //------------------------------------------------------------
    // Trạng thái monitor
    //------------------------------------------------------------
    integer req_n = 0, req_wr_n = 0, req_rd_n = 0;          // requested
    integer aw_n = 0, ar_n = 0, w_n = 0;                    // accepted
    integer b_n = 0, r_n = 0;                               // completed
    integer resp_n = 0, resp_wr_n = 0, resp_rd_n = 0;       // responded (bus_ready)
    integer fir_wr_n = 0, fir_rd_n = 0, other_en_n = 0;
    integer fir_axi_wr_n = 0, fir_axi_rd_n = 0, ram_axi_wr_n = 0, ram_axi_rd_n = 0;
    integer ram_req_wr_n = 0, ram_req_rd_n = 0, ram_done_n = 0;
    integer axi_done_n = 0, txn_timeouts = 0;
    integer req_age = 0, req_age_max = 0;
    integer ram_age = 0, ram_age_max = 0;

    reg        req_open, req_is_wr;
    reg [31:0] req_addr;
    reg        wr_open, rd_open, cur_w_seen;
    reg [31:0] cur_awaddr, cur_wdata, cur_araddr;
    integer    cur_fir_en, cur_ram_req, cur_ram_done;
    reg [31:0] cur_ram_addr, cur_ram_wdata, cur_ram_rdata;
    reg        cur_ram_is_wr;
    reg        ram_open;
    reg [31:0] last_axi_addr, last_axi_rdata;
    reg        last_axi_is_wr;

    integer    dmem_range_err = 0, wr_region_err = 0, pc_range_err = 0, illegal_err = 0;
    integer    irq_seen = 0, sp_err = 0;
    integer    overrun_seen = 0, soft_rst_seen = 0, wr_busy_seen = 0;
    integer    accept_n = 0, hls_done_n = 0, hls_vld_n = 0;
    reg        sp_valid;
    reg [31:0] sp_min;
    reg [31:0] last_pc [0:7];
    integer    mon_k;
    reg [31:0] mon_a;

    initial begin
        req_open = 1'b0; req_is_wr = 1'b0; req_addr = 32'd0;
        wr_open = 1'b0; rd_open = 1'b0; cur_w_seen = 1'b0;
        cur_fir_en = 0; cur_ram_req = 0; cur_ram_done = 0;
        cur_ram_addr = 32'd0; cur_ram_wdata = 32'd0; cur_ram_rdata = 32'd0; cur_ram_is_wr = 1'b0;
        ram_open = 1'b0;
        last_axi_addr = 32'hxxxx_xxxx; last_axi_rdata = 32'hxxxx_xxxx; last_axi_is_wr = 1'b0;
        sp_valid = 1'b0; sp_min = 32'hFFFF_FFFF;
        for (mon_k = 0; mon_k < 8; mon_k = mon_k + 1) last_pc[mon_k] = 32'd0;
    end

    task axi_txn_end;                   // kiểm tác động ở đích của giao dịch vừa xong
        input        is_wr;
        input [31:0] addr;
        input [31:0] data;
        begin
            if (is_fir(addr)) begin
                if (is_wr) fir_axi_wr_n = fir_axi_wr_n + 1; else fir_axi_rd_n = fir_axi_rd_n + 1;
                if (cur_fir_en != 1 || cur_ram_req != 0)
                    mon_fail("FIR transaction: not exactly one fir_*_en / touched RAM (fir_en, ram_req)",
                             cur_fir_en, cur_ram_req);
            end else if (is_ram(addr)) begin
                if (is_wr) ram_axi_wr_n = ram_axi_wr_n + 1; else ram_axi_rd_n = ram_axi_rd_n + 1;
                if (cur_ram_req != 1 || cur_ram_done != 1 || cur_fir_en != 0)
                    mon_fail("RAM transaction: not exactly one ext_ram request + ready (req, done)",
                             cur_ram_req, cur_ram_done);
                else begin
                    if (cur_ram_is_wr !== is_wr || cur_ram_addr !== addr - MON_RAM_LO)
                        mon_fail("ext_ram request addr/dir != AXI (ram addr, axi addr)", cur_ram_addr, addr);
                    if (is_wr && cur_ram_wdata !== data)
                        mon_fail("ext_ram write data != AXI WDATA", cur_ram_wdata, data);
                    if (!is_wr && cur_ram_rdata !== data)
                        mon_fail("AXI RDATA != ext_ram read data", data, cur_ram_rdata);
                end
            end else
                mon_fail("bus transaction outside FIR / external RAM", addr, data);
            on_txn(is_wr, addr, data);
        end
    endtask

    always @(posedge clk) begin
        if (dut.rst_n_sync) begin   // DUT out of reset (S1: 2-cycle synchronizer)
            cycles = cycles + 1;
            for (mon_k = 7; mon_k > 0; mon_k = mon_k - 1) last_pc[mon_k] = last_pc[mon_k-1];
            last_pc[0] = dut.u_cpu.if_id_pc;

            // ---- CPU ----
            if (dut.u_cpu.pc >= MON_IMEM_END && pc_range_err < 5) begin
                pc_range_err = pc_range_err + 1;
                $display("ERROR [cycle %0d] PC 0x%08h outside 1 KB IMEM", cycles, dut.u_cpu.pc);
            end
            if (!supported(dut.u_cpu.if_id_instruction) &&
                !(cycles == 1 && dut.u_cpu.if_id_instruction == 32'd0) && illegal_err < 5) begin
                illegal_err = illegal_err + 1;
                $display("ERROR [cycle %0d] unsupported instruction in ID: PC 0x%08h instr 0x%08h",
                         cycles, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction);
            end
            // startup.S: la sp = auipc + addi -> chỉ kiểm tra từ khi sp đạt __stack_top lần đầu
            if (dut.u_cpu.RF.registers[2] === stack_top) sp_valid = 1'b1;
            if (sp_valid) begin
                if (dut.u_cpu.RF.registers[2] < sp_min) sp_min = dut.u_cpu.RF.registers[2];
                if ((dut.u_cpu.RF.registers[2] < stack_limit || dut.u_cpu.RF.registers[2] > stack_top) &&
                    sp_err < 5) begin
                    sp_err = sp_err + 1;
                    $display("ERROR [cycle %0d] sp 0x%08h outside stack [0x%08h, 0x%08h]", cycles,
                             dut.u_cpu.RF.registers[2], stack_limit, stack_top);
                end
            end
            if (cpu_irq || dut.u_cpu.in_irq) irq_seen = irq_seen + 1;

            // ---- DMEM ----
            mon_a = dut.u_cpu.ex_mem_alu_result;
            if ((dut.u_cpu.dmem_read || dut.u_cpu.dmem_write) &&
                (mon_a < MON_DMEM_BASE || mon_a >= MON_DMEM_END)) begin
                if (dmem_range_err < 5)
                    $display("ERROR [cycle %0d] DMEM %0s at 0x%08h outside window", cycles,
                             dut.u_cpu.dmem_write ? "write" : "read", mon_a);
                dmem_range_err = dmem_range_err + 1;
            end
            if (dut.u_cpu.dmem_write &&
                !((mon_a >= MON_DMEM_BASE && mon_a < MON_SIG_END) ||
                  (mon_a >= stack_limit && mon_a < stack_top) || dmem_wr_allowed(mon_a))) begin
                wr_region_err = wr_region_err + 1;
                if (wr_region_err <= 5)
                    $display("ERROR [cycle %0d] DMEM write 0x%08h outside allowed regions (data 0x%08h)",
                             cycles, mon_a, dut.u_cpu.ex_mem_write_data);
            end

            // ---- FIR wrapper / HLS ----
            if (dut.u_fir.accept) accept_n = accept_n + 1;
            if (dut.u_fir.wr_data_in && dut.u_fir.busy_q) wr_busy_seen = wr_busy_seen + 1;
            if (dut.u_fir.overrun_q)  overrun_seen  = overrun_seen + 1;
            if (dut.u_fir.soft_rst_q) soft_rst_seen = soft_rst_seen + 1;
            if (dut.u_fir.ap_done) begin
                hls_done_n = hls_done_n + 1;
                if (!dut.u_fir.busy_q)
                    mon_fail("HLS ap_done without a transaction in flight", hls_done_n, 0);
            end
            if (dut.u_fir.hls_y_ap_vld) hls_vld_n = hls_vld_n + 1;

            // ---- Interconnect -> ngoại vi thanh ghi ----
            if (dut.timer_wr_en || dut.timer_rd_en || dut.interrupt_wr_en || dut.interrupt_rd_en) begin
                other_en_n = other_en_n + 1;
                mon_fail("timer/interrupt register access", dut.write_addr, dut.read_addr);
            end
            if (dut.fir_wr_en) begin
                fir_wr_n = fir_wr_n + 1;
                cur_fir_en = cur_fir_en + 1;
                if (!wr_open || !cur_w_seen)
                    mon_fail("fir_wr_en outside an AXI write", dut.write_addr, dut.write_data);
                if (dut.write_addr !== cur_awaddr || dut.write_data !== cur_wdata)
                    mon_fail("fir_wr_en addr/data != AXI AW/W", dut.write_addr, dut.write_data);
            end
            if (dut.fir_rd_en) begin
                fir_rd_n = fir_rd_n + 1;
                cur_fir_en = cur_fir_en + 1;
                if (!rd_open)
                    mon_fail("fir_rd_en outside an AXI read", dut.read_addr, 0);
                if (dut.read_addr !== cur_araddr)
                    mon_fail("fir_rd_en read_addr != AXI ARADDR", dut.read_addr, cur_araddr);
            end

            // ---- Interconnect -> RAM ngoài (cổng cpu_* của cache_top) ----
            if ((dut.ext_ram_read || dut.ext_ram_write) && !ram_open) begin
                ram_open = 1'b1;
                ram_age = 0;
                cur_ram_req = cur_ram_req + 1;
                cur_ram_is_wr = dut.ext_ram_write;
                cur_ram_addr = dut.ext_ram_addr;
                cur_ram_wdata = dut.ext_ram_wdata;
                if (dut.ext_ram_write) ram_req_wr_n = ram_req_wr_n + 1; else ram_req_rd_n = ram_req_rd_n + 1;
                if (dut.ext_ram_read && dut.ext_ram_write)
                    mon_fail("ext_ram_read and ext_ram_write together", dut.ext_ram_addr, 0);
                if (!(wr_open || rd_open))
                    mon_fail("ext_ram request outside an AXI transaction", dut.ext_ram_addr, 0);
            end
            if (ram_open) begin
                ram_age = ram_age + 1;
                if (ram_age > ram_age_max) ram_age_max = ram_age;
                if (!dut.ext_ram_ready &&
                    (!(dut.ext_ram_read || dut.ext_ram_write) || dut.ext_ram_addr !== cur_ram_addr ||
                     dut.ext_ram_write !== cur_ram_is_wr || (cur_ram_is_wr && dut.ext_ram_wdata !== cur_ram_wdata)))
                    mon_fail("ext_ram request changed/dropped before ready", dut.ext_ram_addr, cur_ram_addr);
            end
            if (dut.ext_ram_ready) begin
                if (!ram_open)
                    mon_fail("ext_ram_ready without a request", dut.ext_ram_addr, 0);
                else begin
                    ram_done_n = ram_done_n + 1;
                    cur_ram_done = cur_ram_done + 1;
                    cur_ram_rdata = dut.ext_ram_rdata;      // cache mode: valid only this cycle
                end
                ram_open = 1'b0;
            end

            // ---- CPU: requested, giữ ổn định khi stall, timeout ----
            if ((dut.bus_rd || dut.bus_wr) && !req_open) begin
                req_open = 1'b1;
                req_n = req_n + 1;
                if (dut.bus_wr) req_wr_n = req_wr_n + 1; else req_rd_n = req_rd_n + 1;
                req_addr = dut.bus_addr;
                req_is_wr = dut.bus_wr;
                req_age = 0;
            end
            if (req_open) begin
                req_age = req_age + 1;
                if (req_age > req_age_max) req_age_max = req_age;
                if (!(dut.bus_rd || dut.bus_wr) || dut.bus_addr !== req_addr || dut.bus_wr !== req_is_wr)
                    mon_fail("CPU bus request changed/dropped before bus_ready", dut.bus_addr, req_addr);
                if (req_age == TXN_TIMEOUT + 1) begin
                    txn_timeouts = txn_timeouts + 1;
                    $display("ERROR TIMEOUT [cycle %0d] CPU bus %0s 0x%08h not completed within %0d cycles",
                             cycles, req_is_wr ? "write" : "read", req_addr, TXN_TIMEOUT);
                end
            end

            // ---- AXI: accepted (AW/AR), completed (B/R) ----
            if (dut.axi_awvalid && dut.axi_awready) begin
                aw_n = aw_n + 1;
                if (wr_open || rd_open)
                    mon_fail("AW while another AXI transaction is open (duplicate)", dut.axi_awaddr, 0);
                if (!dut.bus_wr || dut.axi_awaddr !== dut.bus_addr)
                    mon_fail("AWADDR != CPU bus write address", dut.axi_awaddr, dut.bus_addr);
                wr_open = 1'b1; cur_w_seen = 1'b0;
                cur_fir_en = 0; cur_ram_req = 0; cur_ram_done = 0;
                cur_awaddr = dut.axi_awaddr;
            end
            if (dut.axi_wvalid && dut.axi_wready) begin
                w_n = w_n + 1;
                if (!wr_open || cur_w_seen)
                    mon_fail("W without matching AW or duplicate W", dut.axi_wdata, 0);
                if (dut.axi_wdata !== dut.bus_wdata || dut.axi_wstrb !== 4'b1111)
                    mon_fail("WDATA/WSTRB != CPU bus write data", dut.axi_wdata, dut.bus_wdata);
                cur_w_seen = 1'b1;
                cur_wdata = dut.axi_wdata;
            end
            if (dut.axi_bvalid && dut.axi_bready) begin
                b_n = b_n + 1;
                if (!wr_open || !cur_w_seen)
                    mon_fail("B without AW/W", 0, 0);
                if (dut.axi_bresp !== 2'b00)
                    mon_fail("BRESP not OKAY", dut.axi_bresp, cur_awaddr);
                wr_open = 1'b0;
                axi_done_n = axi_done_n + 1;
                last_axi_is_wr = 1'b1; last_axi_addr = cur_awaddr;
                axi_txn_end(1'b1, cur_awaddr, cur_wdata);
            end
            if (dut.axi_arvalid && dut.axi_arready) begin
                ar_n = ar_n + 1;
                if (wr_open || rd_open)
                    mon_fail("AR while another AXI transaction is open (duplicate)", dut.axi_araddr, 0);
                if (!dut.bus_rd || dut.axi_araddr !== dut.bus_addr)
                    mon_fail("ARADDR != CPU bus read address", dut.axi_araddr, dut.bus_addr);
                rd_open = 1'b1;
                cur_fir_en = 0; cur_ram_req = 0; cur_ram_done = 0;
                cur_araddr = dut.axi_araddr;
            end
            if (dut.axi_rvalid && dut.axi_rready) begin
                r_n = r_n + 1;
                if (!rd_open)
                    mon_fail("R without AR", dut.axi_rdata, 0);
                if (dut.axi_rresp !== 2'b00)
                    mon_fail("RRESP not OKAY", dut.axi_rresp, cur_araddr);
                rd_open = 1'b0;
                axi_done_n = axi_done_n + 1;
                last_axi_is_wr = 1'b0; last_axi_addr = cur_araddr; last_axi_rdata = dut.axi_rdata;
                axi_txn_end(1'b0, cur_araddr, dut.axi_rdata);
            end

            // ---- CPU: responded (bus_ready = xung mem_ready) ----
            if (dut.bus_ready) begin
                if (!req_open)
                    mon_fail("bus_ready without a CPU bus request", 0, 0);
                else begin
                    resp_n = resp_n + 1;
                    if (dut.bus_wr) resp_wr_n = resp_wr_n + 1; else resp_rd_n = resp_rd_n + 1;
                    if (axi_done_n != resp_n)
                        mon_fail("CPU responses != AXI completions (cpu, axi)", resp_n, axi_done_n);
                    if (dut.bus_addr !== last_axi_addr || dut.bus_wr !== last_axi_is_wr)
                        mon_fail("CPU bus request != last AXI transaction", dut.bus_addr, last_axi_addr);
                    if (dut.bus_rd && dut.bus_rdata !== last_axi_rdata)
                        mon_fail("CPU bus_rdata != AXI RDATA", dut.bus_rdata, last_axi_rdata);
                end
                req_open = 1'b0;
            end
        end
    end

    //------------------------------------------------------------
    // Kiểm tra cuối test và báo cáo
    //------------------------------------------------------------
    task monitor_final_checks;
        begin
            check_eq(mon_errors, 0, "monitor errors (protocol / bus / RAM interface)");
            check_eq(txn_timeouts, 0, "no per-transaction timeout");
            check_eq(aw_n, req_wr_n, "AXI AW accepted == CPU write requests");
            check_eq(w_n, req_wr_n, "AXI W handshakes == CPU write requests");
            check_eq(b_n, req_wr_n, "AXI B completed == CPU write requests");
            check_eq(ar_n, req_rd_n, "AXI AR accepted == CPU read requests");
            check_eq(r_n, req_rd_n, "AXI R completed == CPU read requests");
            check_eq(resp_wr_n, req_wr_n, "CPU write responses (bus_ready) == write requests");
            check_eq(resp_rd_n, req_rd_n, "CPU read responses (bus_ready) == read requests");
            check_eq(fir_wr_n, fir_axi_wr_n, "fir_wr_en pulses == FIR AXI writes");
            check_eq(fir_rd_n, fir_axi_rd_n, "fir_rd_en pulses == FIR AXI reads");
            check_eq(ram_req_wr_n, ram_axi_wr_n, "ext_ram write requests == RAM AXI writes");
            check_eq(ram_req_rd_n, ram_axi_rd_n, "ext_ram read requests == RAM AXI reads");
            check_eq(ram_done_n, ram_axi_wr_n + ram_axi_rd_n, "ext_ram_ready == RAM AXI transactions");
            check_eq(fir_axi_wr_n + ram_axi_wr_n, req_wr_n, "every write went to FIR or RAM");
            check_eq(fir_axi_rd_n + ram_axi_rd_n, req_rd_n, "every read went to FIR or RAM");
            check_eq(other_en_n, 0, "no timer/interrupt register access");
            check_eq(wr_open || rd_open || req_open || ram_open, 0, "no transaction left open");
            check_eq(wr_busy_seen, 0, "no DATA_IN write while FIR BUSY");
            check_eq(overrun_seen, 0, "FIR OVERRUN never set");
            check_eq(soft_rst_seen, 0, "no FIR soft reset");
            check_eq(irq_seen, 0, "no interrupt taken");
            check_eq(pc_range_err, 0, "PC always inside IMEM");
            check_eq(illegal_err, 0, "no unsupported instruction reached ID");
            check_eq(dmem_range_err, 0, "all DMEM load/store inside 0x10000000-0x100003FF");
            check_eq(wr_region_err, 0, "DMEM writes only to signature / allowed data / stack");
            check_eq(sp_valid, 1, "sp set to __stack_top by startup");
            check_eq(sp_err, 0, "sp stayed inside the stack region");
        end
    endtask

    task monitor_report;
        begin
            $display("INFO bus: requested %0d (wr %0d, rd %0d) | AXI accepted AW %0d AR %0d, W %0d | completed B %0d R %0d | CPU responded %0d",
                     req_n, req_wr_n, req_rd_n, aw_n, ar_n, w_n, b_n, r_n, resp_n);
            $display("INFO targets: FIR wr %0d rd %0d (fir_wr_en %0d fir_rd_en %0d) | RAM wr %0d rd %0d (ext_ram req wr %0d rd %0d, ready %0d)",
                     fir_axi_wr_n, fir_axi_rd_n, fir_wr_n, fir_rd_n, ram_axi_wr_n, ram_axi_rd_n,
                     ram_req_wr_n, ram_req_rd_n, ram_done_n);
            $display("INFO latency: longest CPU bus transaction %0d cycles, longest ext_ram request %0d cycles, min sp 0x%08h",
                     req_age_max, ram_age_max, sp_min);
        end
    endtask

    task dump_cpu;
        begin
            $display("  PC = 0x%08h, ID: PC 0x%08h instr 0x%08h, sp = 0x%08h, ra = 0x%08h",
                     dut.u_cpu.pc, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction,
                     dut.u_cpu.RF.registers[2], dut.u_cpu.RF.registers[1]);
            $display("  last 8 ID PCs: %h %h %h %h %h %h %h %h", last_pc[0], last_pc[1],
                     last_pc[2], last_pc[3], last_pc[4], last_pc[5], last_pc[6], last_pc[7]);
            $display("  bus request open %0d age %0d addr 0x%08h", req_open, req_age, req_addr);
        end
    endtask
