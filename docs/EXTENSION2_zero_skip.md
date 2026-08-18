# Extension #2 — Sparsity-Driven Zero-Skip Gating

Design, verification, prior-art assessment, and power estimate.
Companion to the base `completion_aware_gate` cascade. All numbers below are
reproduced by `run_tests.bat` on the local Icarus install.

---

## 1. What was built

| File | Role |
|---|---|
| `rtl/zero_skip_gate.v` | Wraps `completion_aware_gate`, adds zero detect, emits a **split** clock-enable |
| `rtl/pipelined_mac_zs.v` | Zero-skip MAC. Per-item skip tag piped alongside `valid_pipe` |
| `rtl/adder_tree_stage_zs.v` | Tree with **hierarchical sparsity propagation** via `update_in` |
| `rtl/mac_cascade_zs_top.v` | Port-compatible sparse cascade |
| `rtl/pipelined_mac_zs_ir.v` | Input-registered variant — the one that actually saves multiplier power |
| `tb/tb_zero_skip.v` | Cycle-for-cycle equivalence vs the verified baseline + 11 directed edge cases |
| `tb/tb_sparsity_sweep.v` | Activity vs sparsity, 0–95% |
| `tb/tb_zero_skip_ir.v` | Correctness + multiplier-input toggle measurement |
| `negctl/` | The **naive** design, kept deliberately, as a negative control |

`completion_aware_gate.v` and all four original files are **unmodified**. The
baseline stays a golden reference rather than becoming a memory of one.

---

## 2. The finding that determined the whole design

Before writing any code, the baseline's actual gating window was measured
(single item, 8 lanes):

```
cyc=2  vin=1  MAC0: ce=1 oa=0 drain=0                <- trigger, ce via trigger_in
cyc=3         MAC0: ce=1 oa=1 drain=2  mult=30 vpipe=1
cyc=4         MAC0: ce=1 oa=1 drain=1  acc=30 vout=1  <- completion fires HERE
cyc=5         MAC0: ce=0 oa=0 drain=0                <- ce already down
```

**`ce` is high for exactly three cycles and `completion_out` fires on the
last one.** The adder tree is the same shape: `ce` high cycles 4–7,
`sum_valid` latched on the edge ending cycle 7. There is **zero slack** in
either drain window.

Consequence: the literal reading of extension #2 — "when either operand is
zero, suppress the MAC's clock-enable for that cycle" — is **unsafe**. A zero
arriving at cycle T+1 or T+2 lands inside the drain window of the *non-zero*
item that entered at T, and masking the shared `ce` strands that item's
accumulate permanently.

This is not a theoretical worry. It is measured — see §4.

### The three edge cases, resolved

| Case | Hazard | Resolution |
|---|---|---|
| **Zero mid-burst** | Zero cycle must not suppress the accumulate of the item that entered one cycle earlier | Skip decision travels *with the item* as `skip_pipe`; stage 2 consults its own item's tag, never the current input bus |
| **Zero at burst start** | Gating the trigger means the pipeline never starts; whole burst lost | Trigger is the **raw** `valid_in`. The drain counter never sees sparsity at all |
| **Zero at burst end** | The killer. Trailing zero sits inside the preceding item's drain window | Enable is **split**: `ce_ctrl` (drain/validity) is never masked; only the wide datapath registers are gated |

### The mechanism: split the enable, don't mask it

```
ce_ctrl = completion_aware_gate(trigger_in = valid_in)   // NEVER masked
ce_mult = ce_ctrl & valid_in  & ~skip                    // 32-bit product reg
ce_acc  = ce_ctrl & valid_pipe & ~skip_pipe              // 32-bit accumulator
```

The drain counter is structurally blind to sparsity, so no zero pattern can
shorten, extend, or corrupt it. Correctness stops depending on careful
sequencing and starts depending on topology.

