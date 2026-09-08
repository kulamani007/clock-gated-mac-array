import matplotlib, csv, sys, os
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams.update({"font.family":"serif","font.serif":["DejaVu Serif"],
                     "font.size":7.2,"axes.linewidth":0.6,
                     "savefig.bbox":"tight","savefig.pad_inches":0.01})

SRC = "data_power_post.csv" if os.path.exists("data_power_post.csv") else "data_power_rtl.csv"
rows = list(csv.DictReader(open(SRC)))
d = {}
for r in rows:
    d.setdefault(r["tag"], {})[int(r["label"][1:])] = float(r["dynamic_W"])*1000

STYLE = {
 "base": ("Baseline (ungated)",        "k",       "o", "-"),
 "dsp0": ("DSP-packed, gating off",    "0.45",    "s", "--"),
 "zs":   ("Split-enable (product reg)","#b2182b", "^", "-"),
 "dsp":  ("Split-enable + gated operands","#2166ac","D","-"),
}

fig, ax = plt.subplots(figsize=(3.45, 2.15))
for tag in ["base","dsp0","zs","dsp"]:
    if tag not in d: continue
    xs = sorted(d[tag]); ys = [d[tag][x] for x in xs]
    lbl, c, m, ls = STYLE[tag]
    ax.plot(xs, ys, marker=m, color=c, ls=ls, lw=1.0, ms=3.2, label=lbl)

ax.set_xlabel("operand sparsity $s$ (\\%)")
ax.set_ylabel("dynamic power (mW)")
ax.grid(True, lw=0.35, color="0.88")
ax.set_axisbelow(True)
ax.legend(fontsize=6.2, frameon=False, loc="lower left", handlelength=2.2)
ax.spines[["top","right"]].set_visible(False)
ax.set_xlim(-3, 93); ax.set_ylim(0, None)
fig.savefig("fig_power.pdf")
print("fig_power.pdf from", SRC)
