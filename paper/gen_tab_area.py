L = r"""\begin{table}[t]
\caption{Out-of-context implementation on \PART, 4.0\,ns target}
\label{tab:area}
\centering\footnotesize
\setlength{\tabcolsep}{4pt}
\begin{tabular}{lccccc}
\toprule
Design & LUT & FF & CARRY & DSP regs$^{\dagger}$ & $F_{\max}$\\
       &     &    &       & A/B/M/P              & (MHz)\\
\midrule
\multicolumn{6}{l}{\emph{2-stage pipeline, asynchronous datapath reset}}\\
\quad Baseline               & 789 & 546 & 127 & 0/0/0/8 & 269.8\\
\quad + split-enable zero-skip & 890 & 568 & 127 & 0/0/0/8 & 272.7\\[2pt]
\multicolumn{6}{l}{\emph{3-stage pipeline, asynchronous datapath reset}}\\
\quad + gated operand regs   & 906 & 840 & 127 & 0/0/0/8 & \textbf{202.6}\\[2pt]
\multicolumn{6}{l}{\emph{3-stage pipeline, no datapath reset}}\\
\quad control, gating off    & 413 & 298 &  63 & 8/8/8/8 & 271.7\\
\quad + gated operand regs   & 530 & 328 &  63 & 8/8/8/8 & \textbf{283.0}\\
\bottomrule
\end{tabular}
\\[2pt]
\raggedright\scriptsize $^{\dagger}$Number of the eight DSP48E1 slices whose
A, B, M and P pipeline registers are used. All designs infer 8 DSP48E1 and
no BUFGCE.
\end{table}
"""
open("tab_area.tex","w").write(L)
print(L)
