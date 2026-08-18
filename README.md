# Completion-Aware Clock-Gated Parallel MAC Array — Project Context

## Background

Started as a review/correction of a hand-written Verilog design: an 8-lane
parallel MAC array (`mac_array_custom`) built from `pipelined_mac` units,
each with a 2-stage pipeline (multiply, then accumulate) and a custom
clock-gating scheme driven by data validity rather than a naive always-on
clock.

## Architecture Evolution (in order)

1. **Original design (buggy)** — had a swapped `endmodule` ordering, a
   `valid_out` that asserted one cycle too early, an `operation_active`
   tracker that cleared before the pipeline actually drained, and an
   unguarded accumulator.
2. **Corrected single-array design** — fixed all four bugs. Added a 2-bit
   `drain_count` so the clock-enable (`ce`) stays high for exactly 2 cycles
   after `valid_in` deasserts (matching the 2-stage pipeline depth), a
   `valid_pipe` register to correctly delay validity by one cycle, and
   guarded the accumulator so it only updates on real data.
3. **Cascaded hierarchical extension (current)** — extracted the gating
   logic into a standalone, reusable `completion_aware_gate` module
   (parameterized by `DRAIN_DEPTH`), refactored `pipelined_mac` to use it,
   and added a second pipeline stage — a 3-level registered adder tree
   (`adder_tree_stage`) that sums all 8 MAC outputs. The adder tree has its
   *own* completion-aware gate (`DRAIN_DEPTH=3`) and is triggered entirely
   by the OR of all 8 MACs' `completion_out` signals — no shared/centralized
   controller. This is the "cascade": each stage owns its own drain state
   and wakes the next stage via a completion pulse.

## Files (all in `rtl/`)

- `completion_aware_gate.v` — reusable gating cell, parameterized drain depth
- `pipelined_mac.v` — 2-stage MAC using the extracted gate; exposes
  `completion_out` distinct from `valid_out` for cascade triggering
- `adder_tree_stage.v` — 3-level binary adder tree, second cascade stage
- `mac_array_and_cascade_top.v` — contains both `mac_array_custom` (8-lane
  array wrapper) and `mac_cascade_top` (full MAC array → adder tree cascade)
- `tb_cascade.v` — Icarus Verilog testbench, **verified passing (0 errors)**

## Verification Status

Run with: `iverilog -g2012 -o sim rtl/*.v && vvp sim`

Three tests, all passing:
- **T1** — single burst across all 8 MACs → correct summed result via the
  full cascade (MAC drain + tree drain timing both correct)
- **T2** — back-to-back bursts, confirms accumulator is cumulative (by
  design, no auto-reset) and cascade still resolves correctly
- **T3** — confirms both the MAC gates and the tree gate actually return to
  `operation_active = 0` (truly idle) after draining

### Real bug found and fixed during verification (worth remembering)

Original gate logic: `ce = primary_enable | operation_active`.
`operation_active` is registered, so it lags `trigger_in` (`valid_in`) by
one cycle — this silently dropped the *first* valid cycle of every burst,
since `ce` was low exactly when data first arrived. Fixed by making `ce`
combinationally responsive: `ce = primary_enable | operation_active |
trigger_in`. Caught this via simulation (`result_valid` never asserted),
not by inspection — underscores the value of actually simulating rather
than trusting a code review alone.

## Design Rules Established

- **Drain counter = pipeline depth downstream of the trigger.** For the
  2-stage MAC, drain = 2. For the 3-level adder tree, drain = 3. Too short
  drops in-flight results; too long just wastes a cycle of idle `ce`.
- **CE-based gating (not literal clock gating in RTL).** We deliberately
  gate the data path (`if (ce) ...`) rather than writing `clk & ce`
  ourselves — this avoids glitch-prone combinational clock gating and lets
  the synthesis tool (Vivado) infer a proper glitch-free ICG cell
  automatically. The RTL guarantees the *data path* stops toggling
  (dominant power saving) regardless of whether the tool inserts a true ICG.
- **`+:` variable-base part-select** is what makes the packed bus slicing
  in the generate loop possible, since Verilog requires slice width to be
  constant.

## Open Items / Not Yet Done

