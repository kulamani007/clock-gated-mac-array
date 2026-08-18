// =============================================================================
// Module: completion_aware_gate
// Description: Reusable completion-aware clock-enable gating cell.
//
//   This is the generalized form of the gating logic originally embedded
//   inside pipelined_mac. Any pipelined stage — a MAC, an adder tree level,
//   an activation unit — can instantiate this and get correct gating
//   behavior simply by setting DRAIN_DEPTH to its own pipeline latency.
//
//   Behavior:
//     - trigger_in starts a new operation: ce goes high, drain counter
//       loads with DRAIN_DEPTH.
//     - While no new trigger arrives, the counter decrements each cycle
//       that ce is high (i.e. each cycle a pipeline slot is in flight).
//     - operation_active (and therefore ce) stays high until the counter
//       reaches zero, guaranteeing every in-flight pipeline slot drains
//       before the clock-enable drops.
//     - primary_enable is an external override — always keeps ce high,
//       independent of trigger/drain state (e.g. for controller-driven
//       wakeup or initialization).
//
//   NOTE (bug fixed during verification):
//     ce must respond to trigger_in COMBINATIONALLY on the same cycle it
//     arrives. operation_active alone is registered and lags trigger_in by
//     one cycle — using only `primary_enable | operation_active` silently
//     drops the very first valid cycle of every burst. Fixed by OR-ing in
//     trigger_in directly.
// =============================================================================

module completion_aware_gate #(
    parameter DRAIN_DEPTH = 2     // number of pipeline stages downstream of trigger_in
)(
    input  wire clk,
    input  wire rst,

    input  wire primary_enable,   // external override - forces ce high
    input  wire trigger_in,       // asserted the cycle new valid data enters this stage

    output wire ce,                // clock-enable for this stage's registers
    output reg  operation_active   // exposed for cascading / debug visibility
);

    localparam CW = (DRAIN_DEPTH <= 1) ? 1 : $clog2(DRAIN_DEPTH + 1);

    reg [CW-1:0] drain_count;

    // ce must respond to trigger_in combinationally on the SAME cycle it
    // arrives - operation_active alone is one cycle late (it's registered),
    // which would cause the very first valid_in cycle to be silently
    // dropped by the pipeline stages that gate on ce.
    assign ce = primary_enable | operation_active | trigger_in;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            operation_active <= 1'b0;
            drain_count      <= {CW{1'b0}};
        end else if (trigger_in) begin
            // New data arriving - (re)arm the drain counter
            operation_active <= 1'b1;
            drain_count      <= DRAIN_DEPTH[CW-1:0];
        end else if (drain_count > {CW{1'b0}}) begin
            drain_count      <= drain_count - 1'b1;
            operation_active <= (drain_count > {{(CW-1){1'b0}}, 1'b1});
        end
    end

endmodule
