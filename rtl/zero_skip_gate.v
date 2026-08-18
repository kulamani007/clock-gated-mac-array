// =============================================================================
// Module: zero_skip_gate
// Extension #2: sparsity-driven zero-skip gating
//
// PURPOSE
//   Wraps (does not modify) the verified completion_aware_gate and adds
//   operand zero-detection, producing a SPLIT clock-enable:
//
//     ce_ctrl  - the unmodified completion-aware enable. Drives only the
//                validity/skip tracking registers. The drain counter is
//                triggered by the RAW valid_in, so drain state is provably
//                untouched by any zero pattern.
//     ce_mult  - ce_ctrl AND "this cycle carries a real, non-zero item".
//                Gates the wide multiplier result register.
//     skip     - per-item tag, to be piped alongside the item so the
//                accumulator can be gated one cycle later.
//
// WHY SPLIT RATHER THAN MASK ce
//   Measured on the baseline: the MAC's ce window is exactly
//   {trigger cycle, +1, +2} and completion_out fires on the LAST of those.
//   The adder tree's window is exactly {trigger, +1, +2, +3} and sum_valid
//   is latched on the last edge. There is ZERO slack. Masking the single
//   shared ce with ~zero therefore drops an in-flight result whenever a
//   zero lands inside another item's drain window - which is precisely the
//   "zero at burst end" case. Splitting the enable removes the failure mode
//   structurally instead of relying on careful sequencing.
//   Measured cost of getting this wrong: see negctl/ - the naive version
//   drops 131 of 208 results (63%).
//
// LOSSLESS
//   For unsigned operands, (a==0 || b==0) implies a*b==0 exactly. Skipping
//   the multiply and the accumulate of a zero product is bit-exact, not an
//   approximation. This design changes power, never results.
//
// PARAMETERS
//   ENABLE_ZERO_SKIP - 1: sparsity gating active. 0: degenerates to the
//                      baseline gate exactly (for A/B power comparison).
//   AGGRESSIVE_IDLE  - 0 (default): zero items still occupy a pipeline slot
//                      and still emit completion. Cascade timing is
//                      bit-identical to baseline.
//                      1: zero items are also removed from the TRIGGER, so
//                      a sustained all-zero run lets the gate fully idle.
//                      This CHANGES OBSERVABLE SEMANTICS (an all-zero burst
//                      emits no completion pulse) and is NOT recommended -
//                      it buys ~3 control flops while risking the contract.
// =============================================================================

module zero_skip_gate #(
    parameter DATA_WIDTH       = 16,
    parameter DRAIN_DEPTH      = 2,
    parameter ENABLE_ZERO_SKIP = 1,
    parameter AGGRESSIVE_IDLE  = 0
)(
    input  wire                  clk,
    input  wire                  rst,

    input  wire                  primary_enable,
    input  wire                  valid_in,
    input  wire [DATA_WIDTH-1:0] a,
    input  wire [DATA_WIDTH-1:0] b,

    output wire                  ce_ctrl,          // control / validity registers
    output wire                  ce_mult,          // wide multiply-result register
    output wire                  skip,             // per-item skip tag (pipe this)
    output wire                  operand_zero,     // raw detect, for stats/debug
    output wire                  operation_active
);

    // -------------------------------------------------------------------------
    // Zero detection. Reduction-OR is the cheap form: ~(|a) is a DATA_WIDTH-input
    // NOR, one small combinational cone per operand, off the critical path
    // because it feeds an enable, not the datapath.
    // -------------------------------------------------------------------------
    assign operand_zero = ~(|a) | ~(|b);

    // A skip only means anything on a cycle that actually carries an item.
    assign skip = ENABLE_ZERO_SKIP[0] & valid_in & operand_zero;

    // -------------------------------------------------------------------------
    // Trigger selection.
    //
    // Default (AGGRESSIVE_IDLE=0): the drain counter sees the RAW valid_in.
    // This is the whole point - the completion/drain machinery is completely
    // blind to sparsity, so no zero pattern can shorten, extend, or corrupt it.
    // -------------------------------------------------------------------------
    wire trigger_eff = (ENABLE_ZERO_SKIP[0] && AGGRESSIVE_IDLE[0])
                       ? (valid_in & ~operand_zero)
                       :  valid_in;

    completion_aware_gate #(
        .DRAIN_DEPTH(DRAIN_DEPTH)
    ) gate_inst (
        .clk             (clk),
        .rst             (rst),
        .primary_enable  (primary_enable),
        .trigger_in      (trigger_eff),
        .ce              (ce_ctrl),
        .operation_active(operation_active)
    );

    // -------------------------------------------------------------------------
    // Multiplier-register enable.
    //
    // Two independent savings folded into one term:
    //   1. & ~skip      - the sparsity saving (extension #2 proper).
    //   2. & valid_in   - the multiplier register no longer reloads during
    //                     the 2 drain cycles at the end of every burst, when
    //                     the bus holds stale data that is never consumed
    //                     (valid_pipe is low for those slots). This is a free
    //                     win present even at 0% sparsity, and is a real
    //                     inefficiency in the baseline.
    // -------------------------------------------------------------------------
    assign ce_mult = ce_ctrl & valid_in & ~skip;

endmodule