- No formal power estimate from actual Vivado synthesis yet — earlier
  numbers (~33 mW saved at 8 MACs / 40% activity, ~41% reduction) were
  back-of-envelope using typical DSP48E1 power figures, not measured.
- No synthesis run yet to confirm DSP48 inference vs LUT-based multiply —
  flagged as a risk if the gating control logic breaks Vivado's DSP
  packing heuristic.
- No timing closure / STA run — flagged likely critical paths: multiply→
  accumulate chain, and the `ce` fan-out into all pipeline registers.
- `mult_stage <= a * b` originally had a silent width-truncation bug
  (result width = operand width, not accumulator width) — fixed with
  explicit zero-extension in the current `pipelined_mac.v`. Worth
  double-checking this pattern doesn't recur in the adder tree.

## Target Direction — Why We're Extending This

Discussed patentability of the base design (probably not — individual
techniques like drain-counters and CE gating are well established in
literature/industry, e.g. ARM Cortex, Xilinx DSP48 app notes). Identified
**cascaded hierarchical completion-aware gating** — where each stage
autonomously manages its own drain and propagates completion downstream,
with no centralized controller — as the strongest candidate for genuine
novelty, since this specific combination isn't a documented pattern.

### Other extension directions discussed (not yet started), ranked by
### patentability/practical value:

1. **Cascaded hierarchical gating** ← currently being built (this repo)
2. **Sparsity-driven zero-skip gating** — detect zero-valued operands and
   suppress `ce` for that cycle without losing drain-counter state;
   directly relevant to CNN inference sparsity, high practical value
3. **Dynamic/runtime-configurable drain counter** — load `DRAIN_DEPTH` from
   a mode register instead of a fixed parameter, for multi-mode pipelines
4. **Look-ahead / predictive CE** — pre-assert `ce` one cycle before
   predicted data arrival based on observed `valid_in` stream periodicity
5. **Two-level group gating** — coarse group-level CE (any MAC in a group
   active) + fine per-MAC CE, to also cut clock-tree power, not just
   datapath power

### Intended path if pursuing IP
Publish the base architecture (IEEE Access paper, already in progress —
related to the Tsukuba nano-UAV research thread) first to establish
contribution. Any patent filing would need to happen *before* publication
of whichever specific extension is chosen, since publication kills novelty
in most jurisdictions. Realistic next step: prototype extension #2
(sparsity-driven gating) since it's both the most novel-adjacent AND has
the most direct tie to CNN inference sparsity, which is directly relevant
to job-target companies working on inference accelerators.

## Target Context for Research

FPGA/RTL/ASIC engineering role search, Asia-Pacific focus (Japan, Korea,
Taiwan, Singapore, Australia, Canada). This project is a portfolio /
interview-depth artifact as much as a research direction — interview
answers already rehearsed for: architecture explanation (1-2 min pitch),
synthesizability concerns (DSP48 inference, multiplier width truncation),
timing violation risk analysis, verification methodology, and power-saving
estimation methodology.

---

# UPDATE — Extension #2 implemented and verified (sparsity-driven zero-skip)

Full write-up: **`docs/EXTENSION2_zero_skip.md`**.
Reproduce everything: **`run_tests.bat`** (uses the Icarus in
`Downloads\oss-cad-suite`; note it sources `environment.bat` first — without
that, `iverilog` silently produces no output).

## New files

```
rtl/zero_skip_gate.v          split-enable gating cell (wraps, does not modify,
                              completion_aware_gate)
rtl/pipelined_mac_zs.v        zero-skip MAC, per-item skip tag
rtl/adder_tree_stage_zs.v     tree with hierarchical sparsity propagation
rtl/mac_cascade_zs_top.v      sparse cascade, port-compatible with the baseline
rtl/pipelined_mac_zs_ir.v     input-registered variant (see "the real number")
tb/tb_zero_skip.v             cycle-for-cycle equivalence + 11 edge cases
tb/tb_sparsity_sweep.v        activity vs sparsity 0-95%
tb/tb_zero_skip_ir.v          correctness + multiplier-input toggle measurement
negctl/                       the NAIVE design, kept as a negative control
run_tests.bat                 runs all five suites
```

The five original files are **unchanged**.

## The key design finding

The baseline drain window was measured before any code was written: MAC `ce` is
high for exactly 3 cycles and `completion_out` fires on the **last** one. The
tree is the same. **Zero slack.**

