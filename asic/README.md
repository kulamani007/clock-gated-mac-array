# Standard-cell (ASIC) synthesis

Yosys 0.63 + ABC against the open **sky130_fd_sc_hd** library, typical corner
(25 °C, 1.8 V).

## Why this exists

The FPGA results are entangled with the DSP48 hard macro. On Artix-7 the
datapath reset style decides whether the gated operand registers pack *into*
the DSP slice, which in turn decides whether the multiplier array can be
quieted at all. That makes it impossible to tell, from the FPGA data alone,
which effects are architectural and which are artefacts of the macro.

There is no hard multiplier in a standard-cell flow, so this answers both
questions directly.

## Run it

```
powershell -ExecutionPolicy Bypass -File asic\get_lib.ps1   # ~12 MB, once
asic\run_asic.bat
```

`get_lib.ps1` pulls the liberty file from the OpenROAD-flow-scripts sky130hd
platform. It is gitignored — it is a third-party file and trivially
re-downloadable.

## Results

| Design | area (µm²) | vs base | flip-flops | native-EN |
|---|---|---|---|---|
| baseline, 2-stage, async reset | 111,244 | — | 794 | 0 |
| + split-enable zero-skip | 113,032 | +1.6 % | 816 | 0 |
| 3-stage, gated operands, async reset | 123,614 | +11.1 % | 1088 | 0 |
| 3-stage, no datapath reset (control) | 117,311 | +5.5 % | 1058 | 512 |
| + split-enable zero-skip | 119,088 | +7.1 % | 1088 | 512 |

Two findings.

**1. The gating is much cheaper than the FPGA suggests.** +1.6 % of cell area
on the two-stage pipeline, +1.5 % against the three-stage control — against
+12.8 % and +28 % LUT on Artix-7. The added flip-flop count is identical on
both targets (+22 and +30), so the difference is LUT granularity inflating the
apparent cost of small control cones, not a real cost.

**2. The reset-style penalty is not an FPGA artefact.** It reappears here
through a completely unrelated mechanism. sky130_fd_sc_hd provides an enable
flip-flop (`edfxtp`) and an asynchronous-reset flip-flop (`dfrtp`) but **no
cell that is both**. An asynchronously reset register carrying a clock enable
must therefore be built as a reset flop plus a feedback multiplexer. The
no-reset variants map 512 registers onto native enable cells; the
asynchronously reset variants map none, and pay +3.8 % area for the same
function.

So the coding rule holds on both targets, for different reasons: on FPGA
async reset blocks DSP48 absorption and costs 25 % of Fmax; on ASIC it blocks
native enable-cell mapping and costs area.

## Limitations

Synthesis only. **No place and route and no static timing** — no open STA tool
was available in this environment, so ABC's internal delay estimate is not
reported as a timing result. Area is pre-layout cell area and all comparisons
are relative.

The obvious next step is OpenSTA + OpenROAD on the netlists already written to
`netlist/`, which would give real ASIC timing and power and close the largest
remaining gap in the paper.
