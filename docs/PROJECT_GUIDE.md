# Completion-Aware Clock-Gated MAC Array — Complete Technical Guide

*A from-scratch explanation of what this project is, how every module works, why
each decision was made, what we measured, and where it stands as research.*

---

## How to use this document

Read Part 1 and 2 to rebuild the mental model. Part 3 is the module-by-module
reference — go there when you need to remember what a specific file does. Part 4
is the "why" behind every design decision, which is what interviewers actually
probe. Part 7 is a compressed interview crib sheet.

If you have ten minutes, read §1.4 (the one idea the whole project rests on),
§4.2 (the central design decision), and Part 7.

---

# PART 1 — The problem and the idea

## 1.1 What the hardware is

An **8-lane parallel MAC array feeding a 3-level adder tree.**

A MAC — multiply-accumulate — is the atom of neural-network inference:

```
acc = acc + (a × b)
```

Eight of them run side by side, each with its own accumulator. Their eight
accumulator values are then summed by a binary adder tree
(8 → 4 → 2 → 1) to produce one output. This is a dot-product engine: exactly
what a convolution or a fully-connected layer is made of.

Concretely, in this design:
- `DATA_WIDTH = 16` (16-bit unsigned operands)
- `NUM_MACS = 8`
- each MAC is 2 pipeline stages: **multiply**, then **accumulate**
- the adder tree is 3 registered levels

## 1.2 Why we care about power

In a MAC array, dynamic power is dominated by the **multiplier**. A 16×16
multiplier is roughly 250–300 LUTs on FPGA, or in ASIC terms an array of partial
products — about 8–10× the cost of the 32-bit adder next to it. Every cycle the
multiplier's inputs change, that whole array toggles and burns energy.

So the entire game is: **stop the multiplier from switching when its output
doesn't matter.**

There are two independent reasons its output might not matter:

1. **The stage is idle** — no valid data is flowing. → *clock gating*
2. **The data is ineffectual** — an operand is zero, so the product is zero and
   adding it changes nothing. → *zero-skipping / sparsity*

This project builds the first, then adds the second — and the whole research
contribution is the discovery that **the two do not combine safely** in the
obvious way.

## 1.3 Why sparsity is worth exploiting

After a ReLU activation, a large fraction of activations in a CNN are exactly
zero — commonly 40–70%. Pruned weights add more zeros. And critically:

```
a = 0  OR  b = 0   ⟹   a × b = 0     exactly
```

This is **lossless**. Skipping a zero-product multiply is not an approximation
technique; the arithmetic result is bit-identical. That property is what makes
the whole thing verifiable by exact equivalence checking later.

## 1.4 The one idea everything rests on: the drain window

This is the concept to hold onto.

**Naive clock gating**: enable the stage when data arrives.

```
ce = valid_in
```

This is *broken* for a pipeline. Consider a 2-stage MAC. Data arrives at cycle
T. At the end of T it lands in the multiply register. But the *accumulate* of
that same item happens at the end of cycle T+1 — and by then `valid_in` is low,
so `ce` is low, so the accumulate never happens. **The result is stranded inside
the pipeline.**

The fix is a **drain counter**. When new data arrives, load a counter with the
stage's pipeline depth D. Keep the enable asserted while the counter runs down.
That guarantees every in-flight item gets the cycles it needs to reach the
output before the stage goes to sleep.

```
on trigger:  drain_count <= D ; operation_active <= 1
otherwise:   drain_count <= drain_count - 1
             operation_active <= (drain_count > 1)

ce = primary_enable | operation_active | trigger_in
```

That is `completion_aware_gate.v`, and every stage in the design instantiates
one with its own D.

### The zero-slack property — memorise this

A drain counter is *correct* when D equals the stage's latency:
- **D too small** → in-flight data stranded (the bug above)
- **D too large** → wasted enable cycles, wasted power

So sizing it correctly makes the enable window **exactly as long as the pipeline
needs and not one cycle longer.** There is no spare cycle anywhere.

We measured this rather than assuming it. For a single item entering the MAC at
cycle T:

```
cyc  vin  ce  oa  drain  mult  vpipe  acc  vout
 T    1    1   0    0      -     -     -    -     <- trigger; ce via trigger_in
T+1   0    1   1    2     30     1     -    -
T+2   0    1   1    1     30     0    30    1     <- completion fires HERE
T+3   0    0   0    0     30     0    30    0     <- ce already down
```

`ce` is high for exactly three cycles, and `completion_out` fires on the **last
one**. The adder tree behaves identically over four cycles.

**Everything that follows is a consequence of this zero-slack property.** It is
why the obvious way to add sparsity gating destroys the design.

## 1.5 The cascade

There is no central controller. Each stage owns its own gate and its own drain
counter, sized to its own depth:

- MAC: `DRAIN_DEPTH = 2` (multiply, accumulate)
- adder tree: `DRAIN_DEPTH = 3` (three registered levels)

Stage 2 is triggered by the **OR of all eight MACs' `completion_out`** signals.
So stage 1 wakes stage 2 by telling it "fresh data is here — wake yourself for
your own drain duration." Each stage is autonomous; the wiring between them is a
single completion pulse.

That arrangement is what "cascaded completion-aware gating" means.

---

# PART 2 — The extension: sparsity-driven zero-skip

## 2.1 What we wanted

When an operand is zero, skip the multiply and save the power — **without**
disturbing the drain machinery, and without dropping or corrupting any result.

The obvious implementation, and the one used in published work
(Gohel et al., *Electronics* 15(11):2492, 2026):

