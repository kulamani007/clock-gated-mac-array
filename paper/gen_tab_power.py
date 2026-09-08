import csv
rows=list(csv.DictReader(open("data_power_rtl.csv")))
d={(r["tag"],r["label"]):float(r["dynamic_W"])*1000 for r in rows}
c={(r["tag"],r["label"]):float(r["clocks_W"])*1000 for r in rows}
SP=["s0","s50","s75","s90"]; SPL={"s0":"0","s50":"50","s75":"75","s90":"90"}
NAME=[("base",r"Baseline (2-stage, async reset)"),
      ("zs",  r"\quad + split-enable zero-skip"),
      ("dsp0",r"DSP-packed, gating off"),
      ("dsp", r"\quad + split-enable zero-skip")]
L=[r"\begin{table}[t]",
   r"\caption{Dynamic power (mW) at matched operand sparsity}",
   r"\label{tab:power}",r"\centering\footnotesize",
   r"\setlength{\tabcolsep}{4.5pt}",
   r"\begin{tabular}{l"+"c"*len(SP)+"}",r"\toprule",
   r"Design & \multicolumn{%d}{c}{operand sparsity $s$ (\%%)}\\"%len(SP),
   r"\cmidrule(l){2-%d}"%(len(SP)+1),
   " & "+" & ".join(SPL[s] for s in SP)+r"\\",r"\midrule"]
for t,n in NAME:
    L.append(n+" & "+" & ".join("%.0f"%d[(t,s)] for s in SP)+r"\\")
    if t in ("zs","dsp"):
        ref = "base" if t=="zs" else "dsp0"
        L.append(r"\quad\emph{change vs.\ its control} & "+
                 " & ".join(r"\emph{%+.0f\%%}"%(-100*(d[(ref,s)]-d[(t,s)])/d[(ref,s)]) for s in SP)+r"\\")
        if t=="zs": L.append(r"\midrule")
L+=[r"\midrule",
    r"clock component (baseline) & "+" & ".join("%.0f"%c[("base",s)] for s in SP)+r"\\",
    r"\bottomrule",r"\end{tabular}",r"\\[2pt]",
    r"\raggedright\scriptsize Vivado \texttt{report\_power}; confidence Medium.",
    r"Each design is compared against its own structural control at the same",
    r"sparsity, because the ungated baseline itself loses 31\,\% of its power",
    r"between $s=0$ and $s=0.9$ from reduced multiplier switching alone.",
    r"The DSP-packed rows understate the gating benefit: see",
    r"Section~\ref{sec:results}-E.",
    r"\end{table}"]
open("tab_power.tex","w").write("\n".join(L)+"\n")
print("\n".join(L))