So the literal form of extension #2 — mask `ce` when an operand is zero — is
unsafe: a zero landing inside a preceding item's drain window strands that
item. Measured cost, via a deliberately-built naive implementation:
**131 of 208 results silently dropped (63%)**.

The shipped design **splits** the enable instead of masking it:

```
ce_ctrl = gate(trigger_in = RAW valid_in)     // never masked - drain is blind to sparsity
ce_mult = ce_ctrl & valid_in  & ~skip         // wide product register
ce_acc  = ce_ctrl & valid_pipe & ~skip_pipe   // wide accumulator
```

The skip decision travels with the item (`skip_pipe`), so stage 2 consults its
own item's tag rather than the current input bus. Correctness becomes
topological rather than sequencing-dependent.

## Verification status

All five suites pass on this machine:

- baseline regression — 0 errors (unchanged)
- zero-skip — **636 cycles compared, 0 divergences**, cycle-for-cycle identical
  to the verified baseline, plus an independent absolute model
- **negative control — the naive design is caught (278/284 cycles diverge)**,
  which is what proves the equivalence check is not vacuous
- sparsity sweep 0-95% — 0 divergences at every point
- input-registered variant — numerically correct on all edge cases

## The real number vs the flattering one

`tb_zero_skip` reports "64% fewer mult-reg loads". **Most of that is not
multiplier power.** Gating the product *register* does not stop the
combinational multiply array, because `a`/`b` still change every cycle.

`pipelined_mac_zs_ir.v` adds gated operand registers so the multiplier's inputs
actually hold. Measured at 29% sparsity:

```
multiplier-input changes, plain zero-skip  : 2661   (= baseline, i.e. 0% saved)
multiplier-input changes, input-registered : 1009   -> 62% reduction
```

Cost: +1 pipeline stage, `DRAIN_DEPTH` 2->3. That one parameter change is the
entire adaptation — which is a genuine vindication of parameterising the gate.
It should also improve DSP48 packing (A/B regs -> `CEA`/`CEB`).

## Power estimate (activity-model, NOT measured)

Compounded on the existing ~41% base figure, assuming the input-registered
variant:

| sparsity | overall reduction vs ungated |
|---|---|
| 30% | ~54% |
| 50% | ~63% |
| 70% | ~73% |

Treat as +/-15 points. No Vivado `report_power`, no SAIF, and the 41% base was
itself back-of-envelope. Also: this saves **compute** power only — zeros are
still fetched and still move across the bus, which in a real accelerator is
usually where the power actually goes.

## Novelty verdict: NOT patentable — do not file

- **Anticipated.** *Electronics* 15(11):2492 (June 2026) publishes exactly
  `EN_MAC = valid AND (A!=0) AND (B!=0)` with FPGA power numbers, under a title
  nearly identical to this project's. Imagination Technologies CN110007896B
  (2017) claims zero-based clock gating across both multiplier and adder tree.
  Google US9818059B1 (2016) covers zero-activation multiply suppression.
  Academic zero-skipping dates to 2016 (Eyeriss, Cnvlutin, Cambricon).
- **The base design's claim is weaker than assumed too.** IBM US7308593B2
  (2005-07) already claims per-stage local clock gating with distributed,
  non-centralized control and forward valid propagation.
- **What is actually new** is narrow: that the standard zero-skip enable is
  *not composable* with drain-counter gating, and the split-enable fix. That is
  a combination of two standard techniques — very likely obvious, and not worth
  a filing.

**Better path:** drop the patent track. Publish a short engineering note on the
**composability hazard**, with the negative control as the contribution — it is
specific, reproducible, and timely given the June 2026 paper. And as interview
material this is now stronger than a patent would have been, because what it
demonstrates is method: measure before designing, build a test that can fail,
and catch your own headline number being mostly unreal.

## Revised open items

1. **Vivado synthesis + `report_power` with a real SAIF** — highest value now.
   Every power figure above is a model, not a result.
2. Confirm DSP48 inference for `pipelined_mac_zs_ir` (would retire the existing
   DSP-packing risk).
3. STA on the `ce` cone — zero-detect adds to a path already flagged critical.
4. Re-frame the paper around composability, not novelty.
