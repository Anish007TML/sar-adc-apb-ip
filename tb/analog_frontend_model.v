// =============================================================================
//  analog_frontend_model.v  --  Behavioral model of the SAR ADC analog macro
// -----------------------------------------------------------------------------
//  NOT synthesizable. Uses Verilog 'real' arithmetic to model:
//
//   * Sample & hold     : Vin is captured on the falling edge of 'sample',
//                         plus optional kT/C (thermal) sampling noise.
//   * Binary-weighted   : bit i is made of 2^i unit capacitors. Each unit has
//     capacitor DAC       random mismatch sigma_u, so bit i has relative error
//                         sigma_u / sqrt(2^i)  (errors of the units average out).
//                         Vdac = VREF * sum(b_i * C_i) / C_total
//   * Clocked comparator: evaluated on the falling clock edge (mid-cycle) so its
//                         decision is ready for the SAR logic on the next rising
//                         edge. Includes static offset and random (thermal)
//                         noise per decision.
//
//  Non-idealities are set from the simulator command line (integers):
//     +MISMATCH_PPM=<n>   unit-capacitor sigma in ppm   (5000 = 0.5 %)
//     +NOISE_UV=<n>       comparator rms noise in uV
//     +OFFSET_UV=<n>      comparator offset in uV (signed)
//     +KTC_UV=<n>         sampling (kT/C) rms noise in uV
//     +SEED=<n>           random seed (reproducible runs)
// =============================================================================
`timescale 1ns/1ps

module analog_frontend_model #(
    parameter integer N = 10
) (
    input  wire          clk,
    input  wire [63:0]   vin_bits,     // $realtobits(Vin)
    input  wire          sample,
    input  wire [N-1:0]  dac_code,
    output reg           comp
);

    real VREF;                         // reference voltage (1.8 V, 180 nm CMOS)
    real cap   [0:N-1];                // actual capacitor values, in unit caps
    real c_dummy;                      // termination (dummy) unit cap
    real c_tot;
    real v_hold;

    integer mismatch_ppm, noise_uv, offset_uv, ktc_uv, seed, seed0;
    integer i;

    // standard normal random number  N(0,1)
    function real gauss;
        input integer dummy;
        begin
            gauss = $dist_normal(seed, 0, 1000000) / 1.0e6;
        end
    endfunction

    // DAC output voltage for a given code
    function real vdac;
        input [N-1:0] code;
        integer k;
        real    q;
        begin
            q = 0.0;
            for (k = 0; k < N; k = k + 1)
                if (code[k]) q = q + cap[k];
            vdac = VREF * q / c_tot;
        end
    endfunction

    initial begin
        VREF         = 1.8;
        mismatch_ppm = 0;
        noise_uv     = 0;
        offset_uv    = 0;
        ktc_uv       = 0;
        seed         = 1;
        if ($value$plusargs("MISMATCH_PPM=%d", mismatch_ppm)) ;
        if ($value$plusargs("NOISE_UV=%d",     noise_uv)) ;
        if ($value$plusargs("OFFSET_UV=%d",    offset_uv)) ;
        if ($value$plusargs("KTC_UV=%d",       ktc_uv)) ;
        if ($value$plusargs("SEED=%d",         seed)) ;
        seed0 = seed;

        // build the capacitor array
        c_tot = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            cap[i] = (2.0 ** i) *
                     (1.0 + (mismatch_ppm * 1.0e-6) * gauss(0) / $sqrt(2.0 ** i));
            c_tot  = c_tot + cap[i];
        end
        c_dummy = 1.0 + (mismatch_ppm * 1.0e-6) * gauss(0);
        c_tot   = c_tot + c_dummy;

        v_hold = 0.0;
        comp   = 1'b0;

        $display("[AFE] VREF=%0.3f V  LSB=%0.3f mV  mismatch=%0d ppm  noise=%0d uV  offset=%0d uV  kTC=%0d uV  seed=%0d",
                 VREF, VREF/(2.0**N)*1e3, mismatch_ppm, noise_uv, offset_uv, ktc_uv, seed0);
    end

    // ---- sample & hold: capture on falling edge of 'sample' ----------------
    always @(negedge sample) begin
        v_hold = $bitstoreal(vin_bits) + (ktc_uv * 1.0e-6) * gauss(0);
    end

    // ---- clocked comparator --------------------------------------------------
    always @(negedge clk) begin
        comp <= ((v_hold + offset_uv * 1.0e-6 + (noise_uv * 1.0e-6) * gauss(0))
                 >= vdac(dac_code));
    end

endmodule