Cost of *not* gating the ~3 control flops: negligible. They are 3 of ~67 flops
in the lane. Buying them back would require perturbing completion timing,
which the zero-slack window makes unsafe. Bad trade, declined.

**Losslessness.** For unsigned operands `(a==0 || b==0)` implies `a*b==0`
exactly. This is not an approximation technique. Results are bit-identical;
only power changes.

### Bonus: a pre-existing inefficiency, fixed for free

`ce_mult` includes `& valid_in`. The baseline reloads `mult_stage` on *every*
`ce` cycle, including the two drain cycles at the end of every burst, when the
bus holds stale data that `valid_pipe` guarantees is never consumed. That is a
real waste in the original design, present even at 0% sparsity. It costs
nothing to fix and shows up in the bursty-traffic numbers.

### One thing deliberately *not* done

`AGGRESSIVE_IDLE` (default 0, provided only so the trade is measurable) also
strips zeros from the trigger, letting the gate fully idle during long zero
runs. It is **not recommended**: it changes observable semantics (an all-zero
burst emits no completion pulse), and it buys only those 3 control flops. The
parameter exists to be measured and rejected, not used.

---

## 3. Hierarchical sparsity propagation (the cascade-level part)

Per-MAC zero-skip is a local trick. The cascade makes a stronger claim
available.

Each MAC exports `update_out` = "my accumulator actually moved", registered on
the same edge as `valid_out`, so it is phase-aligned with `completion_out`.
The tree uses it:

```
l1_en[j] = update_in[2j] | update_in[2j+1]
l2_en[k] = l1_chg[2k]    | l1_chg[2k+1]      (l1_chg = registered l1_en)
l3_en    = |l2_chg
```

Each change-flag is registered on the same edge as the data it guards, so the
flags shift up the tree in lockstep with the partial sums they describe.

**Why it is exact:** if neither MAC feeding a level-1 adder changed, that
adder's inputs did not change, so its output would be identical — holding the
register is bit-exact, not approximate. Note this exploits *unchanged-ness*,
not *zero-ness*: the tree sums accumulators, which are persistent state and
rarely zero. That is a different mechanism from operand-zero gating.

**Honest scope:** this is second-order. The tree is 7 adders against 8
multipliers, and a level-1 pair only idles when *both* its MACs idle — under
unstructured sparsity `s` that is `s^2`. Measured at `s=0.48`: 22.7% L1 saving
against a predicted 23%; L2 5.4% predicted vs 4.9% measured. The model holds,
but the magnitude is small. It matters for structured/block sparsity and it is
what makes this a cascade contribution rather than a per-MAC one. It is not
where the power is.

---

## 4. Verification

### Method

The baseline is already verified (0 errors), so it is used as a **golden
reference**. Both cascades are driven from the same stimulus wires and
compared **cycle-for-cycle** on `(result, result_valid)`. Since zero-skip is
lossless by construction, *any* divergence on *any* cycle is a bug. That is a
much stronger claim than "the final number looked right".

Layered on top:
- an **independent absolute model** tracking per-lane expected accumulators, so
  a fault corrupting both DUTs identically would still be caught;
- **11 directed edge cases** (Z1–Z11) plus a 400-cycle randomized sparse stream;
- **activity counters** on the wide-register enables — the power numbers are
  measured, not assumed.

### Results — all pass

```
Z1  zero mid-burst                    Z7  full level-1 pair idle
Z2  zero at burst start               Z8  isolated bursts, alternating sparsity
Z3  zero at burst end  [the case]     Z9  partial valid_in mask + sparsity
Z4  all-zero burst                    Z10 400-cycle randomized stream
Z5  12-cycle zero run, then resume    Z11 gates return to idle
Z6  per-lane heterogeneous sparsity

636 cycles compared, 0 divergences.
RESULT: PASS - zero-skip is cycle-for-cycle identical to baseline
```

### Negative control — proving the test can fail

