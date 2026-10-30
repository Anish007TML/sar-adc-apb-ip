#!/usr/bin/env python3
"""
analyze_adc.py - static (INL/DNL) and dynamic (SNDR/ENOB/SFDR) ADC analysis.

Reads the code dumps written by the testbench (build/<tag>_ramp.txt and
build/<tag>_sine.txt), computes the standard ADC figures of merit and
saves plots to docs/images/.

Static test  : histogram (code-density) method on a slow linear ramp
               DNL[k] = hits[k] / mean_hits - 1          (in LSB)
               INL[k] = cumulative sum of DNL             (in LSB)
Dynamic test : coherently sampled sine (M = 67 cycles in N = 4096 points,
               M prime so every sample hits a different phase -> no window
               needed, no spectral leakage)
               SNDR = P_signal / P_(noise + distortion)
               ENOB = (SNDR - 1.76) / 6.02

Usage:  python3 scripts/analyze_adc.py  [--build build] [--out docs/images]
"""
import argparse
import json
import os

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

NBITS = 10
NCODES = 2 ** NBITS
FFT_M = 67

# colors / ink (validated reference palette)
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

plt.rcParams.update({
    "figure.facecolor": SURF, "axes.facecolor": SURF,
    "axes.edgecolor": INK2, "axes.labelcolor": INK2, "text.color": INK,
    "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True,
    "grid.color": GRID, "grid.linewidth": 0.8, "axes.spines.top": False,
    "axes.spines.right": False, "font.size": 10, "axes.titlesize": 11,
    "axes.titleweight": "bold", "axes.titlelocation": "left",
})


def load_codes(path):
    data = np.loadtxt(path)
    return data[:, 0].astype(int), data[:, 1]


# --------------------------------------------------------------------------
def static_analysis(codes):
    hits = np.bincount(codes, minlength=NCODES).astype(float)
    inner = hits[1:-1]                       # end codes absorb over-range
    dnl = np.zeros(NCODES)
    dnl[1:-1] = inner / inner.mean() - 1.0
    inl = np.cumsum(dnl)
    # endpoint (best straight line through ends) correction
    inl[1:-1] -= np.linspace(inl[1], inl[-2], NCODES - 2)
    missing = int(np.sum(inner == 0))
    return {
        "dnl": dnl, "inl": inl,
        "dnl_max": float(np.max(np.abs(dnl[1:-1]))),
        "inl_max": float(np.max(np.abs(inl[1:-1]))),
        "missing_codes": missing,
    }


def dynamic_analysis(codes):
    n = len(codes)
    x = codes - np.mean(codes)
    X = np.abs(np.fft.rfft(x))
    P = X ** 2
    P[0] = 0.0                                # remove DC
    ps = P[FFT_M]
    pnd = np.sum(P) - ps
    sndr = 10 * np.log10(ps / pnd)
    spur = np.max(np.delete(P, FFT_M))
    sfdr = 10 * np.log10(ps / spur)
    harm = 0.0                                # harmonics 2..5, aliased
    for h in range(2, 6):
        b = (h * FFT_M) % n
        b = n - b if b > n // 2 else b
        harm += P[b]
    thd = 10 * np.log10(harm / ps) if harm > 0 else -200.0
    full_scale = (NCODES / 2) * n / 2         # |X| of a full-scale sine
    spec_dbfs = 20 * np.log10(np.maximum(X, 1e-12) / full_scale)
    sig_dbfs = spec_dbfs[FFT_M]
    return {
        "spec": spec_dbfs, "sndr": float(sndr), "enob": float((sndr - 1.76) / 6.02),
        "sfdr": float(sfdr), "thd": float(thd), "sig_dbfs": float(sig_dbfs),
    }


# --------------------------------------------------------------------------
def plot_static(res, out):
    tags = [t for t in ("ideal", "mismatch", "real") if t in res]
    fig, axes = plt.subplots(2, len(tags), figsize=(4.6 * len(tags), 5.8),
                             sharex=True, squeeze=False)
    titles = {"ideal": "Ideal analog front-end",
              "mismatch": "0.5 % unit-cap mismatch only",
              "real": "Mismatch + comparator/kT/C noise"}
    k = np.arange(NCODES)
    for j, t in enumerate(tags):
        s = res[t]
        ax = axes[0][j]
        ax.plot(k[1:-1], s["dnl"][1:-1], color=BLUE, lw=1.0)
        ax.set_title(f"{titles[t]}\nDNL   max |DNL| = {s['dnl_max']:.2f} LSB")
        ax.set_ylabel("DNL (LSB)")
        ax.set_ylim(-1, 1)
        ax = axes[1][j]
        ax.plot(k[1:-1], s["inl"][1:-1], color=BLUE, lw=1.6)
        ax.set_title(f"INL   max |INL| = {s['inl_max']:.2f} LSB")
        ax.set_ylabel("INL (LSB)")
        ax.set_xlabel("Output code")
        ax.set_ylim(-1, 1)
        ax.set_xlim(0, NCODES)
        ax.set_xticks([0, 256, 512, 768, 1023])
    if "mismatch" in tags:
        j = tags.index("mismatch")
        d = res["mismatch"]["dnl"]
        for c in (255, 511, 767):
            axes[0][j].plot(c, d[c], "o", ms=7, mfc="none", mec=ORANGE, mew=1.6)
        axes[0][j].text(30, 0.72, "largest errors at major carries\n255->256, 511->512, 767->768",
                        color=INK2, fontsize=8.5)
    fig.tight_layout()
    p = os.path.join(out, "dnl_inl.png")
    fig.savefig(p, dpi=150)
    plt.close(fig)
    return p


