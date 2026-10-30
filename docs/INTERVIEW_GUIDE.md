# Interview Guide: SAR ADC APB IP

How to present this project, what to draw on the whiteboard, and answers to the
questions an SoC / mixed-signal interviewer is likely to ask.

---

## 1. The 60-second pitch

> "I designed a **10-bit SAR ADC IP** the way it would be delivered inside an SoC.
> The digital part, a **SAR controller FSM** and an **AMBA APB register block** with interrupts,
> averaging and a window comparator, is synthesizable Verilog. Since I can't tape out the
> analog part, I wrote a **behavioral model** of the capacitor DAC and comparator that includes
> **capacitor mismatch, comparator offset and noise**.
>
> I verified it with a **self-checking testbench**, 431 checks covering the register map,
> the transfer function, timing, interrupts and corner cases. I **mutation-tested** it to prove
> the tests actually catch bugs, and re-ran everything on the **gate-level netlist** after Yosys synthesis.
>
> Then I **characterised** it like real silicon: a histogram test for INL/DNL and a coherent-sampling
> FFT for SNDR and ENOB. The ideal case gives **9.94 effective bits**, which matches theory. With 0.5 %
> capacitor mismatch you see the classic DNL spikes at the major-carry codes. And I showed that
> **8× hardware averaging recovers ENOB from 8.9 to 9.6 bits**."

**Tie it to your background:** at SCL you designed analog/RF blocks in 180 nm with Virtuoso
and Spectre. This project is the **digital + verification side** of the same kind of
mixed-signal IP. VREF = 1.8 V was chosen to match a 180 nm process, and the comparator and
cap-DAC in the model are exactly the blocks you would design at transistor level.

---

## 2. Whiteboard: draw this

```
          APB bus                                       analog macro
   ┌──────────────┐   en,start,avg,smp   ┌──────────┐   sample   ┌─────────┐
CPU│ adc_apb_regs │ ───────────────────► │ sar_ctrl │ ─────────► │  S/H    │◄─ Vin
◄──│ CTRL STATUS  │ ◄─────────────────── │   FSM    │  dac_code  │ cap-DAC │
irq│ DATA IRQ WIN │   busy,done,result   │          │ ─────────► │         │
   └──────────────┘                      └──────────┘ ◄───────── │  comp   │
                                                        comp     └─────────┘
FSM:  IDLE ──start──► SAMPLE (SMP clk) ──► CONVERT (10 clk) ──► ACC ──► IDLE
                          ▲                                      │
                          └────── more averaging / continuous ───┘
```

Then explain one conversion with Vin = 0.6 V (see `images/sar_conversion.png`):
try 512 → too high, clear · try 256 → keep · 384 → clear · 320 → keep · … → **341**.
341 × 1.758 mV = 0.5994 V ✔.

---

## 3. Key numbers to remember

| Item | Value | Where it comes from |
|---|---|---|
| LSB | 1.758 mV | 1.8 V / 1024 |
| Conversion time | 15 clocks = 300 ns | 4 (sample) + 10 (bits) + 1 (accumulate) |
| Sample rate | 3.33 MS/s @ 50 MHz | 50 MHz / 15 |
| Ideal SNDR | 61.96 dB full-scale | 6.02·N + 1.76 |
| Measured ideal | 61.6 dB / 9.94 bit | tone at −0.41 dBFS → 61.55 dB expected |
| With non-idealities | 8.92 bit → 9.63 bit with 8× avg | |
| Logic | 108 flip-flops, ~600 gates | Yosys `stat` |
| Tests | 431 checks, 6/6 mutants killed | `make test` |

---

## 4. Likely questions and answers

### Architecture / analog

**Q: Why SAR and not flash or sigma-delta?**
Flash needs 2^N − 1 comparators (1023 for 10 bits): fast but huge and power-hungry.
Sigma-delta gives high resolution but needs oversampling and a digital decimation filter, so
it suits lower bandwidths. SAR needs **one comparator** and N clock cycles. It's the best
energy-per-conversion for 8–12 bits at around 1–10 MS/s, and it's mostly digital, so it
shrinks with each process node. That's why MCUs (including NXP's) use SAR ADCs.

**Q: How does the capacitor DAC work?**
Binary-weighted capacitors (1, 2, 4 … 512 Cu, plus a dummy Cu). In a charge-redistribution
SAR, the input is sampled onto the array. During conversion each bit's capacitor bottom plate
is switched to VREF or GND, so the top-plate voltage moves by
VREF·C_i/C_total. The comparator checks the sign. The array also acts as the
**sample-and-hold**, which is one of the reasons SAR is so efficient.

**Q: Why do DNL errors appear at codes 255/511/767?**
At 511→512 the MSB capacitor turns on and *all* the lower ones turn off. Any mismatch between
C_512 and the sum of C_1…C_256 shows up as a wider or narrower code. That's the
**major-carry transition**. The unit-cap error is random with σ_u, and a 2^i cap built from
2^i units has an absolute error of σ_u·√(2^i), so the biggest bit causes the biggest error.

**Q: How would you reduce mismatch?**
Larger unit caps (σ ∝ 1/√area), common-centroid layout with dummies, a split-capacitor
(bridge) DAC to cut total capacitance, or **digital calibration** (measure each bit's weight
and correct it in logic).

**Q: What is kT/C noise?**
Thermal noise sampled onto a capacitor: v_rms = √(kT/C). It sets the **minimum** total DAC
capacitance for a given resolution. For 10 bits at 1.8 V it is small, but at 14–16 bits it
dominates the design.

