// =============================================================================
//  sar_ctrl.v  --  Successive-Approximation (SAR) conversion controller
// -----------------------------------------------------------------------------
//  Digital half of a charge-redistribution SAR ADC.
//
//  One conversion =  SAMPLE phase  (programmable, sample_cycles clocks)
//                  + CONVERT phase (N clocks, one bit decided per clock)
//                  + ACC phase     (1 clock, accumulate for hardware averaging)
//
//  Binary search:  the MSB is tried first (dac_code = 100..0). The analog
//  comparator answers "is Vin >= Vdac?". If yes the bit is kept, otherwise it
//  is cleared, and the next lower bit is tried. After N decisions dac_code
//  holds the digital result.
//
//  Features
//    * Single-shot or continuous conversion
//    * Programmable sample (acquisition) time
//    * Hardware averaging of 1/2/4/8 conversions (rounded)
//    * Clean abort when 'en' is de-asserted mid-conversion
//
//  Analog interface (to cap-DAC + comparator):
//    sample   : 1 = S/H switch closed (tracking Vin), falling edge = hold
//    dac_code : trial code driving the capacitor DAC switches
//    comp     : comparator decision, 1 => Vin_held >= Vdac
//               (comparator is clocked by clk; result is ready before the
//                next rising edge, so it is synchronous to this block)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module sar_ctrl #(
    parameter integer N = 10                 // ADC resolution in bits
) (
    input  wire          clk,
    input  wire          rst_n,              // async active-low reset

    // control (from register block)
    input  wire          en,                 // ADC enable
    input  wire          start,              // 1-cycle start pulse
    input  wire          cont,               // continuous mode
    input  wire [1:0]    avg_sel,            // 0:1x 1:2x 2:4x 3:8x averaging
    input  wire [7:0]    sample_cycles,      // acquisition time in clocks (0 => 1)

    // analog front-end interface
    input  wire          comp,
    output reg           sample,
    output reg  [N-1:0]  dac_code,

    // status / result
    output reg           busy,
    output reg           done,               // 1-cycle pulse, result valid
    output reg  [N-1:0]  result
);

    // ---------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0,
                     S_SAMP = 2'd1,
                     S_CONV = 2'd2,
                     S_ACC  = 2'd3;

    localparam integer BW  = (N <= 2) ? 1 : $clog2(N);   // bit-index width
    localparam integer ACW = N + 3;                      // accumulator: up to 8 samples
    localparam integer  MSB_I   = N - 1;
    localparam [BW-1:0] MSB_IDX = MSB_I[BW-1:0];

    reg [1:0]      state;
    reg [7:0]      samp_cnt;
    reg [BW-1:0]   bit_idx;
    reg [ACW-1:0]  acc;
    reg [3:0]      avg_cnt;
    reg [1:0]      avg_lat;      // averaging setting latched at start

    // ---- combinational helpers -------------------------------------------
    wire [7:0] samp_target = (sample_cycles == 8'd0) ? 8'd1 : sample_cycles;

    // SAR decision for the current bit + set trial for next bit
    reg  [N-1:0] code_next;
    always @(*) begin
        code_next = dac_code;
        if (!comp)
            code_next[bit_idx] = 1'b0;           // Vin < Vdac -> reject this bit
        if (bit_idx != {BW{1'b0}})
            code_next[bit_idx - 1'b1] = 1'b1;    // try next lower bit
    end

    wire [ACW-1:0] acc_sum   = acc + {{(ACW-N){1'b0}}, code_next};
    wire [3:0]     avg_total = 4'd1 << avg_lat;

    // rounded divide by 2^avg_lat
    wire [ACW-1:0] round_add = (avg_lat == 2'd0) ? {ACW{1'b0}}
                                                 : ({{(ACW-1){1'b0}}, 1'b1} << (avg_lat - 1'b1));
    /* verilator lint_off UNUSEDSIGNAL */   // upper bits are always 0 after the shift
    wire [ACW-1:0] avg_res   = (acc + round_add) >> avg_lat;
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- main FSM ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            samp_cnt <= 8'd0;
            bit_idx  <= {BW{1'b0}};
            acc      <= {ACW{1'b0}};
            avg_cnt  <= 4'd0;
            avg_lat  <= 2'd0;
            sample   <= 1'b0;
            dac_code <= {N{1'b0}};
            busy     <= 1'b0;
            done     <= 1'b0;
            result   <= {N{1'b0}};
        end else begin
            done <= 1'b0;                        // default: pulse

            if (!en) begin                       // abort / disabled
                state    <= S_IDLE;
                sample   <= 1'b0;
                busy     <= 1'b0;
                dac_code <= {N{1'b0}};
            end else begin
                case (state)
                // -------------------------------------------------------
                S_IDLE: begin
                    sample <= 1'b0;
                    if (start) begin
                        state    <= S_SAMP;
                        busy     <= 1'b1;
                        sample   <= 1'b1;        // close S/H switch
                        samp_cnt <= 8'd0;
                        acc      <= {ACW{1'b0}};
                        avg_cnt  <= 4'd0;
                        avg_lat  <= avg_sel;
                    end
                end
                // -------------------------------------------------------
                S_SAMP: begin
                    if (samp_cnt + 8'd1 >= samp_target) begin
                        sample   <= 1'b0;        // open switch -> HOLD
                        state    <= S_CONV;
                        bit_idx  <= MSB_IDX;
                        dac_code <= {1'b1, {(N-1){1'b0}}};   // try MSB
                    end else begin
                        samp_cnt <= samp_cnt + 8'd1;
                    end
                end
                // -------------------------------------------------------
                S_CONV: begin
                    dac_code <= code_next;
                    if (bit_idx == {BW{1'b0}}) begin
                        acc   <= acc_sum;        // LSB decided: conversion done
                        state <= S_ACC;
                    end else begin
                        bit_idx <= bit_idx - 1'b1;
                    end
                end
                // -------------------------------------------------------
                S_ACC: begin
                    if (avg_cnt + 4'd1 >= avg_total) begin
                        result <= avg_res[N-1:0];
                        done   <= 1'b1;
                        acc    <= {ACW{1'b0}};
                        avg_cnt<= 4'd0;
                        if (cont) begin          // continuous: start again (clear CONT to stop)
                            state    <= S_SAMP;
                            sample   <= 1'b1;
                            samp_cnt <= 8'd0;
                        end else begin
                            state    <= S_IDLE;
                            busy     <= 1'b0;
                        end
                    end else begin               // more samples to average
                        avg_cnt  <= avg_cnt + 4'd1;
                        state    <= S_SAMP;
                        sample   <= 1'b1;
                        samp_cnt <= 8'd0;
                    end
                end
                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