def plot_dynamic(res, out):
    tags = [t for t in ("ideal", "real", "real_avg8") if t in res]
    titles = {"ideal": "Ideal", "real": "Mismatch + noise",
              "real_avg8": "Mismatch + noise, 8x HW averaging"}
    fig, axes = plt.subplots(len(tags), 1, figsize=(9, 2.6 * len(tags)),
                             sharex=True, squeeze=False)
    for i, t in enumerate(tags):
        d = res[t]
        ax = axes[i][0]
        f = np.arange(len(d["spec"])) / 4096.0
        ax.plot(f, d["spec"], color=BLUE, lw=0.8)
        ax.set_ylim(-140, 5)
        ax.set_ylabel("dBFS")
        ax.set_title(f"{titles[t]}   SNDR {d['sndr']:.1f} dB  |  ENOB {d['enob']:.2f} bit"
                     f"  |  SFDR {d['sfdr']:.1f} dB")
    axes[-1][0].set_xlabel("Frequency (fraction of sample rate fs)")
    axes[-1][0].set_xlim(0, 0.5)
    fig.tight_layout()
    p = os.path.join(out, "spectrum.png")
    fig.savefig(p, dpi=150)
    plt.close(fig)
    return p


def plot_transfer(codes, vin, out):
    fig, ax = plt.subplots(figsize=(9, 3.4))
    lsb = 1.8 / NCODES
    sel = (vin > 508 * lsb) & (vin < 516 * lsb)
    ax.step(vin[sel] * 1e3, codes[sel], where="post", color=BLUE, lw=1.6, label="ADC output")
    ideal = np.clip(np.floor(vin[sel] / lsb), 0, NCODES - 1)
    ax.plot(vin[sel] * 1e3, ideal, color=ORANGE, lw=1.0, ls="--", label="Ideal floor(Vin/LSB)")
    ax.set_xlabel("Vin (mV)")
    ax.set_ylabel("Code")
    ax.set_title("Transfer function zoom around mid-scale (ideal model)")
    ax.legend(frameon=False, loc="upper left")
    fig.tight_layout()
    p = os.path.join(out, "transfer_zoom.png")
    fig.savefig(p, dpi=150)
    plt.close(fig)
    return p


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build")
    ap.add_argument("--out", default=os.path.join("docs", "images"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    stat, dyn, summary = {}, {}, {}
    for tag in ("ideal", "mismatch", "real"):
        f = os.path.join(a.build, f"{tag}_ramp.txt")
        if os.path.exists(f):
            codes, vin = load_codes(f)
            stat[tag] = static_analysis(codes)
            if tag == "ideal":
                plot_transfer(codes, vin, a.out)
    for tag in ("ideal", "real", "real_avg8"):
        f = os.path.join(a.build, f"{tag}_sine.txt")
        if os.path.exists(f):
            codes, _ = load_codes(f)
            dyn[tag] = dynamic_analysis(codes)

    if stat:
        plot_static(stat, a.out)
    if dyn:
        plot_dynamic(dyn, a.out)

    print(f"{'case':<12}{'|DNL|max':>10}{'|INL|max':>10}{'missing':>9}"
          f"{'SNDR dB':>9}{'ENOB':>7}{'SFDR dB':>9}{'THD dB':>9}")
    for tag in ("ideal", "mismatch", "real", "real_avg8"):
        s, d = stat.get(tag), dyn.get(tag)
        row = {}
        line = f"{tag:<12}"
        if s:
            line += f"{s['dnl_max']:>10.2f}{s['inl_max']:>10.2f}{s['missing_codes']:>9d}"
            row.update({k: s[k] for k in ("dnl_max", "inl_max", "missing_codes")})
        else:
            line += f"{'-':>10}{'-':>10}{'-':>9}"
        if d:
            line += f"{d['sndr']:>9.1f}{d['enob']:>7.2f}{d['sfdr']:>9.1f}{d['thd']:>9.1f}"
            row.update({k: d[k] for k in ("sndr", "enob", "sfdr", "thd")})
        print(line)
        if row:
            summary[tag] = row
    with open(os.path.join(a.build, "results.json"), "w") as fh:
        json.dump(summary, fh, indent=2)


if __name__ == "__main__":
    main()
