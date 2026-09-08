# Synthesis, implementation and power flow

Everything here targets **xc7a100tcsg324-1** with **Vivado 2023.2**, out of
context, at a 4.0 ns clock target.

## Why out-of-context

The cascade exposes 311 ports against 210 user I/O on any Artix-7 package, so
`-mode out_of_context` is *required*, not merely convenient. It is also the
right choice for this study, because it keeps I/O buffer power out of a
comparison that is about datapath gating.

## Order to run things

| Step | Script | Produces |
|---|---|---|
| 1 | `run_build.bat` | `base`, `zs`, `ir` checkpoints + `rpt/summary_area.csv` |
| 2 | `run_build2.bat` | `dsp`, `dsp0` checkpoints (appends to the same CSV) |
| 3 | `run_power.bat` | RTL-SAIF power, `rpt/summary_power.csv` |
| 4 | `run_power_post.bat` | post-implementation SAIF attempt (see caveat below) |

`build.tcl` takes `<top> <tag> <part> <period_ns>`. Checkpoints, SAIF files and
netlists are gitignored because they are large and fully regenerable.

## The five designs

| tag | top module | what it is |
|---|---|---|
| `base` | `mac_cascade_top` | ungated reference, 2-stage, async datapath reset |
| `zs` | `mac_cascade_zs_top` | split-enable zero-skip, gates the product register |
| `ir` | `mac_cascade_zs_ir_top` | adds gated operand registers, async reset (fails timing) |
| `dsp` | `mac_cascade_zs_dsp_top` | same, no datapath reset — DSP48 packs |
| `dsp0` | `mac_cascade_dsp_nogate_top` | `dsp` with gating disabled: the control |

`dsp0` exists so the cost of the *gating* can be separated from the cost of
the extra pipeline stage and the reset-style change. Comparing `dsp` against
`base` conflates all three.

## What is trustworthy in `rpt/`

**Trust:** `summary_area.csv` and the `*_impl_util.rpt` / `*_timing.rpt` /
`*_synth_util.rpt` files. These are deterministic and were regenerated after a
constraints bug was fixed (see below).

**Trust with the stated caveat:** `power_<tag>_s<N>.rpt` and
`summary_power.csv`. Vivado reports confidence *Medium* with only 12–13 % of
design nets annotated from simulation. Comparisons are therefore only made
between designs of identical structure at identical sparsity, never across
structures or across sparsity levels. `summary_power.csv` also contains a few
duplicate rows because two sweeps briefly ran concurrently; the duplicated
values agree, and the curated data actually used in the paper is
`../paper/data_power_rtl.csv`.

**Do not trust:** anything named `powerpost_*`. Those came from an attempt to
drive power from post-implementation netlist simulation. It did not work — net
matching did not improve, and a cmd `FOR`+`CALL` scoping bug meant several runs
simulated sparsity 0 while being labelled otherwise. The files are deleted
rather than kept, and the limitation is stated in the paper instead of hidden.

## Two bugs worth remembering

1. **Do not false-path the input ports.** An earlier version of `build.tcl`
   did, which excluded the multiplier-input paths of the two-stage designs from
   timing analysis entirely and made the whole Fmax column meaningless. The
   current script budgets 20 % of the period as input/output delay so every
   path is timed uniformly.

2. **cmd nested `FOR` + `CALL` mis-scopes loop variables.** This silently ran
   sweep points at the wrong sparsity while labelling them correctly. Both
   `run_power_post.bat` and `fill_base.bat` therefore use a flat, explicit call
   list and write their defines into a generated config file rather than
   passing multiple `-d` options through the xvlog `.bat` wrapper, which is
   also unreliable (it splits on `=`).

## Environment notes

- `xelab` needs `-timescale 1ns/1ps`: the RTL declares no timescale, the
  testbench does.
- SAIF paths inside an xsim Tcl script must use forward slashes. A Windows
  path is treated as containing Tcl escapes and the file is silently not
  written.
- A stale `.Xil/` directory makes `synth_design` fail with
  `couldn't read file .../realtime/<top>.tcl`. The build scripts delete it
  first.
