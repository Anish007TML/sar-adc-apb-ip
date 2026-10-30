#!/usr/bin/env python3
"""
plot_conversion.py - visualise one SAR conversion (binary search) from
build/trace.txt (written by: vvp build/sim.vvp +TEST=trace).

Top panel   : DAC voltage tried each clock vs. the held input voltage
Bottom panel: digital control signals (sample, busy, done)
"""
import os

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

BLUE, ORANGE, AQUA, RED = "#2a78d6", "#eb6834", "#1baf7a", "#e34948"
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
VIN = 0.6

d = np.loadtxt(os.path.join("build", "trace.txt"))
cyc, samp, code, comp, busy, done, vdac = (d[:, i] for i in range(7))
code = code.astype(int)
conv = np.where((samp == 0) & (busy == 1))[0]          # CONVERT cycles (+ ACC)
conv = conv[:-1]                                        # last busy cycle is ACC

fig, (ax, ax2) = plt.subplots(2, 1, figsize=(10, 6.2), sharex=True,
                              gridspec_kw={"height_ratios": [3, 1.3]},
                              facecolor=SURF)
for a in (ax, ax2):
    a.set_facecolor(SURF)
    for s in ("top", "right"):
        a.spines[s].set_visible(False)
    a.grid(True, color=GRID, lw=0.8)

ax.axhline(VIN, color=ORANGE, lw=1.6, ls="--")
ax.text(cyc[0] + 0.1, VIN + 0.02, "Vin (held) = 0.600 V", color=INK2, fontsize=9)
xs = np.append(cyc[conv], cyc[conv[-1]] + 1)
ax.step(xs, np.append(vdac[conv], vdac[conv[-1]]), where="post", color=BLUE, lw=2)
for i, c in enumerate(conv):
    keep = comp[c] == 1
    ax.plot(cyc[c] + 0.5, vdac[c], "o", ms=8, color=AQUA if keep else RED,
            mec=SURF, mew=1.5, zorder=3)
    bit = 9 - i
    ax.text(cyc[c] + 0.5, 1.04, f"b{bit}\n{code[c]}", ha="center", va="top",
            fontsize=8, color=INK2)
ax.plot([], [], "o", color=AQUA, label="Vin >= Vdac : keep bit")
ax.plot([], [], "o", color=RED, label="Vin < Vdac : clear bit")
ax.legend(frameon=False, loc="lower right", fontsize=9)
ax.set_ylabel("DAC voltage (V)", color=INK2)
ax.set_ylim(0.3, 1.08)
ax.text(cyc[0] + 0.1, 1.03, "bit tried\ntrial code", fontsize=8, color=INK2, va="top")
ax.set_title("One 10-bit SAR conversion: binary search converges to code 341 in 10 clocks",
             loc="left", fontweight="bold", fontsize=11)

rows = [("sample", samp, BLUE), ("busy", busy, INK2), ("done", done, AQUA)]
for k, (name, sig, col) in enumerate(rows):
    off = (len(rows) - 1 - k) * 2.0
    ax2.step(np.append(cyc, cyc[-1] + 1), np.append(sig, sig[-1]) + off,
             where="post", color=col, lw=1.8)
    ax2.text(cyc[0] - 0.4, off + 0.35, name, ha="right", va="center", fontsize=9, color=INK2)
ax2.set_yticks([])
ax2.set_xlabel("Clock cycle (20 ns @ 50 MHz)", color=INK2)
ax2.text(1.5, 5.4, "SAMPLE (4 clk)", ha="center", fontsize=8, color=INK2)
ax2.text(8.5, 5.4, "CONVERT (10 clk, 1 bit / clk)", ha="center", fontsize=8, color=INK2)
ax2.set_ylim(-0.3, 5.9)
ax2.set_xlim(cyc[0] - 0.2, cyc[-1] + 1)

fig.tight_layout()
out = os.path.join("docs", "images", "sar_conversion.png")
fig.savefig(out, dpi=150)
print("saved", out)