```
EN_MAC = valid ∧ (A ≠ 0) ∧ (B ≠ 0)
```

Detect the zero, drop the clock enable for that cycle. Simple.

## 2.2 Why that is catastrophic here

The enable is **not private to the item arriving this cycle.** In a pipelined
stage, one enable clocks *every* register in that stage — including the
registers holding items that arrived earlier and are still draining.

Trace it. Non-zero item enters at T. Zero operand arrives at T+1.

- At T+1 the naive rule deasserts `ce`.
- But the accumulate of the item from T was *supposed* to happen at the end of
  T+1.
- It is deferred. Meanwhile the drain counter — which doesn't know about
  sparsity — keeps counting down.
- The enable window closes. The deferred accumulate never happens.
- **That result is gone permanently.**

Because the drain window has zero slack (§1.4), there is no later idle cycle
where the stranded item can catch up.

### How bad, measured

We built the naive version deliberately (`negctl/pipelined_mac_naive.v`) and ran
it against the verified baseline on identical stimulus:

```
result_valid pulses, reference : 208
result_valid pulses, naive     :  77     <- 131 results silently dropped (63%)
diverging cycles, naive vs ref : 278 / 284
```

It does not compute *wrong* sums so much as **stop computing.** 63% of results
never appear.

## 2.3 The three edge cases

| Case | What could go wrong | How it's handled |
|---|---|---|
| **Zero mid-burst** | The zero cycle must not suppress the accumulate of the item that entered one cycle earlier | The skip decision travels *with the item* as `skip_pipe`; stage 2 reads its own item's tag, never the current input bus |
| **Zero at burst start** | If the zero gates the *trigger*, the pipeline never starts and the whole burst is lost | The drain counter is triggered by the **raw** `valid_in`; it never sees sparsity at all |
| **Zero at burst end** | **The fatal one.** The trailing zero lands inside the drain window of the item before it | The enable is **split**: the control enable is never masked, only the wide datapath registers are gated |

## 2.4 The fix: split the enable, don't mask it

Stop treating the clock enable as one signal. Derive three:

```
ce_ctrl = completion_aware_gate(trigger_in = RAW valid_in)   // NEVER masked
ce_mult = ce_ctrl & valid_in   & ~skip                       // 32-bit product reg
ce_acc  = ce_ctrl & valid_pipe & ~skip_pipe                  // 32-bit accumulator
```

Two properties make this correct:

1. **The drain counter is structurally blind to sparsity.** It is fed the raw
   `valid_in`. No operand pattern can shorten, extend, or corrupt it. Correctness
   stops depending on careful sequencing and starts depending on *topology*.

2. **The skip decision is tagged per item.** `skip_pipe` is registered alongside
   `valid_pipe`, so the accumulate stage consults the tag belonging to *its own*
   item. The zero arriving at T+1 cannot suppress the predecessor's accumulate,
   because that predecessor carries `skip_pipe = 0`.

Only the two **wide** register banks get sparsity-gated. `mult_stage` and
`acc` are 64 bits of the roughly 70 flip-flops in a lane, so gating them
captures essentially all the available saving. The handful of control
flip-flops — `valid_pipe`, `skip_pipe`, `valid_out`, `update_out` and the
gate's own drain counter — stay ungated, because gating them would require
perturbing completion timing, which the zero-slack window forbids. Bad trade,
declined.

## 2.5 Hierarchical propagation into the tree

Per-lane skipping is a local trick. The cascade allows something stronger:

> If a lane's accumulator did not change, then every partial sum in the tree
> that depends only on unchanged accumulators is also unchanged, and its
> register can be **held** instead of reloaded.

Each MAC exports `update_out` — "my accumulator actually moved" — registered in
the same cycle as its completion output. From it:

```
l1_en[j] = update_in[2j] | update_in[2j+1]
l2_en[k] = l1_chg[2k]    | l1_chg[2k+1]      (l1_chg = registered l1_en)
l3_en    = |l2_chg
```

Each change-flag is registered on the same edge as the data it guards, so the
flags climb the tree in the same pipeline phase as the partial sums they
describe.

**Why it is exact**: holding a register whose inputs provably did not change is
bit-identical to reloading it. Note the exploited property is *unchangedness*,
not *zeroness* — the tree sums accumulators, which are persistent state and
rarely zero. That is a genuinely different mechanism from operand-zero gating of
adder trees, which is what Imagination's patent CN110007896B claims.

**Honest scope**: this is second-order. A level-1 adder only idles when *both*
its feeding lanes idle — probability `s²` under unstructured sparsity `s`.
Measured at s = 0.48: L1 saving 22.7% against `s² = 23%` predicted, L2 4.9%
against `s⁴ = 5.3%`. The model holds precisely, but the tree is 7 adders against
8 multipliers, so it is not where the power is. Don't oversell it.

---

# PART 3 — Module-by-module reference

Eleven modules across three groups: the **verified baseline** (untouched), the
**zero-skip extension**, and the **negative control** (deliberately wrong).

## 3.1 Baseline group

### `rtl/completion_aware_gate.v` — the reusable gating cell

**Purpose.** One parameterised gate any pipelined stage can instantiate to get
correct completion-aware clock enabling.

**Parameter.** `DRAIN_DEPTH` — the number of pipeline stages downstream of the
trigger. Set it to the stage's own latency.

**Ports.**

