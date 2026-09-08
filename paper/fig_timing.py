import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

plt.rcParams.update({
    "font.family": "serif", "font.serif": ["DejaVu Serif"],
    "font.size": 7.0, "axes.linewidth": 0.6,
    "savefig.bbox": "tight", "savefig.pad_inches": 0.01,
})

NC = 8
LBLX = -0.18          # right edge of signal names
MARG = 2.55           # right margin (in cycles) reserved for verdict text

def draw(ax, y, vals, label, color="k", lw=1.0):
    xs, ys = [], []
    for i, v in enumerate(vals):
        xs += [i, i+1]; ys += [y + 0.60*v, y + 0.60*v]
    ax.plot(xs, ys, color=color, lw=lw, solid_joinstyle="miter", clip_on=False)
    for i in range(1, len(vals)):
        if vals[i] != vals[i-1]:
            ax.plot([i, i], [y+0.60*vals[i-1], y+0.60*vals[i]],
                    color=color, lw=lw, clip_on=False)
    ax.text(LBLX, y+0.30, label, ha="right", va="center", fontsize=7.0)

fig, axes = plt.subplots(2, 1, figsize=(3.45, 2.75), sharex=True,
                         gridspec_kw={"hspace":0.42})

valid  = [0, 1, 1, 1, 0, 0, 0, 0]
zeroop = [0, 0, 0, 1, 0, 0, 0, 0]

RED, BLU = "#b2182b", "#2166ac"

# ---- (a) naive ----
a = axes[0]
draw(a, 3.0, valid,  r"$valid\_in$")
draw(a, 2.0, zeroop, r"$operand\_zero$")
draw(a, 1.0, [0,1,1,0,1,0,0,0], r"$ce$", color=RED, lw=1.2)
draw(a, 0.0, [0]*8,             r"$result\_valid$", color=RED, lw=1.2)
a.add_patch(Rectangle((3,-0.18), 1, 3.98, facecolor=RED, alpha=0.11, lw=0))
a.text(NC+0.18, 1.30, "enable\nremoved", fontsize=6.3, color=RED, va="center")
a.text(NC+0.18, 0.16, "never\nasserts",  fontsize=6.3, color=RED, va="center")
a.set_title(r"(a) naive: shared enable masked by the enable of Eq. (1)",
            fontsize=7.0, pad=2.5)

# ---- (b) proposed ----
b = axes[1]
draw(b, 3.0, [0,1,1,1,1,1,0,0], r"$ce_{\mathrm{ctrl}}$", color=BLU, lw=1.2)
draw(b, 2.0, [0,1,1,0,0,0,0,0], r"$ce_{\mathrm{mult}}$", color=BLU, lw=1.2)
draw(b, 1.0, [0,0,0,1,0,0,0,0], r"$skip_p$")
draw(b, 0.0, [0,0,0,0,0,1,0,0], r"$result\_valid$", color=BLU, lw=1.2)
b.add_patch(Rectangle((3,-0.18), 1, 3.98, facecolor=BLU, alpha=0.11, lw=0))
b.text(NC+0.18, 3.30, "drain path\nuntouched", fontsize=6.3, color=BLU, va="center")
b.text(NC+0.18, 2.30, "datapath\ngated",       fontsize=6.3, color=BLU, va="center")
b.text(NC+0.18, 0.30, "result\nretained",      fontsize=6.3, color=BLU, va="center")
b.set_title(r"(b) proposed: split enable with per-item $skip_p$ tag",
            fontsize=7.0, pad=2.5)

labels = [r"$T\!-\!1$", r"$T$", r"$T\!+\!1$", r"$T\!+\!2$", r"$T\!+\!3$",
          r"$T\!+\!4$", r"$T\!+\!5$", r"$T\!+\!6$"]
for ax in axes:
    ax.set_ylim(-0.40, 3.95)
    ax.set_xlim(-1.45, NC + MARG)
    for i in range(NC+1):
        ax.axvline(i, color="0.86", lw=0.4, zorder=0)
    ax.set_yticks([]); ax.spines[:].set_visible(False)
axes[1].set_xticks([i+0.5 for i in range(NC)])
axes[1].set_xticklabels(labels, fontsize=6.3)
axes[1].tick_params(axis="x", length=0, pad=1.5)

fig.savefig("fig_timing.pdf")
print("ok")
