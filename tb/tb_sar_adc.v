// =============================================================================
//  tb_sar_adc.v  --  Self-checking testbench for the SAR ADC APB IP
// -----------------------------------------------------------------------------
//  Structure
//     tb  --+-- APB master BFM (tasks apb_write / apb_read)
//           +-- DUT: sar_adc_ip (synthesizable RTL)
//           +-- analog_frontend_model (behavioral cap-DAC + comparator)
//           +-- protocol checker (assertion-style monitors)
//
//  Select the test with +TEST=<name>
//     regress   (default) all functional tests below, self-checking
//     ramp      slow ramp, dumps every code    -> build/<tag>_ramp.txt  (INL/DNL)
//     sine      coherent sine, dumps codes     -> build/<tag>_sine.txt  (FFT/ENOB)
//     trace     one conversion, per-cycle log  -> build/trace.txt
//  Optional: +AVG=<0..3> (ramp/sine), +TAG=<name> (output file prefix), +VCD
//
//  Only top-level DUT nets (dut.busy / dut.done / dut.result) are probed, so the
//  same testbench also runs on the post-synthesis gate-level netlist.
//
//  The functional (regress) tests assume an ideal analog model, i.e. run
//  without +MISMATCH_PPM / +NOISE_UV / +OFFSET_UV.
// =============================================================================
`timescale 1ns/1ps

module tb_sar_adc;

    localparam integer N      = 10;
    localparam real    VREF   = 1.8;
    localparam real    LSB    = VREF / 1024.0;
    localparam real    TCLK   = 20.0;              // 50 MHz

    // register map
    localparam [7:0] R_CTRL = 8'h00, R_STATUS = 8'h04, R_DATA  = 8'h08,
                     R_IRQEN= 8'h0C, R_WINLO  = 8'h10, R_WINHI = 8'h14,
                     R_ID   = 8'h18;
    // CTRL bits
    localparam [31:0] EN = 32'h1, START = 32'h2, CONT = 32'h4, WIN_EN = 32'h8;

    // ---------------------------------------------------------------------
    reg          pclk = 1'b0;
    reg          presetn = 1'b0;
    reg          psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
    reg  [7:0]   paddr = 8'h0;
    reg  [31:0]  pwdata = 32'h0;
    wire [31:0]  prdata;
    wire         pready, pslverr, irq;
    wire         sample;
    wire [N-1:0] dac_code;
    wire         comp;

    real         vin = 0.0;
    reg  [63:0]  vin_bits = 64'h0;

    always #(TCLK/2.0) pclk = ~pclk;

`ifdef GLS                                        // gate-level netlist: no parameters
    sar_adc_ip dut (
`else
    sar_adc_ip #(.N(N)) dut (
`endif
        .pclk(pclk), .presetn(presetn),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata),
        .pready(pready), .pslverr(pslverr),
        .irq(irq),
        .sample_o(sample), .dac_code_o(dac_code), .comp_i(comp)
    );

    analog_frontend_model #(.N(N)) afe (
        .clk(pclk), .vin_bits(vin_bits), .sample(sample),
        .dac_code(dac_code), .comp(comp)
    );

    // ---------------------------------------------------------------------
    //  Bookkeeping
    // ---------------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;

    task check;
        input        cond;
        input [8*80-1:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  ** FAIL @%0t ns: %0s", $time, msg);
            end
        end
    endtask

    task set_vin;
        input real v;
        begin
            vin      = v;
            vin_bits = $realtobits(v);
        end
    endtask

    // ideal transfer function: floor(Vin / LSB), clamped to [0, 2^N-1]
    function integer ideal_code;
        input real v;
        real c;
        begin
            c = v / LSB;
            if (c < 0.0)              ideal_code = 0;
            else if (c >= 1023.0)     ideal_code = 1023;
            else                      ideal_code = $rtoi(c);   // truncation = floor (c >= 0)
        end
    endfunction

    // ---------------------------------------------------------------------
    //  APB3 master BFM
    //  SETUP phase: PSEL=1, PENABLE=0   ACCESS phase: PENABLE=1 (PREADY=1)
    // ---------------------------------------------------------------------
    reg last_slverr;

    task apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge pclk); #1;
            psel = 1; penable = 0; pwrite = 1; paddr = addr; pwdata = data;
            @(posedge pclk); #1;
            penable = 1;
            @(negedge pclk);
            last_slverr = pslverr;
            @(posedge pclk); #1;
            psel = 0; penable = 0; pwrite = 0;
        end
    endtask

    task apb_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(posedge pclk); #1;
            psel = 1; penable = 0; pwrite = 0; paddr = addr;
            @(posedge pclk); #1;
            penable = 1;
            @(negedge pclk);
            data        = prdata;
            last_slverr = pslverr;
            @(posedge pclk); #1;
            psel = 0; penable = 0;
        end
    endtask

    // wait for EOC by polling STATUS (with timeout)
    task wait_eoc;
        reg [31:0] st;
        integer    t;
        begin
            st = 0; t = 0;
            while (!st[1] && t < 2000) begin
                apb_read(R_STATUS, st);
                t = t + 1;
            end
            check(st[1], "timeout waiting for EOC");
        end
    endtask

    // one single-shot conversion through the bus, returns DATA
    task convert;
        input  real    v;
        input  [31:0]  ctrl_extra;
        output integer code;
        reg    [31:0]  d;
        begin
            set_vin(v);
            apb_write(R_CTRL, EN | START | ctrl_extra);
            wait_eoc;
            apb_read(R_DATA, d);
            code = d[N-1:0];
        end
    endtask

    // ---------------------------------------------------------------------
    //  Protocol checker (runs in every test)
    // ---------------------------------------------------------------------
    always @(posedge pclk) if (presetn) begin
        if (sample && !dut.busy) begin
            errors = errors + 1;
            $display("  ** ASSERT @%0t: S/H sampling while core not busy", $time);
        end
        if (psel && penable && !pready) begin
            errors = errors + 1;
            $display("  ** ASSERT @%0t: PREADY low (IP is zero-wait-state)", $time);
        end
    end

    // =====================================================================
    //  TESTS
    // =====================================================================
    reg [31:0] rd;
    integer    code, exp, i, k, t0, t1, cyc;
    real       v, frac;
    integer    seed_tb;

    // ---------------- 1. register access -----------------------------------
    task test_regs;
        begin
            $display("[TEST] register access / reset values / PSLVERR");
            apb_read(R_ID, rd);       check(rd == 32'h0ADC_0100, "ID register");
            apb_read(R_CTRL, rd);     check(rd == 32'h0000_0400, "CTRL reset value (SMP=4)");
            apb_read(R_STATUS, rd);   check(rd == 32'h0,         "STATUS reset value");
            apb_read(R_WINHI, rd);    check(rd == 32'h3FF,       "WIN_HI reset value");

            apb_write(R_WINLO, 32'h155);  apb_read(R_WINLO, rd); check(rd == 32'h155, "WIN_LO r/w");
            apb_write(R_WINHI, 32'h2AA);  apb_read(R_WINHI, rd); check(rd == 32'h2AA, "WIN_HI r/w");
            apb_write(R_IRQEN, 32'h7);    apb_read(R_IRQEN, rd); check(rd == 32'h7,   "IRQ_EN r/w");
            apb_write(R_IRQEN, 32'h0);

            apb_write(R_CTRL, 32'h0000_0835);           // SMP=8 AVG=3 WIN_EN... START=0
            apb_read (R_CTRL, rd); check(rd == 32'h0000_0835, "CTRL r/w");
            apb_write(R_ID, 32'hDEAD_BEEF);
            apb_read (R_ID, rd);   check(rd == 32'h0ADC_0100, "ID is read-only");

            apb_read (8'h40, rd);  check(last_slverr == 1'b1, "PSLVERR on unmapped read");
            apb_write(8'h1C, 0);   check(last_slverr == 1'b1, "PSLVERR on unmapped write");
            apb_read (8'h05, rd);  check(last_slverr == 1'b1, "PSLVERR on unaligned access");
            apb_read (R_DATA, rd); check(last_slverr == 1'b0, "no PSLVERR on valid access");

            apb_write(R_CTRL, 32'h0000_0400);           // back to defaults, disabled
        end
    endtask

    // ---------------- 2. transfer function vs. ideal -------------------------
    task test_transfer;
        integer mism;
        begin
            $display("[TEST] single conversions vs ideal transfer function");
            mism = 0;
            // corner points
            convert(-0.05,              0, code); check(code == 0,    "negative input clamps to 0");
            convert(0.0,                0, code); check(code == 0,    "zero input -> code 0");
            convert(0.5*LSB,            0, code); check(code == 0,    "0.5 LSB -> code 0");
            convert(1.5*LSB,            0, code); check(code == 1,    "1.5 LSB -> code 1");
            convert(511.5*LSB,          0, code); check(code == 511,  "mid-scale - 0.5 LSB -> 511");
            convert(512.5*LSB,          0, code); check(code == 512,  "mid-scale + 0.5 LSB -> 512 (MSB carry)");
            convert(1022.5*LSB,         0, code); check(code == 1022, "1022.5 LSB -> 1022");
            convert(VREF,               0, code); check(code == 1023, "full scale -> 1023");
            convert(VREF + 0.1,         0, code); check(code == 1023, "over-range clamps to 1023");
            // random points (avoid +/-5% of an LSB around a code edge)
            for (i = 0; i < 300; i = i + 1) begin
                k    = {$random(seed_tb)} % 1024;
                frac = 0.05 + 0.9 * (({$random(seed_tb)} % 1000) / 1000.0);
                v    = (k + frac) * LSB;
                convert(v, 0, code);
                exp = ideal_code(v);
                if (code != exp) begin
                    mism = mism + 1;
                    if (mism < 5) $display("    vin=%f got %0d exp %0d", v, code, exp);
                end
            end
            check(mism == 0, "300 random conversions match ideal code");
            $display("        300 random points: %0d mismatches", mism);
        end
    endtask

    // ---------------- 3. sample time & averaging timing ----------------------
    task measure_busy;            // returns busy-high clock cycles in 'cyc'
        input [31:0] ctrl;
        begin
            set_vin(0.9);
            apb_write(R_CTRL, ctrl | EN | START);
            @(posedge dut.busy); t0 = $time;
            @(negedge dut.busy); t1 = $time;
            cyc = (t1 - t0) / TCLK;
            wait_eoc; apb_read(R_DATA, rd);
        end
    endtask

    task test_timing_avg;
        integer smp, a;
        begin
            $display("[TEST] conversion time = AVG x (SMP + N + 1) clocks, averaging result");
            for (a = 0; a < 4; a = a + 1) begin
                for (smp = 1; smp <= 8; smp = smp * 2) begin
                    measure_busy((smp << 8) | (a << 4));
                    check(cyc == (1 << a) * (smp + N + 1), "busy duration");
                    if (cyc != (1 << a) * (smp + N + 1))
                        $display("    AVG=%0d SMP=%0d: %0d cycles, expected %0d", 1<<a, smp, cyc, (1<<a)*(smp+N+1));
                end
            end
            $display("        e.g. SMP=4, AVG=1 -> %0d clocks = %0.0f ns @ 50 MHz (%0.2f MS/s)",
                     4+N+1, (4+N+1)*TCLK, 1000.0/((4+N+1)*TCLK));
            // averaged result equals single result with an ideal (noise-free) AFE
            for (i = 0; i < 20; i = i + 1) begin
                v = ((({$random(seed_tb)} % 1000) + 10) / 1030.0) * VREF;
                v = ($floor(v / LSB) + 0.5) * LSB;
                convert(v, 32'h30, code);              // AVG = 8x
                check(code == ideal_code(v), "8x averaged result == ideal code");
            end
            // rounding: 2x average of codes 100 and 101 = 100.5 -> rounds to 101
            set_vin(100.5*LSB);
            apb_write(R_CTRL, EN | START | (32'h1 << 4));
            @(posedge sample); @(posedge sample);      // 2nd acquisition starts
            #1 set_vin(101.5*LSB);
            wait_eoc; apb_read(R_DATA, rd);
            check(rd[N-1:0] == 101, "2x average of 100,101 rounds to 101");
            // 4x average of 100,101,101,101 = 100.75 -> 101 (truncation would give 100)
            set_vin(100.5*LSB);
            apb_write(R_CTRL, EN | START | (32'h2 << 4));
            @(posedge sample); @(posedge sample);
            #1 set_vin(101.5*LSB);
            wait_eoc; apb_read(R_DATA, rd);
            check(rd[N-1:0] == 101, "4x average of 100,101,101,101 rounds to 101");
        end
    endtask

    // ---------------- 4. window comparator + interrupts -----------------------
    task test_window_irq;
        begin
            $display("[TEST] window comparator, W1C flags, IRQ");
            apb_write(R_STATUS, 32'hE);                 // clear all flags
            apb_write(R_WINLO, 200);
            apb_write(R_WINHI, 800);
            apb_write(R_IRQEN, 32'h2);                  // WIN interrupt only

            convert(500.5*LSB, WIN_EN, code);           // inside window
            apb_read(R_STATUS, rd);
            check(rd[2] == 1'b0, "inside window: WIN flag clear");
            check(irq == 1'b0,   "inside window: no IRQ");

            convert(100.5*LSB, WIN_EN, code);           // below window
            apb_read(R_STATUS, rd);
            check(rd[2] == 1'b1, "below window: WIN flag set");
            check(irq == 1'b1,   "below window: IRQ asserted");
            apb_write(R_STATUS, 32'h4);                 // W1C
            check(irq == 1'b0,   "IRQ deasserted after W1C");

            convert(900.5*LSB, WIN_EN, code);           // above window
            apb_read(R_STATUS, rd);
            check(rd[2] == 1'b1, "above window: WIN flag set");
            apb_write(R_STATUS, 32'h4);

            convert(900.5*LSB, 0, code);                // window disabled
            apb_read(R_STATUS, rd);
            check(rd[2] == 1'b0, "WIN_EN=0: no WIN flag");

            // EOC interrupt, cleared by reading DATA
            apb_write(R_IRQEN, 32'h1);
            set_vin(0.3);
            apb_write(R_CTRL, EN | START);
            @(posedge irq);
            check(1'b1, "EOC IRQ fired");
            apb_read(R_DATA, rd);
            #1 check(irq == 1'b0, "EOC IRQ cleared by DATA read");
            apb_write(R_IRQEN, 0);
        end
    endtask

    // ---------------- 5. continuous mode + overrun ---------------------------
    task test_continuous;
        integer n_done;
        begin
            $display("[TEST] continuous mode, overrun detection, stop");
            apb_write(R_STATUS, 32'hE);
            set_vin(1.0);
            apb_write(R_CTRL, EN | START | CONT | (32'h1 << 8));
            n_done = 0;
            while (n_done < 3) begin @(posedge pclk); if (dut.done) n_done = n_done + 1; end
            apb_read(R_STATUS, rd);
            check(rd[0] == 1'b1, "continuous: BUSY stays high");
            check(rd[3] == 1'b1, "OVR set when DATA was not read");
            apb_read(R_DATA, rd);
            check(rd[N-1:0] == ideal_code(1.0), "continuous: DATA correct");
            apb_write(R_CTRL, EN | (32'h1 << 8));       // clear CONT -> stop after current
            @(negedge dut.busy);
            repeat (5) @(posedge pclk);
            check(dut.busy == 1'b0, "continuous stops when CONT cleared");
            apb_write(R_STATUS, 32'h8);
            apb_read(R_STATUS, rd);
            check(rd[3] == 1'b0, "OVR cleared by W1C");
        end
    endtask

    // ---------------- 6. abort ----------------------------------------------
    task test_abort;
        begin
            $display("[TEST] abort conversion by clearing EN");
            apb_write(R_STATUS, 32'hE);
            set_vin(0.7);
            apb_write(R_CTRL, EN | START | (32'd20 << 8));  // long sample time
            repeat (6) @(posedge pclk);
            apb_write(R_CTRL, 32'h0);
            repeat (40) @(posedge pclk);
            apb_read(R_STATUS, rd);
            check(rd[0] == 1'b0, "abort: BUSY low");
            check(rd[1] == 1'b0, "abort: no EOC");
            check(sample == 1'b0, "abort: S/H switch open");
            convert(0.7, 0, code);
            check(code == ideal_code(0.7), "conversion after abort is correct");
        end
    endtask

    // =====================================================================
    //  Data-dump tests for INL/DNL and FFT analysis
    // =====================================================================
    integer fd, n_samp, avg_arg, n_logged;
    reg [8*32-1:0] tag;
    reg            logging = 1'b0;

    // sweep definitions
    localparam integer RAMP_HITS = 32;                 // samples per code
    localparam integer FFT_N     = 4096;
    localparam integer FFT_M     = 67;                 // signal cycles (prime -> coherent)
    integer            test_kind;                      // 1 = ramp, 2 = sine

    function real sweep_v;
        input integer idx;
        real span, start;
        begin
            if (test_kind == 1) begin                  // ramp from -2 LSB to FS + 2 LSB
                start   = -2.0 * LSB;
                span    = VREF + 4.0 * LSB;
                sweep_v = start + span * idx / (1024.0 * RAMP_HITS);
            end else begin                             // coherent sine, -0.4 dBFS
                sweep_v = VREF/2.0 + 0.477 * VREF * $sin(2.0 * 3.14159265358979 * FFT_M * idx / FFT_N);
            end
        end
    endfunction

    // log every finished conversion and present the next input value
    always @(posedge pclk) if (logging && dut.done) begin
        $fdisplay(fd, "%0d %0.9f", dut.result, vin);
        n_logged = n_logged + 1;
        #1 set_vin(sweep_v(n_logged));
    end

    task run_sweep;
        input integer kind;
        input integer count;
        begin
            test_kind = kind;
            n_logged  = 0;
            set_vin(sweep_v(0));
            // SMP = 4: the stimulus is updated 1 clock after DONE, so the S/H
            // must stay open >= 2 clocks to acquire the new value
            apb_write(R_CTRL, EN | START | CONT | (32'h4 << 8) | (avg_arg << 4));
            logging = 1'b1;
            wait (n_logged >= count);
            logging = 1'b0;
            apb_write(R_CTRL, 32'h0);
            $fclose(fd);
            $display("[DUMP] %0d conversions written", count);
        end
    endtask

    // =====================================================================
    reg [8*16-1:0] testname;
    reg [8*128-1:0] fname;

    initial begin
        seed_tb = 2026;
        avg_arg = 0;
        tag     = "ideal";
        if (!$value$plusargs("TEST=%s", testname)) testname = "regress";
        if ($value$plusargs("AVG=%d", avg_arg)) ;
        if ($value$plusargs("TAG=%s", tag)) ;
        if ($test$plusargs("VCD")) begin
            $dumpfile("build/tb_sar_adc.vcd");
            $dumpvars(0, tb_sar_adc);
        end

        repeat (3) @(posedge pclk);
        presetn = 1'b1;
        repeat (2) @(posedge pclk);

        if (testname == "trace") begin
            // cycle-by-cycle trace of ONE conversion (Vin = 0.6 V -> code 341)
            fd = $fopen("build/trace.txt", "w");
            set_vin(0.6);
            apb_write(R_CTRL, EN | START | (32'h4 << 8));
            @(posedge dut.busy);
            k = 0;
            while (dut.busy || k < 2) begin
                @(negedge pclk); #1;          // after the comparator has decided
                $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0.9f",
                          k, sample, dac_code, comp, dut.busy, dut.done, afe.vdac(dac_code));
                k = k + 1;
                if (!dut.busy) k = k + 10;    // stop shortly after DONE
            end
            $fclose(fd);
            $display("[TRACE] build/trace.txt written");
        end else if (testname == "ramp") begin
            $sformat(fname, "build/%0s_ramp.txt", tag);
            fd = $fopen(fname, "w");
            $display("[TEST] ramp sweep (%0d hits/code, AVG=%0dx) -> %0s", RAMP_HITS, 1<<avg_arg, fname);
            run_sweep(1, 1024 * RAMP_HITS + 4 * RAMP_HITS);
        end else if (testname == "sine") begin
            $sformat(fname, "build/%0s_sine.txt", tag);
            fd = $fopen(fname, "w");
            $display("[TEST] coherent sine, %0d points, %0d cycles, AVG=%0dx -> %0s", FFT_N, FFT_M, 1<<avg_arg, fname);
            run_sweep(2, FFT_N);
        end else begin
            test_regs;
            test_transfer;
            test_timing_avg;
            test_window_irq;
            test_continuous;
            test_abort;
            $display("");
            $display("==================================================");
            if (errors == 0)
                $display("  RESULT: PASS   (%0d checks, 0 errors)", checks);
            else
                $display("  RESULT: FAIL   (%0d checks, %0d errors)", checks, errors);
            $display("==================================================");
        end
        $finish;
    end

    // global watchdog
    initial begin
        #200_000_000;
        $display("** WATCHDOG timeout");
        $finish;
    end

endmodule