| Port | Dir | Meaning |
|---|---|---|
| `primary_enable` | in | external override, forces `ce` high regardless of state |
| `trigger_in` | in | asserted the cycle new valid data enters this stage |
| `ce` | out | the clock enable for this stage's registers |
| `operation_active` | out | exposed for cascading and debug visibility |

**Mechanism.**

```verilog
assign ce = primary_enable | operation_active | trigger_in;

if (rst)                    { operation_active <= 0; drain_count <= 0; }
else if (trigger_in)        { operation_active <= 1; drain_count <= DRAIN_DEPTH; }
else if (drain_count > 0)   { drain_count <= drain_count - 1;
                              operation_active <= (drain_count > 1); }
```

**The subtle part — why `| trigger_in` is in the `ce` equation.** This was a real
bug found in simulation, not by inspection. `operation_active` is a *register*,
so it lags `trigger_in` by one cycle. Without the disjunction, `ce` is low on
exactly the cycle the first data arrives, so **the first valid cycle of every
burst is silently dropped.** The symptom was `result_valid` never asserting at
all. Remember this one — it is the cleanest example in the project of why you
simulate rather than trust a code review.

**Counter width.** `CW = clog2(DRAIN_DEPTH+1)`, with a guard for
`DRAIN_DEPTH <= 1`.

---

### `rtl/pipelined_mac.v` — the 2-stage MAC

**Purpose.** One lane. Multiply, then accumulate, with completion-aware gating.

**Structure.**

```
        a,b ──► [ × ] ──► mult_stage ──► [ + ] ──► acc
                                          ▲
                                          └── acc (feedback)

        valid_in ──► valid_pipe ──► valid_out ( = completion_out )
```

- `DRAIN_DEPTH(2)` on its gate — two stages downstream of the trigger.
- `mult_stage` is `2*DATA_WIDTH` wide. The multiply is written with **explicit
  zero-extension**: `{{DW{1'b0}}, a} * {{DW{1'b0}}, b}`. Without that, Verilog
  computes the product at *operand* width and silently truncates — a real bug
  that was fixed earlier in the project's history.
- `valid_pipe` delays validity by one cycle to match the multiply stage.
- The accumulator is **guarded**: `if (valid_pipe) acc <= acc + mult_stage;` so
  it only absorbs real data.

**Why `completion_out` exists separately from `valid_out`.** In this 2-stage MAC
they happen to be the same signal. They are named separately because they mean
different things at the *interface*: `valid_out` is "my data is valid this
cycle", `completion_out` is "a pipeline slot completed here, downstream stage
please wake up." Keeping them distinct is what makes the module cascade-ready
without overloading one signal's meaning.

**Accumulator semantics.** `acc` is cumulative since reset — there is no
per-burst clear, by design. Test 2 in `tb_cascade.v` exists specifically to
confirm that.

---

### `rtl/adder_tree_stage.v` — the 3-level tree

**Purpose.** Sum the eight accumulators. Second stage of the cascade.

**Key point: it has no `valid_in` of its own.** Its gate is triggered by
`|completion_in` — the OR of all eight MACs' completion outputs. *That OR is the
cascade connection.*

**Structure.** 8 → 4 → 2 → 1, three registered levels, so `DRAIN_DEPTH = 3`.
Bit growth is handled explicitly: `level1` is `ACC_WIDTH+1`, `level2` is
`ACC_WIDTH+2`, `sum_out` is `ACC_WIDTH+3` (log2(8) = 3 guard bits).

**Validity tracking.** A 3-bit shift register `valid_shift` instead of the MAC's
single `valid_pipe`, because the tree is three levels deep.
`sum_out` updates on `valid_shift[1]`; `sum_valid` is driven from
`valid_shift[2]` — the oldest bit, meaning "a fully drained result".

**Unpacking the bus.** `acc_bus[gi*ACC_WIDTH +: ACC_WIDTH]` — the `+:`
variable-base part-select is what makes packed-bus slicing possible inside a
generate loop, because plain Verilog requires the slice *width* to be constant
while allowing the base to vary.

---

### `rtl/mac_array_and_cascade_top.v` — array wrapper + top

Contains two modules:

- **`mac_array_custom`** — a generate loop instantiating `NUM_MACS` lanes,
  slicing `a_bus`/`b_bus` and concatenating `acc_bus`, `valid_out`,
  `completion_out`.
- **`mac_cascade_top`** — wires the array to the adder tree. The only
  interesting line is `.completion_in(completion_bus)`: that single connection
  *is* the cascade.

---

## 3.2 Zero-skip extension group

### `rtl/zero_skip_gate.v` — the sparsity-aware gating cell

**Purpose.** Wraps — does **not** modify — the verified `completion_aware_gate`,
adding zero detection and producing the split enable.

**Why a wrapper rather than an edit.** The baseline gate is verified. Editing it
would mean the golden reference becomes a memory of one. Wrapping keeps the
verified module intact and testable.

**Zero detection.**

```verilog
assign operand_zero = ~(|a) | ~(|b);      // two DATA_WIDTH-input NORs
assign skip         = ENABLE_ZERO_SKIP[0] & valid_in & operand_zero;
```

Reduction-OR is the cheap form. It sits on the *enable* path, not the datapath,
so the risk it introduces is **timing**, not power.

**Outputs.**

| Port | Meaning |
|---|---|
| `ce_ctrl` | the unmodified completion-aware enable; drives only validity/skip tracking |
| `ce_mult` | `ce_ctrl & valid_in & ~skip` — gates the wide multiply register |
| `skip` | per-item tag, to be piped alongside the item |
| `operand_zero` | raw detect, for stats and debug |