**Q: Comparator offset vs. noise: which one hurts ENOB?**
A static **offset** only shifts the whole transfer curve (an offset error, easily calibrated).
It does not change DNL or ENOB. **Random noise** adds to the noise floor and reduces SNDR/ENOB.
The model has both: 2 mV offset and 0.5 LSB rms noise.

### Digital design

**Q: Walk me through the FSM.**
IDLE waits for START. SAMPLE keeps the S/H switch closed for SMP clocks (acquisition time,
settling of the input). CONVERT runs 10 clocks: each clock the comparator's answer for the
current bit is applied and the next lower bit is set to 1 as the new trial. ACC adds the code
to an accumulator. It then either loops back to SAMPLE (more averaging samples, or continuous
mode) or returns to IDLE and pulses DONE.

**Q: Is the comparator output metastable?**
Not here. The comparator is **clocked by the SAR clock on the falling edge**, so its decision
is ready half a cycle before the SAR logic samples it. In an *asynchronous* SAR (self-timed
comparator) you would need a "ready" handshake. If a signal crosses clock domains, use a
2-flop synchronizer.

**Q: Why is the accumulator N+3 bits?**
Up to 8 = 2³ samples of a 10-bit value: max sum 8 × 1023 = 8184 < 2^13.

**Q: Why round instead of truncate when averaging?**
Truncation always rounds down, adding a systematic −0.5 LSB bias. The design adds 2^(k−1)
before shifting right by k. The testbench has a dedicated test for this, and the truncation
mutant was caught by it.

### Bus / registers

**Q: Explain the APB protocol.**
Two phases. **SETUP**: PSEL = 1, PENABLE = 0, address, direction and write data are driven.
**ACCESS**: PENABLE = 1, and the transfer completes on the clock edge where PREADY = 1.
This slave is zero-wait-state (PREADY tied high), so every transfer takes 2 clocks. PSLVERR
flags an error in the ACCESS phase; here that means an unmapped or unaligned address.

**Q: Why APB and not AXI?**
An ADC is a low-bandwidth control/status peripheral. APB has no bursts, no pipelining and
very low gate count. In an SoC it sits behind an AHB/AXI-to-APB bridge with the other
peripherals. A high-throughput ADC would add a **DMA request** instead.

**Q: What is W1C and why use it?**
Write-1-to-clear. Software writes a 1 only to the flag it wants to clear, so it never has to
do read-modify-write. That avoids accidentally clearing a flag that hardware set between the
read and the write. Also, if hardware sets a flag in the same cycle software clears it,
**set wins**, so no event is lost.

**Q: What is the overrun flag for?**
In continuous mode, if a new result arrives while EOC is still set (the previous result
was never read), data was lost. OVR tells the software, and it can raise an interrupt.

### Verification

**Q: How do you know your testbench is good?**
Three ways:
1. **Self-checking**: every result is compared with a reference model (`floor(Vin/LSB)`);
   nobody has to eyeball waveforms.
2. **Mutation testing**: I injected 6 bugs into the RTL, and every one made the regression
   fail. One mutant (truncation instead of rounding) initially *survived*, which showed a
   coverage hole, so I added a test that changes Vin between averaged samples.
3. **Assertions**: protocol checkers run during every test (S/H never samples while idle,
   PREADY always high).

**Q: Why gate-level simulation?**
It catches synthesis/simulation mismatches: incomplete sensitivity lists, unintended latches,
`x`-propagation and initial-value assumptions. The same testbench runs on the netlist
(`make gls`) and only probes top-level nets so it works on both.

**Q: How did you measure ENOB? Why 4096 points and 67 cycles?**
**Coherent sampling**: the number of signal cycles M and FFT points N are chosen so the sine
fits an integer number of periods, with M prime and coprime to N. Then every sample lands on
a different phase, there's no spectral leakage and no window is needed.
SNDR = signal power / everything else (excluding DC), and ENOB = (SNDR − 1.76)/6.02.

**Q: How did you measure DNL?**
**Histogram (code-density) test**: a slow linear ramp slightly beyond full scale, 32 samples
per code on average. A code that is hit more often is wider:
DNL[k] = hits[k]/mean − 1, and INL is the running sum (end-point corrected).

**Q: A bug you found while building this?**
The first FFT gave only 8.4 ENOB for the *ideal* model, which was impossible. Comparing the
dumped codes with floor(Vin/LSB), almost every one was off by one sample. The testbench
updated Vin one clock after DONE, but with a 1-clock sample time the S/H had already closed,
so every conversion used the **previous** input. That broke coherent sampling. With a
≥2-clock sample time it gives the theoretical 9.94 bit. Lesson: **always sanity-check
measurements against theory**.

### SoC flow (connect to the NXP job description)

**Q: How would this go to silicon?**
RTL → lint → simulation → **synthesis** with the foundry standard-cell library and SDC
constraints → **STA** → **DFT** (scan insertion; the analog macro gets a test mux/bypass) →
**place & route** (floorplan, power grid, CTS, routing) → signoff (STA, DRC/LVS, IR drop) →
**mixed-signal integration**: the analog macro as a hard block with a LEF/LIB abstract.
Mixed-signal verification would use real-number models (like mine) or AMS co-simulation
with Spectre.

**Q: What would you add next?**
A transistor-level StrongARM comparator and cap-DAC in Virtuoso, co-simulated with this RTL;
foreground mismatch calibration; a UVM environment with functional coverage; and an
OpenLane place-and-route run on Sky130.

---

## 5. Demo in the interview (if you have a laptop)

```bash
make test        # 431 checks PASS
make analyze     # regenerates all plots
vvp -n build/sim.vvp +TEST=sine +TAG=demo +MISMATCH_PPM=20000 +SEED=1
```
Then show how ENOB drops when you raise the mismatch, and explain why.