A passing equivalence test is worthless until it is shown to fail on a design
that is actually wrong. `negctl/pipelined_mac_naive.v` implements the literal
brief (`ce = ce_raw & ~(valid_in & operand_zero)`) and is run alongside:

```
result_valid pulses  reference : 208     <- non-vacuity check
result_valid pulses  shipped   : 208
result_valid pulses  NAIVE     : 77      <- 131 results silently dropped (63%)

divergences  SHIPPED vs ref : 0
divergences  NAIVE   vs ref : 278 / 284 cycles
```

The naive design does not merely produce wrong sums — it **stops producing
results at all** for most bursts. This is the concrete cost of masking a
shared enable in a pipeline whose drain window has no slack.

### Sparsity sweep — continuous traffic, 500 cycles/point

Continuous `valid_in` so drain overhead is amortised away and the numbers
isolate the pure sparsity effect.

| sparsity | mult-reg loads | acc-reg loads | tree L1 | tree L2 | divergences |
|---|---|---|---|---|---|
| 0%  | 0.0%  | 0.0%  | 0.0%  | 0.2%  | 0 |
| 12% | 12.1% | 12.1% | 1.7%  | 0.2%  | 0 |
| 24% | 23.0% | 23.0% | 5.2%  | 0.7%  | 0 |
| 36% | 36.9% | 36.9% | 14.0% | 2.1%  | 0 |
| 48% | 47.6% | 47.6% | 22.7% | 4.9%  | 0 |
| 60% | 58.3% | 58.3% | 33.8% | 11.4% | 0 |
| 72% | 71.3% | 71.3% | 50.3% | 27.0% | 0 |
| 84% | 83.9% | 83.9% | 70.6% | 50.1% | 0 |
| 95% | 95.1% | 95.1% | 90.7% | 82.0% | 0 |

MAC-level activity tracks sparsity 1:1, exactly as a lossless scheme must.
Tree levels track `s^2` and `s^4`. Zero divergences at every point.

---

## 5. The number that does not mean what it looks like

**`tb_zero_skip` reports "64% reduction in mult-reg loads". Most of that is
not multiplier power.**

`pipelined_mac_zs` gates the `mult_stage` *register*. But the multiplier is
combinational between the `a`/`b` ports and that register, and `a`/`b` keep
changing every cycle regardless of the enable. The partial-product array keeps
switching. Gating the output register saves 32 flops of load; it does not quiet
the ~270-LUT multiply array behind them.

`rtl/pipelined_mac_zs_ir.v` fixes this with **gated operand registers**: on a
skipped item `a_reg`/`b_reg` hold, so the multiplier's inputs are stable and
its internal network does not switch.

Measured at 29% sparsity (`tb_zero_skip_ir`):

```
multiplier-input changes, plain zero-skip  : 2661
multiplier-input changes, input-registered : 1009    -> 62% reduction
```

Plain zero-skip scores **0%** on this metric — its multiplier-input activity is
identical to the baseline's. The gap between those two rows is real power that
register-load counts claim but do not deliver.

**Cost:** one extra pipeline stage, so latency +1 cycle and `DRAIN_DEPTH` 2->3.
That one-line parameter change is the *entire* adaptation — nothing else in the
gating logic moves. A small but real vindication of parameterising the gate by
drain depth in the first place.

**Bonus:** this is also the shape Vivado wants for DSP48 packing. A/B input
registers map onto the DSP48's own A/B registers with `CEA`/`CEB`, so the
gating is absorbed into the hard block rather than costing fabric — which also
addresses the "DSP48 inference risk" already flagged in the README.

Verified numerically correct against the independent model on all edge cases
(cycle-equivalence is the wrong check here — it is deliberately one cycle later).

---

## 6. Power estimate

### Model

Relative combinational weights (Xilinx 7-series LUT-equivalents):
16x16 multiply ~ 270, 32-bit add ~ 32, tree L1/L2/L3 ~ 132/68/35.