**A free win hidden in `ce_mult`.** The `& valid_in` term is not about sparsity.
The baseline reloads `mult_stage` on *every* `ce` cycle — including the two
drain cycles at the end of every burst, when the bus holds stale data that
`valid_pipe` guarantees is never consumed. That is a genuine inefficiency in the
original design, present even at 0% sparsity, and it costs nothing to fix.

**Parameters.**
- `ENABLE_ZERO_SKIP` — set 0 and the module degenerates to exactly the baseline
  gate. This is what makes fair A/B controls possible.
- `AGGRESSIVE_IDLE` — **default 0, and deliberately not recommended.** When 1 it
  also strips zeros from the *trigger*, letting the gate fully idle during long
  zero runs. It buys about three control flip-flops and changes observable
  semantics: an all-zero burst emits no completion pulse. The parameter exists
  so the trade can be *measured and rejected*, not used.

---

### `rtl/pipelined_mac_zs.v` — zero-skip MAC

Kept as a **separate module** from `pipelined_mac.v` so both can be instantiated
in one simulation and proven cycle-for-cycle equivalent.

**What changed from the baseline:**

1. `skip_pipe` is registered in parallel with `valid_pipe` — the item carries
   its own skip decision.
2. `acc_update = valid_pipe & ~skip_pipe` guards the accumulator.
3. `mult_stage` is gated by `ce_mult` instead of `ce`.
4. New output `update_out` — registered `acc_update`, phase-aligned with
   `completion_out`.

**What deliberately did *not* change:** `valid_pipe`, `valid_out` and
`completion_out` are driven by `ce_ctrl` only. Their timing is bit-identical to
baseline for every input pattern. A skipped item still occupies its pipeline
slot and still emits a completion pulse, so the downstream cascade sees an
identical trigger stream.

**`completion_out` vs `update_out`:**

| Signal | Meaning |
|---|---|
| `completion_out` | "a pipeline slot completed here" — fires for skipped items too |
| `update_out` | stricter: "…and it actually moved my accumulator" |

---

### `rtl/adder_tree_stage_zs.v` — tree with sparsity propagation

The completion path — `trigger_in`, the gate, `valid_shift`, `sum_valid` — is
**byte-identical to the baseline tree.** Only register enables are added.

New input `update_in[NUM_MACS-1:0]`, from which the change-flag pipeline of
§2.5 is built. `ENABLE_ZERO_SKIP = 0` forces every enable high, giving exactly
the baseline tree.

The `l3_en` term guards `sum_out`: if nothing changed anywhere,
`sum_out` holds its previous value — which is correct, because the sum genuinely
did not change. `sum_valid` still asserts.

---

### `rtl/mac_cascade_zs_top.v` — sparse cascade

Port-compatible with `mac_cascade_top`, so the two can be driven by identical
stimulus and compared. **The only added wire between the stages is
`update_bus`** — the companion to the existing `completion_bus`. That single bus
is what turns a per-MAC trick into a cascade-level mechanism.

---

### `rtl/pipelined_mac_zs_ir.v` — input-registered variant

**Why it exists — and this is the most important lesson in the project.**

`pipelined_mac_zs` gates the `mult_stage` *register*. Activity counting there
suggests a 64% reduction in load events. **That number is mostly not real
multiplier power.**

The multiplier is *combinational* between the `a`/`b` ports and that register.
`a` and `b` keep changing every cycle regardless of any enable. Gating the
output register saves 32 flip-flops' worth of load and **nothing of the ~270-LUT
multiply array behind them.**

**The fix**: gated registers on the *operands*. On a skipped item `a_reg` and
`b_reg` **hold**, so the multiplier's inputs are stable and its partial-product
network does not switch.

Measured at 29% sparsity:

```
multiplier-input transitions, product-reg gated : 2661   (= baseline; 0% saved)
multiplier-input transitions, input-registered  : 1009   -> 62% reduction
```

**Cost**: one extra pipeline stage. Latency +1 cycle and `DRAIN_DEPTH` 2 → 3.
That one-line parameter change is the *entire* adaptation — a small but real
vindication of parameterising the gate by drain depth in the first place.

**Structure changes**: `valid_sr[1:0]` and `skip_sr[1:0]` are now 2-deep shift
registers instead of single bits, to match the extra stage.
`mult_load = ce_ctrl & valid_sr[0] & ~skip_sr[0]`,
`acc_update = valid_sr[1] & ~skip_sr[1]`.

**Verification note**: this variant is deliberately one cycle later than
baseline, so cycle-for-cycle equivalence is the *wrong* check. It is verified
against the independent absolute model instead.

---

### `rtl/pipelined_mac_zs_dsp.v` — DSP-friendly reset style

**Architecturally identical to `_ir`. The only difference is reset style.** And
that difference turned out to matter more than any architectural choice in the
project.

**The problem.** Post-implementation, Vivado reported `AREG = BREG = MREG = 0`
for every DSP48 — the DSP's own input and multiply pipeline registers were
unused, and `a_reg`/`b_reg` sat in fabric. The critical path became a fabric
flip-flop driving a DSP48 input pin with **zero logic levels** and mostly route
delay, missing a 250 MHz target by 0.94 ns.

**The cause.** DSP48E1 A/B/M pipeline registers support **only synchronous
reset**. Every datapath register in the original design carries an
*asynchronous* one, so none could ever be absorbed into the slice.

