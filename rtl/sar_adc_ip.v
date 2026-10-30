// =============================================================================
//  sar_adc_ip.v  --  Top level of the SAR ADC digital IP
// -----------------------------------------------------------------------------
//
//            APB3 bus                     analog macro (cap-DAC + comparator)
//   ----------------------+          +--------------------------------------
//   psel/penable/pwrite --|          |
//   paddr/pwdata ------->|  REGS  --> SAR_CTRL --- sample ----> S/H switch
//   prdata/pslverr <-----|          |          --- dac_code --> cap-DAC
//   irq <----------------|          |          <-- comp ------- comparator
//   ----------------------+          +--------------------------------------
//
//  This module is the fully synthesizable digital part. In silicon the analog
//  macro is a custom (full-custom / Virtuoso) block; in this repo it is
//  replaced by a behavioral model (tb/analog_frontend_model.v) for simulation.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module sar_adc_ip #(
    parameter integer N = 10
) (
    input  wire          pclk,
    input  wire          presetn,

    // APB3 slave
    input  wire          psel,
    input  wire          penable,
    input  wire          pwrite,
    input  wire [7:0]    paddr,
    input  wire [31:0]   pwdata,
    output wire [31:0]   prdata,
    output wire          pready,
    output wire          pslverr,

    // interrupt
    output wire          irq,

    // analog macro interface
    output wire          sample_o,
    output wire [N-1:0]  dac_code_o,
    input  wire          comp_i
);

    wire          en, start, cont, busy, done;
    wire [1:0]    avg_sel;
    wire [7:0]    sample_cycles;
    wire [N-1:0]  result;

    adc_apb_regs #(.N(N)) u_regs (
        .pclk          (pclk),
        .presetn       (presetn),
        .psel          (psel),
        .penable       (penable),
        .pwrite        (pwrite),
        .paddr         (paddr),
        .pwdata        (pwdata),
        .prdata        (prdata),
        .pready        (pready),
        .pslverr       (pslverr),
        .en            (en),
        .start         (start),
        .cont          (cont),
        .avg_sel       (avg_sel),
        .sample_cycles (sample_cycles),
        .busy          (busy),
        .done          (done),
        .result        (result),
        .irq           (irq)
    );

    sar_ctrl #(.N(N)) u_sar (
        .clk           (pclk),
        .rst_n         (presetn),
        .en            (en),
        .start         (start),
        .cont          (cont),
        .avg_sel       (avg_sel),
        .sample_cycles (sample_cycles),
        .comp          (comp_i),
        .sample        (sample_o),
        .dac_code      (dac_code_o),
        .busy          (busy),
        .done          (done),
        .result        (result)
    );

endmodule

`default_nettype wire