- Array = 91.1% of cascade datapath (multiply 81.4%, accumulate-add 9.7%)
- Tree = 8.9%

Saving at sparsity `s`, **with input registers**:

```
saving(s) = 0.814*s + 0.097*s + 0.089*(0.562 s^2 + 0.289 s^4 + 0.149 s^8)
```

### Result, compounded onto the base ~41%

Taking the README's ungated->gated figure (100 -> 59) and assuming the cascade
datapath is ~80% of what remains:

| operand sparsity | datapath saving | incremental vs gated design | **overall vs ungated** |
|---|---|---|---|
| 30% | 27.8% | 22% | **~54%** |
| 50% | 47.0% | 38% | **~63%** |
| 70% | 66.9% | 54% | **~73%** |

### What these numbers are not

Read these as order-of-magnitude, +/-15 points, not as results.

1. **Not measured.** Activity-model derived. No Vivado `report_power` run, no
   SAIF, no post-synthesis netlist. The base 41% was itself back-of-envelope —
   compounding two estimates compounds two error bars.
2. **Assumes the input-registered variant.** Plain `pipelined_mac_zs` delivers
   materially less, for the reason in §5.
3. **Clock-tree power not modelled.** Separate enables per register bank should
   yield separate ICGs, which helps, but the clock still reaches the lane.
4. **Zero-detect logic costs something.** Two 16-input NORs per lane —
   negligible area/power, but it sits on the enable path, so the risk it
   introduces is *timing*, not power. `ce` fan-out was already flagged as a
   likely critical path; this adds to that cone. Needs STA.
5. **Sparsity assumption is doing a lot of work.** Post-ReLU CNN activation
   sparsity is commonly 40–70%, but if `b` is an unpruned weight then only
   `a`-side zeros count. On dense workloads `s~0` and this extension yields
   **nothing** while costing area and a timing risk.
6. **Biggest caveat: this saves compute power, not data-movement power.**
   Zeros are still fetched, still cross the bus, still occupy a pipeline slot.
   Eyeriss/SCNN/Cnvlutin get most of their win from *not moving* zeros. In a
   real accelerator, data movement usually dominates compute. This extension
   does not touch it.

---

## 7. Prior-art and novelty assessment

You asked me to actually check rather than tell you what you want to hear.
Here is what I found.

### The core idea is not novel. It is directly anticipated.