**The fix.** `a_reg`, `b_reg` and `mult_stage` carry **no reset at all.** They do
not need one — correctness is enforced by the valid/skip tags, and *those* are
reset. Control registers keep their async reset; they live in fabric anyway.

**Result**: `AREG = BREG = MREG = PREG = 8`. The accumulator's carry chain folds
into the DSP's own adder too, halving CARRY4 from 127 to 63.

**`mac_cascade_dsp_nogate_top`** in the same file is the structural control:
identical in every way with `ENABLE_ZERO_SKIP = 0`. It exists so the cost of the
*gating* can be separated from the cost of the extra stage and the reset change.
Comparing `dsp` against `base` conflates all three — a mistake that would have
made the gating look free when it isn't.

---

## 3.3 Negative control group

### `negctl/pipelined_mac_naive.v` — intentionally wrong

**Not part of the design.** It implements the literal instruction — detect a
zero operand, suppress the shared clock enable:

```verilog
wire ce = ce_raw & ~(valid_in & operand_zero);   // <<< THE NAIVE MOVE
```

It exists for two reasons:

1. To prove the equivalence checker **can fail**. A test that cannot fail proves
   nothing.
2. To document, in runnable form, why the shipped design splits the enable.

It uses the *baseline* (non-sparse) adder tree so the experiment isolates the
MAC-side change.

---

# PART 4 — Every design decision, and why

This is the part interviewers probe. Each entry is a decision that could
plausibly have gone the other way.

## 4.1 Why `ce = pe | oa | trig` and not `ce = pe | oa`

`operation_active` is registered and therefore one cycle late. Without the
`| trig` term the enable is low on precisely the cycle the first data arrives,
so every burst loses its first item. Found by simulation (`result_valid` never
asserted), not by reading the code.

## 4.2 Why split the enable instead of masking it — THE central decision

Masking one shared enable applies *one item's* condition to *its predecessors*,
because a stage's enable is not private to the item arriving this cycle. With a
zero-slack drain window there is no later cycle for the stranded item to catch
up. Measured cost of getting this wrong: **63% of results dropped.**

Splitting makes correctness **topological** rather than sequencing-dependent:
the control enable is structurally incapable of seeing sparsity, so no operand
pattern can affect it.

## 4.3 Why the drain counter is fed raw `valid_in`

This is the *mechanism* of 4.2. If the counter saw the gated trigger, sparsity
could shorten or extend the drain window. Feeding it the raw valid makes the
completion machinery provably blind to data values.

## 4.4 Why the skip decision is tagged per item

Because stage 2 works on an item that entered one cycle *earlier*. It must
consult that item's own skip decision, not whatever happens to be on the input
bus now. `skip_pipe` rides alongside `valid_pipe` exactly like a valid bit —
standard pipeline practice, applied to a new payload.

## 4.5 Why skipped items still emit `completion_out`

Two reasons.

1. **Cascade timing stays byte-identical to baseline.** The downstream tree sees
   the same trigger stream it always did, so nothing about its drain behaviour
   needs re-verifying.
2. **The alternative changes observable semantics.** Squashing completion for
   skipped items means an all-zero burst produces *no result pulse at all*. Any
   consumer waiting on one hangs.

## 4.6 Why only the two wide register banks are gated

`mult_stage` and `acc` are 64 bits of roughly 70 flip-flops in a lane, so
gating them captures essentially all the available saving. Gating the remaining
control flops would require perturbing completion timing, which §1.4 forbids.
The trade is bad and was declined.

## 4.7 Why `AGGRESSIVE_IDLE` defaults to 0

It buys those same three flip-flops while changing semantics and risking the
completion contract. It is included as a *measurable, rejectable* option — which
is a better engineering artefact than silently not implementing it.

## 4.8 Why `update_out` is separate from `completion_out`

They answer different questions. "Did a slot complete?" governs *timing* and
must stay unchanged. "Did the accumulator move?" governs *whether downstream
partial sums can be held* and is the new information. Overloading one signal
with both meanings would have forced the tree's drain behaviour to depend on
data — reintroducing exactly the class of bug the project is about.

## 4.9 Why the tree exploits *unchangedness*, not *zeroness*

The tree sums **accumulators**, which are persistent state and almost never
zero. Zero-detecting them would fire essentially never. "This input did not
change since last cycle, so my output won't either" is the property that
actually applies — and it is bit-exact.

## 4.10 Why datapath registers carry no reset in the DSP variant

Because DSP48E1 A/B/M registers accept only synchronous reset, and an
async-reset register can never be absorbed into the slice. The datapath does not
need a reset: correctness comes from the valid/skip tags, which *are* reset. On
ASIC the same coding rule pays off for an unrelated reason (§6.3).

**This is the rule to take away:** *a gating scheme is only as good as the
register style it is written in.*

## 4.11 Why new modules instead of editing the verified ones

So the baseline stays a **golden reference** rather than becoming a memory of
one. It is what makes exact equivalence checking possible — you cannot compare
against something you have overwritten.

---

# PART 5 — Verification: what each test proves

The verification strategy is arguably the strongest part of the project.

## 5.1 The core method: exact equivalence

Zero-skip is **lossless by construction** (§1.3). Therefore the gated and
ungated designs must agree on **every cycle**, not merely at the end of a burst.

Both cascades are driven from the *same stimulus wires* and compared
cycle-for-cycle on `(result, result_valid)`. Any divergence at any cycle is a
bug. This is a far stronger statement than "the final number looked right."

## 5.2 The testbenches

