import csv
d={r["tag"]:r for r in csv.DictReader(open("data_asic.csv"))}
b=float(d["base"]["area_um2"])
NAME=[("base",r"Baseline (2-stage, async reset)"),
      ("zs",  r"\quad + split-enable zero-skip"),
      ("ir",  r"3-stage, gated operands, async reset"),
      ("dsp0",r"3-stage, no datapath reset (control)"),
      ("dsp", r"\quad + split-enable zero-skip")]
L=[r"\begin{table}[t]",
   r"\caption{Standard-cell synthesis, sky130\_fd\_sc\_hd (typ., 25\,$^{\circ}$C, 1.8\,V)}",
   r"\label{tab:asic}",r"\centering\footnotesize",
   r"\setlength{\tabcolsep}{3pt}",
   r"\begin{tabular}{lcccc}",r"\toprule",
   r"Design & area & vs.\ & \multicolumn{2}{c}{flip-flops}\\",
   r"\cmidrule(l){4-5}",
   r"& ($\mu$m$^2$) & base & total & native-EN\\",r"\midrule"]
for t,n in NAME:
    r=d[t]; a=float(r["area_um2"])
    delta = "---" if t == "base" else ("%+.1f\\%%" % (100*(a-b)/b))
    L.append("%s & %s & %s & %s & %s\\\\" % (
        n, format(int(a), ","), delta, r["ff_total"], r["ff_native_enable"]))
L+=[r"\bottomrule",r"\end{tabular}",r"\\[2pt]",
    r"\raggedright\scriptsize Yosys 0.63 + ABC, pre-layout cell area. ``native-EN''",
    r"counts registers mapped onto a true enable flip-flop (\texttt{edfxtp}); the",
    r"library provides an enable cell and an async-reset cell but none that is",
    r"both, so asynchronously reset registers with a clock enable become a reset",
    r"flop plus a feedback multiplexer instead.",
    r"\end{table}"]
open("tab_asic.tex","w").write("\n".join(L)+"\n")
print("tab_asic.tex regenerated")
