// =============================================================================
//  adc_apb_regs.v  --  AMBA APB3 slave register block for the SAR ADC IP
// -----------------------------------------------------------------------------
//  Zero-wait-state APB3 slave (PREADY tied high). Unmapped addresses return
//  PSLVERR = 1. All registers are 32-bit and word aligned.
//
//  Offset  Name     Access  Description
//  ------  -------  ------  ---------------------------------------------------
//  0x00    CTRL     RW      [0]    EN        ADC enable
//                           [1]    START     write 1 to start (self-clearing, reads 0)
//                           [2]    CONT      continuous conversion mode
//                           [3]    WIN_EN    window comparator enable
//                           [5:4]  AVG       hw averaging 0:1x 1:2x 2:4x 3:8x
//                           [15:8] SMP       sample time in clocks (0 => 1)
//  0x04    STATUS   R/W1C   [0]    BUSY      conversion in progress (RO)
//                           [1]    EOC       end of conversion   (W1C / cleared on DATA read)
//                           [2]    WIN       result outside window (W1C)
//                           [3]    OVR       overrun: new result while EOC still set (W1C)
//  0x08    DATA     RO      [N-1:0] last conversion result (read clears EOC)
//  0x0C    IRQ_EN   RW      [0] EOC_IE  [1] WIN_IE  [2] OVR_IE
//  0x10    WIN_LO   RW      [N-1:0] window low threshold
//  0x14    WIN_HI   RW      [N-1:0] window high threshold
//  0x18    ID       RO      IP identification / version
//
//  irq = |(STATUS[3:1] & IRQ_EN[2:0])     (level, active high)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module adc_apb_regs #(
    parameter integer N        = 10,
    parameter [31:0]  IP_ID    = 32'h0ADC_0100      // "ADC" v1.00
) (
    // APB3 slave
    input  wire          pclk,
    input  wire          presetn,
    input  wire          psel,
    input  wire          penable,
    input  wire          pwrite,
    input  wire [7:0]    paddr,
    /* verilator lint_off UNUSEDSIGNAL */   // pwdata[31:16] reserved
    input  wire [31:0]   pwdata,
    /* verilator lint_on UNUSEDSIGNAL */
    output reg  [31:0]   prdata,
    output wire          pready,
    output wire          pslverr,

    // to SAR core
    output wire          en,
    output wire          start,
    output wire          cont,
    output wire [1:0]    avg_sel,
    output wire [7:0]    sample_cycles,

    // from SAR core
    input  wire          busy,
    input  wire          done,
    input  wire [N-1:0]  result,

    output wire          irq
);

    // ---- address decode -------------------------------------------------
    localparam [5:0] A_CTRL   = 6'h00,   // 0x00
                     A_STATUS = 6'h01,   // 0x04
                     A_DATA   = 6'h02,   // 0x08
                     A_IRQEN  = 6'h03,   // 0x0C
                     A_WINLO  = 6'h04,   // 0x10
                     A_WINHI  = 6'h05,   // 0x14
                     A_ID     = 6'h06;   // 0x18

    wire [5:0] widx      = paddr[7:2];
    wire       aligned   = (paddr[1:0] == 2'b00);
    wire       mapped    = aligned && (widx <= A_ID);

    wire       access    = psel & penable;          // APB ACCESS phase
    wire       wr        = access &  pwrite & mapped;
    wire       rd        = access & ~pwrite & mapped;

    assign pready  = 1'b1;
    assign pslverr = access & ~mapped;

    // ---- registers --------------------------------------------------------
    reg          ctrl_en, ctrl_cont, ctrl_win_en;
    reg  [1:0]   ctrl_avg;
    reg  [7:0]   ctrl_smp;
    reg          start_q;
    reg          st_eoc, st_win, st_ovr;
    reg  [N-1:0] data_q;
    reg  [2:0]   irq_en;
    reg  [N-1:0] win_lo, win_hi;

    wire out_of_window = (result < win_lo) || (result > win_hi);

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl_en     <= 1'b0;
            ctrl_cont   <= 1'b0;
            ctrl_win_en <= 1'b0;
            ctrl_avg    <= 2'd0;
            ctrl_smp    <= 8'd4;                  // reset sample time: 4 clocks
            start_q     <= 1'b0;
            st_eoc      <= 1'b0;
            st_win      <= 1'b0;
            st_ovr      <= 1'b0;
            data_q      <= {N{1'b0}};
            irq_en      <= 3'b000;
            win_lo      <= {N{1'b0}};
            win_hi      <= {N{1'b1}};
        end else begin
            start_q <= 1'b0;                      // START is a 1-cycle pulse

            // ---------------- software writes ----------------
            if (wr) begin
                case (widx)
                    A_CTRL: begin
                        ctrl_en     <= pwdata[0];
                        start_q     <= pwdata[1];
                        ctrl_cont   <= pwdata[2];
                        ctrl_win_en <= pwdata[3];
                        ctrl_avg    <= pwdata[5:4];
                        ctrl_smp    <= pwdata[15:8];
                    end
                    A_STATUS: begin               // write-1-to-clear
                        if (pwdata[1]) st_eoc <= 1'b0;
                        if (pwdata[2]) st_win <= 1'b0;
                        if (pwdata[3]) st_ovr <= 1'b0;
                    end
                    A_IRQEN: irq_en <= pwdata[2:0];
                    A_WINLO: win_lo <= pwdata[N-1:0];
                    A_WINHI: win_hi <= pwdata[N-1:0];
                    default: ;                    // DATA / ID are read-only
                endcase
            end

            // reading DATA acknowledges the conversion
            if (rd && widx == A_DATA)
                st_eoc <= 1'b0;

            // ---------------- hardware events (win over SW clear) ----------
            if (done) begin
                data_q <= result;
                st_eoc <= 1'b1;
                if (st_eoc && !(rd && widx == A_DATA) &&
                    !(wr && widx == A_STATUS && pwdata[1]))
                    st_ovr <= 1'b1;               // previous result never read
                if (ctrl_win_en && out_of_window)
                    st_win <= 1'b1;
            end
        end
    end

    // ---- read mux (combinational, valid in ACCESS phase) -----------------
    always @(*) begin
        prdata = 32'h0;
        if (psel && !pwrite) begin
            case (widx)
                A_CTRL:   prdata = {16'h0, ctrl_smp, 2'b00, ctrl_avg,
                                    ctrl_win_en, ctrl_cont, 1'b0, ctrl_en};
                A_STATUS: prdata = {28'h0, st_ovr, st_win, st_eoc, busy};
                A_DATA:   prdata = {{(32-N){1'b0}}, data_q};
                A_IRQEN:  prdata = {29'h0, irq_en};
                A_WINLO:  prdata = {{(32-N){1'b0}}, win_lo};
                A_WINHI:  prdata = {{(32-N){1'b0}}, win_hi};
                A_ID:     prdata = IP_ID;
                default:  prdata = 32'h0;
            endcase
        end
    end

    // ---- outputs ------------------------------------------------------------
    assign en            = ctrl_en;
    assign start         = start_q;
    assign cont          = ctrl_cont;
    assign avg_sel       = ctrl_avg;
    assign sample_cycles = ctrl_smp;

    assign irq = |({st_ovr, st_win, st_eoc} & irq_en);

endmodule

`default_nettype wire