| File | What it proves |
|---|---|
| `rtl/tb_cascade.v` | Baseline regression: single burst, back-to-back bursts, gates return to idle. 3 tests, 0 errors. |
| `tb/tb_zero_skip.v` | **The main one.** 11 directed edge cases (Z1–Z11) + 400-cycle randomised sparse stream. 636 cycles compared, **0 divergences.** |
| `negctl/tb_negative_control.v` | Runs shipped *and* naive designs against the reference simultaneously. Proves the checker has teeth. |
| `tb/tb_sparsity_sweep.v` | Activity vs sparsity, 0–95%, continuous traffic. 0 divergences at every point. |
| `tb/tb_zero_skip_ir.v` | Input-registered variant vs the absolute model, plus the multiplier-input toggle measurement. |
| `tb/tb_dsp_equiv.v` | DSP-friendly reset style vs `_ir`: bit-identical over 3031 cycles, 2823 result pulses. |

**Z1–Z11 coverage**: zero mid-burst, zero at burst start, zero at burst end,
all-zero burst, 12-cycle zero run then resume, per-lane heterogeneous sparsity,
full level-1 pair idle, isolated bursts with alternating sparsity, partial
`valid_in` mask plus sparsity, 400-cycle random stream, and gates returning to
idle.

## 5.3 The three layers of checking

1. **Equivalence** against the verified baseline — catches any behavioural
   change.
2. **An independent absolute model** in the testbench, tracking what each lane's
   accumulator *should* contain — catches a fault that somehow corrupted *both*
   designs identically.
3. **Non-vacuity**: the reference emits 208 result pulses, so we know the
   comparison isn't trivially passing on silence.

## 5.4 Why the negative control matters most

**A passing test proves nothing until you show it can fail.**

Running the intentionally broken design through the identical harness and
watching it get caught — 278 of 284 cycles diverging — is what converts "our
test passed" into "our test would have caught this." That single experiment is
probably the most persuasive thing in the whole project, and it is the intended
contribution of the paper.

## 5.5 Both a/b zero paths are exercised

`drive_cycle` alternates which operand is zeroed by lane parity — odd lanes zero
`a`, even lanes zero `b` — so both halves of `~(|a) | ~(|b)` are covered rather
than only one.

---

# PART 6 — Results, and what each number actually means

## 6.1 FPGA implementation (xc7a100tcsg324-1, Vivado 2023.2, OOC, 4.0 ns)

| Design | LUT | FF | CARRY | DSP A/B/M/P | Fmax |
|---|---|---|---|---|---|
| Baseline, 2-stage, async reset | 789 | 546 | 127 | 0/0/0/8 | 269.8 MHz |
| + split-enable zero-skip | 890 | 568 | 127 | 0/0/0/8 | 272.7 MHz |
| + gated operand regs, async reset | 906 | 840 | 127 | 0/0/0/8 | **202.6 MHz** |
| + gated operand regs, **no datapath reset** | 530 | 328 | 63 | **8/8/8/8** | **283.0 MHz** |
| same, gating disabled (control) | 413 | 298 | 63 | 8/8/8/8 | 271.7 MHz |

**Out-of-context is required**, not merely convenient: the cascade has 311 ports
against 210 user I/O on any Artix-7 package. It also keeps I/O buffer power out
of a comparison that is about datapath gating.

**Reading the table correctly**: compare the last two rows to get the gating's
true cost (+117 LUT, +30 FF, no frequency penalty). Comparing `dsp` against
`base` conflates gating, an extra pipeline stage, *and* the reset change.

**A methodology trap we fell into and fixed.** The first run false-pathed the
input ports. That excluded the two-stage designs' multiplier-input paths from
timing analysis entirely and made the whole Fmax column meaningless. Everything
was rebuilt with 20% of the period budgeted as input/output delay so every path
is timed uniformly.

## 6.2 Power (SAIF-driven `report_power`)

| Design | s=0 | s=50 | s=75 | s=90 |
|---|---|---|---|---|
| Baseline | 70 | 65 | 58 | 48 mW |
| + split-enable zero-skip | 72 | 56 | 43 | 29 mW |
| *change vs. control* | *+3%* | *-14%* | *-26%* | *-40%* |

**Two things that are routinely omitted from papers and that we insist on:**

1. **The ungated baseline's own power falls with sparsity** — 31% between s=0
   and s=0.9, with no gating at all, purely because zero operands toggle a
   multiplier less. Comparing "gated at 90% sparsity" against "ungated at 0%"
   credits the gating with a reduction that is mostly a property of the *data*.
   Every comparison here is at **matched sparsity**.

2. **Clock power is a floor.** No BUFGCE is inferred — CE-based gating on
   7-series maps to the flip-flops' native enable pins, *not* clock-tree gating.
   20 mW of the baseline's dynamic power (29%) is untouchable by any technique
   in this class.

**Known limitation, stated rather than hidden.** Vivado reports confidence
*Medium* with only 12–13% of nets annotated, and the annotation cannot see
inside a DSP48 at all — so the DSP-packed variant's numbers are a **lower
bound**, not a result. The symptom is unmistakable: its DSP power reads a flat
20 mW at every sparsity while the baseline's falls 21 → 7 mW. Post-implementation
netlist simulation is the standard remedy and did not improve matching in our
attempts.

## 6.3 ASIC (Yosys + ABC, sky130_fd_sc_hd, typ. 25 °C 1.8 V)