**Electronics 15(11):2492, June 2026** — "RTL-Level Power Optimization of CNN
Accelerators via Clock Gating and Sparsity-Aware MAC Suppression on FPGA"
(https://doi.org/10.3390/electronics15112492). A zero-detection block before
the multiplier stage, with enable:

> **EN_MAC = valid AND (A != 0) AND (B != 0)**

That is extension #2's literal statement, published two months ago, with
measured FPGA power numbers (32.99% reduction). The title is nearly your
project's title. This is the single most damaging reference.

**Imagination Technologies, CN110007896B** (priority 2017) — "Hardware unit
with clock gating for performing matrix multiplication"
(https://patents.google.com/patent/CN110007896B/en). Claims gating storage
elements when a data element "is known to have or may be considered to have
zero value", applied across the multiplier stage **and the adder tree**. This
covers both the per-MAC zero gating *and* tree-level zero gating.

**Google, US9818059B1 / US11106606B2** (priority Oct 2016) — exploiting input
sparsity in NN compute units, including a mode where a control signal prevents
the multiply on detecting a zero activation.
(https://patents.google.com/patent/US9818059B1/en)

**Academic:** zero-skipping dates to 2016 — Eyeriss (Chen/Emer/Sze), Cnvlutin
(Albericio et al.), Cambricon (Liu et al.), then ZeNA, SCNN, Samsung's
sparsity-aware NPU (ISCA 2021). Roughly a decade of prior art.

### The base design's claim is also weaker than the README assumes

The README nominates "cascaded hierarchical completion-aware gating — each
stage autonomously manages its own drain and propagates completion downstream,
with no centralized controller" as the strongest novelty candidate. But
**IBM US7308593B2 / US7065665B2** (2005–2007), "Interlocked synchronous
pipeline clock gating" (https://patents.google.com/patent/US7308593), already
claims stages that individually and locally gate their own clocks, propagate
valid forward, and propagate delayed stall signals backward — explicitly
"distributed, local decision-making rather than centralized control".

The mechanism differs (IBM uses stall-signal propagation; yours uses a
per-stage drain counter) but the *architectural claim* is the same one. That
claim is not available.

### What I could not find prior art for

Searching specifically for the interaction — operand-zero skipping applied to a
pipeline whose enable is held by a completion/drain counter, and the hazard of
a zero landing inside another item's drain window — returned nothing. The MDPI
paper has no drain counter at all (its pipeline simply holds state when
`valid=0`), so the composition never arises there. Imagination's is
zero-forcing at the storage element, not drain-preserving.

So the genuinely new content is narrow and specific:

> `EN_MAC = valid AND (A!=0) AND (B!=0)` is safe in a pipeline without
> completion-aware drain gating, but is **not composable** with drain-counter
> gating — applied there it drops 63% of results. Safe composition requires
> splitting the enable into a never-masked control enable and a sparsity-gated
> datapath enable, with the skip decision tagged per item.

### Verdict: not patentable

Be clear-eyed about it:

- The **core idea** is anticipated by a 2026 paper and a 2017 patent. Dead on
  novelty (§102-equivalent).
- The **split-enable discipline** is new as a documented composition, but it is
  the combination of two standard techniques — per-item valid/skip tagging is
  textbook pipeline practice, zero-skip is a decade old. Any competent RTL
  engineer told "make zero-skip work in a drain-gated pipeline" would arrive
  here. That is close to the definition of obvious (§103-equivalent). A filing
  would very likely fail, and would cost real money to find out.
- The **hierarchical update-propagation** in the tree is the most interesting
  piece, but it is second-order in power and conceptually adjacent to
  well-established computation-reuse / silent-store ideas.

Do not file. The README's plan — publish first, patent before publication —
should be simplified to just: publish.

### What it *is* good for

Two things, and they are not nothing:

1. **A publishable engineering note.** "Sparsity gating is not composable with
   completion-aware drain gating" is a real, specific, reproducible result with
   a measured failure mode and a clean fix. The negative control is the
   contribution. Given the MDPI paper is two months old and uses exactly the
   `EN_MAC` form, a short paper showing that form's composition hazard —
   with a runnable counterexample — is timely and citable. That is a much more
   defensible framing than "novel architecture".

2. **Strong interview material — arguably stronger than a patent would be.**
   What this now demonstrates is not an idea but a *method*: measure the
   timing before designing, reason the edge cases through first, build a
   negative control to prove the test can fail, then find and quantify the gap
   between the flattering metric (register loads) and the real one (multiplier
   input toggles). Interviewers at inference-accelerator teams have seen
   endless zero-skip projects. They have seen far fewer candidates who caught
   that their own headline number was mostly not real and said so.

---

## 8. Recommended next steps

1. **Vivado synthesis + `report_power` with a real SAIF.** Every number in §6
   is a model. Until there is a post-route power report, all of it is a
   hypothesis. This is now the single highest-value action.
2. **Confirm DSP48 inference for `pipelined_mac_zs_ir`.** The input-registered
   shape should map cleanly onto DSP48 A/B/M/P registers with `CEA/CEB/CEM/CEP`.
   If it does, the DSP-packing risk in the README is retired.
3. **STA on the `ce` cone.** Zero-detect adds to an enable path already flagged
   as a likely critical path.
4. **Re-frame the paper** around composability + the negative control, not
   novelty of zero-skip.
5. Lower priority: extension #3 (runtime-configurable drain depth) is a natural
   follow-on — §5 already demonstrated the 2->3 retarget by hand.