| Design | area (µm²) | vs base | flip-flops | native-EN |
|---|---|---|---|---|
| baseline, 2-stage, async reset | 111,244 | — | 794 | 0 |
| + split-enable zero-skip | 113,032 | +1.6% | 816 | 0 |
| 3-stage, gated operands, async reset | 123,614 | +11.1% | 1088 | 0 |
| 3-stage, no datapath reset (control) | 117,311 | +5.5% | 1058 | 512 |
| + split-enable zero-skip | 119,088 | +7.1% | 1088 | 512 |

**Finding 1 — the gating is far cheaper than the FPGA suggests.** +1.6% of cell
area on the two-stage pipeline, +1.5% against the three-stage control — against
+12.8% and +28% *LUT*. The added flip-flop count is **identical on both targets**
(+22 and +30), so the discrepancy is LUT granularity inflating the apparent cost
of small control cones, not a real difference. We had been quoting a figure
roughly 10× too pessimistic.

**Finding 2 — the reset-style penalty is NOT an FPGA artefact.** This was the
surprise. sky130_fd_sc_hd provides an enable flip-flop (`edfxtp`) and an
async-reset flip-flop (`dfrtp`) but **no cell that is both.** So an
asynchronously reset register carrying a clock enable must be built as a reset
flop plus a **feedback multiplexer.** The no-reset variants map 512 registers
onto native enable cells; the async-reset variants map **none**, and pay +3.8%
area for identical function.

Same coding rule, two completely unrelated mechanisms, both targets.

**Limitation**: synthesis only. No place and route, no static timing (no open
STA tool available). Area is pre-layout cell area; all comparisons are relative.

---

# PART 7 — Research position and interview crib

## 7.1 What is genuinely novel — the honest answer

**The core zero-skip idea is not novel and is directly anticipated:**

- Gohel, Gundrapally & Choi, *Electronics* 15(11):2492, **June 2026** — publishes
  literally `EN_MAC = valid ∧ (A≠0) ∧ (B≠0)` with measured FPGA power, under a
  title nearly identical to this project's. The most damaging reference.
- **Imagination Technologies CN110007896B** (2017) — clock-gating storage
  elements on zero operands across multiplier *and* adder tree.
- **Google US9818059B1** (2016) — zero-activation multiply suppression.
- Academically: Eyeriss, Cnvlutin, Cambricon (all 2016), then ZeNA, SCNN.

**The base architecture's claim is weaker than originally assumed too:**
**IBM US7308593B2** (2005–07) already claims per-stage local clock gating with
distributed, non-centralised control and forward valid propagation. The
mechanism differs (stall propagation vs drain counters) but the architectural
claim is the same one.

**What no prior art was found for:** the *interaction* — that operand-zero
skipping is not composable with completion/drain-counter gating, and the
split-enable fix. The Gohel scheme has no drain counter, so the composition
never arises there.

**Verdict: not patentable.** The core is anticipated (novelty). The split-enable
discipline is a combination of two standard techniques — per-item valid tagging
is textbook, zero-skip is a decade old — which is close to the definition of
obvious. Publish instead.

## 7.2 The 60-second pitch

> "It's an 8-lane MAC array with completion-aware clock gating — each pipeline
> stage owns a drain counter sized to its own latency, so the enable stays
> asserted exactly long enough for in-flight data to retire, and each stage
> wakes the next with a completion pulse rather than through a central
> controller.
>
> I then tried to add sparsity zero-skipping on top, and found the two don't
> compose. The standard enable — valid AND A-nonzero AND B-nonzero — suppresses
> a *shared* enable, which also clocks items still draining from earlier cycles.
> Because a correctly sized drain window has zero slack by construction, those
> items are stranded permanently. I built that naive version deliberately and
> measured it: it drops 63% of all results.
>
> The fix is to split the enable — a control enable that's never masked and
> feeds the drain counter with raw valid, plus a sparsity-gated datapath enable,
> with the skip decision tagged per item so each stage reads its own item's tag.
> That's cycle-for-cycle identical to the ungated reference over randomised
> sparse traffic, and I kept the broken version as a negative control to prove
> the equivalence check can actually fail."

## 7.3 Questions you should expect, and the answers

**"Why a drain counter rather than just propagating valid?"**
Either works; the drain counter makes the window explicitly sized by a
parameter, which is what let me retarget from 2 to 3 stages with a one-line
change when I added operand registers. Valid-propagation schemes have the same
composability exposure — the hazard is about *sharing* one enable, not about how
it's generated.

**"How do you know your test is any good?"**
Because I made it fail. The naive design is kept in the repo and run in the same
harness; it's caught on 278 of 284 cycles. And the reference emits 208 result
pulses, so the comparison isn't passing vacuously on silence.

**"Your 64% activity reduction — is that real power?"**
Mostly not, and that's a finding rather than an excuse. Gating the product
register doesn't quiet the multiplier array, because the operands still change
every cycle. Post-implementation Vivado confirms AREG=BREG=0, so the DSP is
driven straight from the ports. Only gated *operand* registers quiet it —
multiplier-input transitions fall 62%. Register-enable counts are a misleading
metric and I'd argue papers should state which register is being gated.

**"What about clock power?"**
It's a floor. No BUFGCE is inferred on 7-series — CE gating maps to the flops'
native enable pins, not the clock tree. 29% of the baseline's dynamic power is
untouchable by this class of technique.

**"Why did removing a reset make it 33% smaller?"**
DSP48E1 pipeline registers only support synchronous reset, so async-reset
datapath registers can never be absorbed into the slice. Removing them moved
AREG/BREG/MREG from 0 to 8 and folded the accumulator's carry chain into the
DSP's own adder. On sky130 the same coding rule pays off differently — the
library has an enable flop and an async-reset flop but no cell that's both.

**"Is this novel?"**
The zero-skip idea, no — it's anticipated by a 2026 Electronics paper and a 2017
Imagination patent, and dates to Eyeriss in 2016. What I couldn't find prior art
for is the composability hazard and the fix. I'd frame it as an engineering
caution with a runnable counterexample, not a new architecture.

*(That last answer is the strongest one you have. Interviewers respond much
better to a candidate who knows the limits of their own claim.)*

---

# PART 8 — Practical reference

## 8.1 File map

```
rtl/
  completion_aware_gate.v      reusable gate, parameterised by DRAIN_DEPTH
  pipelined_mac.v              baseline 2-stage MAC
  adder_tree_stage.v           baseline 3-level tree
  mac_array_and_cascade_top.v  array wrapper + mac_cascade_top
  tb_cascade.v                 baseline regression testbench
  zero_skip_gate.v             split-enable gating cell
  pipelined_mac_zs.v           zero-skip MAC (product-register gated)
  adder_tree_stage_zs.v        tree with hierarchical sparsity propagation
  mac_cascade_zs_top.v         sparse cascade top
  pipelined_mac_zs_ir.v        + gated operand registers (async reset)
  pipelined_mac_zs_dsp.v       + no datapath reset -> DSP48 packs; + control top
tb/
  tb_zero_skip.v               equivalence + 11 edge cases + random
  tb_sparsity_sweep.v          activity vs sparsity 0-95%
  tb_zero_skip_ir.v            IR variant + multiplier-input toggle measurement
  tb_dsp_equiv.v               DSP reset style is bit-identical
negctl/
  pipelined_mac_naive.v        INTENTIONALLY WRONG - negative control
  tb_negative_control.v        proves the checker can fail
synth/                         Vivado build / power flow  (see synth/README.md)
asic/                          Yosys + sky130 flow        (see asic/README.md)
paper/                         TCAS-II draft + data       (see SUBMISSION_NOTES.md)
docs/                          this guide + extension write-up
```

## 8.2 How to run everything

```bat
run_tests.bat                 :: all 6 simulation suites (Icarus, ~1 min)
synth\run_build.bat           :: Vivado: base, zs, ir
synth\run_build2.bat          :: Vivado: dsp, dsp0
synth\run_power.bat           :: SAIF power sweep
asic\get_lib.ps1              :: fetch sky130 liberty (~12 MB, once)
asic\run_asic.bat             :: Yosys standard-cell synthesis
cd paper && pdflatex main && pdflatex main
```

## 8.3 Environment gotchas that cost real time

- **oss-cad-suite needs `environment.bat` sourced first.** Without it `iverilog`
  silently produces no output at all — no error, no file.
- **`xelab` needs `-timescale 1ns/1ps`**: the RTL declares no timescale, the
  testbench does.
- **SAIF paths in an xsim Tcl script must use forward slashes.** A Windows path
  is treated as containing Tcl escapes and the file is silently not written.
- **A stale `.Xil/` makes `synth_design` fail** with
  `couldn't read file .../realtime/<top>.tcl`. Delete it before every build.
- **cmd nested `FOR` + `CALL` mis-scopes loop variables** — this silently ran
  sweep points at the wrong sparsity while labelling them correctly. Use a flat
  call list.
- **Multiple `-d` options through the xvlog `.bat` wrapper are unreliable** (it
  splits on `=`). Write defines into a generated config file that `include`s the
  testbench.

## 8.4 Glossary

| Term | Meaning |
|---|---|
| **MAC** | multiply-accumulate: `acc += a*b` |
| **Drain window** | the cycles an enable must stay asserted for in-flight data to retire |
| **Zero slack** | a correctly sized drain window has no spare cycle — the source of the hazard |
| **Completion pulse** | "a pipeline slot finished here" — the cascade's wake-up signal |
| **`ce_ctrl` / `ce_mult`** | the split enable: control (never masked) / datapath (sparsity-gated) |
| **`skip_pipe`** | per-item skip tag riding alongside `valid_pipe` |
| **`update_out`** | "my accumulator actually moved" — stricter than completion |
| **ICG** | integrated clock gating cell; *not* inferred here — CE maps to flop enable pins |
| **SAIF** | switching activity file, drives power estimation |
| **OOC** | out-of-context synthesis: no I/O buffers, required here (311 ports vs 210 pins) |
| **AREG/BREG/MREG/PREG** | DSP48E1's internal pipeline registers |
| **Native-EN flop** | a standard cell with a real clock-enable pin (`edfxtp`) |

## 8.5 Current status

- All 6 simulation suites pass. Zero-skip is cycle-for-cycle identical to the
  verified baseline; the negative control is caught.
- FPGA and ASIC implementation complete; power measured with stated caveats.
- Paper drafted for IEEE TCAS-II Express Briefs, 5 pages (at the limit).
- Repo `kulamani007/clock-gated-mac-array`, Apache-2.0, **private until
  submission** — must be flipped public *at* submission, since reviewers are who
  needs it.

**Two open gaps**, both tractable:
1. SAIF net matching is 12–13%; the DSP-packed power figure is a lower bound.
2. No place & route or static timing on the ASIC side. Netlists are in
   `asic/netlist/` ready for OpenSTA + OpenROAD, which would likely close both
   gaps at once.
