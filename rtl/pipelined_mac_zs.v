// =============================================================================
// Module: pipelined_mac_zs
// Zero-skip (sparsity-aware) variant of pipelined_mac.
//
// Kept as a SEPARATE module rather than an edit to the verified
// pipelined_mac.v, so both can be instantiated in one simulation and proven
// cycle-for-cycle equivalent (see tb/tb_zero_skip.v). The baseline stays a
// golden reference instead of becoming a memory of one.
//
// STRUCTURE OF THE CHANGE
//   - The item's "skippability" is decided combinationally at the input and
//     then TRAVELS WITH THE ITEM as skip_pipe, exactly parallel to
//     valid_pipe. Stage 2 consults the tag belonging to ITS item, not to
//     whatever is on the input bus this cycle. This is what makes
//     "zero at burst end" safe: the zero arriving at cycle T+1 cannot
//     suppress the accumulate of the non-zero item that entered at T,
//     because that item carries its own skip_pipe = 0.
//   - valid_pipe / valid_out / completion_out are driven by ce_ctrl only,
//     so their timing is bit-identical to baseline for every input pattern.
//   - Only the two WIDE register banks (mult_stage, acc) are sparsity-gated.
//     They are ~64 of the ~67 flops in this module, so gating them captures
//     essentially all of the available saving; also idling the last 3
//     control flops would require perturbing completion timing, which the
//     zero-slack drain window makes unsafe.
//
// NEW OUTPUT
//   update_out - "my accumulator actually changed this cycle". Registered at
//                the same edge acc updates, so it is aligned exactly with
//                completion_out. The adder tree consumes it to gate its own
//                adder levels (hierarchical sparsity propagation).
// =============================================================================

module pipelined_mac_zs #(
    parameter DATA_WIDTH       = 16,
    parameter ENABLE_ZERO_SKIP = 1,
    parameter AGGRESSIVE_IDLE  = 0
)(
    input  wire                      clk,
    input  wire                      rst,

    input  wire                      primary_enable,
    input  wire                      valid_in,

    input  wire [DATA_WIDTH-1:0]     a,
    input  wire [DATA_WIDTH-1:0]     b,

    output reg  [2*DATA_WIDTH-1:0]   acc,
    output reg                       valid_out,
    output wire                      completion_out,
    output reg                       update_out       // NEW: acc genuinely changed
);

    // -------------------------------------------------------------------------
    // Sparsity-aware gating cell
    // -------------------------------------------------------------------------

    wire ce_ctrl, ce_mult, skip, operand_zero, operation_active;

    zero_skip_gate #(
        .DATA_WIDTH       (DATA_WIDTH),
        .DRAIN_DEPTH      (2),            // multiply, accumulate
        .ENABLE_ZERO_SKIP (ENABLE_ZERO_SKIP),
        .AGGRESSIVE_IDLE  (AGGRESSIVE_IDLE)
    ) gate_inst (
        .clk             (clk),
        .rst             (rst),
        .primary_enable  (primary_enable),
        .valid_in        (valid_in),
        .a               (a),
        .b               (b),
        .ce_ctrl         (ce_ctrl),
        .ce_mult         (ce_mult),
        .skip            (skip),
        .operand_zero    (operand_zero),
        .operation_active(operation_active)
    );

    // -------------------------------------------------------------------------
    // Pipeline Stage 1: Multiply  (sparsity-gated, wide register)
    // -------------------------------------------------------------------------

    reg [2*DATA_WIDTH-1:0] mult_stage;

    always @(posedge clk or posedge rst) begin
        if (rst)
            mult_stage <= {(2*DATA_WIDTH){1'b0}};
        else if (ce_mult)
            mult_stage <= ({{DATA_WIDTH{1'b0}}, a}) * ({{DATA_WIDTH{1'b0}}, b});
    end

    // -------------------------------------------------------------------------
    // Pipeline validity + skip tracker  (control-gated ONLY - never sparsity
    // gated, this is what preserves the completion/drain contract)
    // -------------------------------------------------------------------------

    reg valid_pipe;
    reg skip_pipe;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_pipe <= 1'b0;
            skip_pipe  <= 1'b0;
        end else if (ce_ctrl) begin
            valid_pipe <= valid_in;
            skip_pipe  <= skip;
        end else begin
            valid_pipe <= 1'b0;
            skip_pipe  <= 1'b0;
        end
    end

    // The item in stage 2 contributes to acc only if it is valid AND was not
    // tagged skippable when IT entered.
    wire acc_update = valid_pipe & ~skip_pipe;

    // -------------------------------------------------------------------------
    // Pipeline Stage 2: Accumulate  (sparsity-gated, wide register)
    // -------------------------------------------------------------------------

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc       <= {(2*DATA_WIDTH){1'b0}};
            valid_out <= 1'b0;
        end else if (ce_ctrl) begin
            if (acc_update)
                acc <= acc + mult_stage;
            valid_out <= valid_pipe;
        end else begin
            valid_out <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Completion + update outputs
    // -------------------------------------------------------------------------
    // completion_out: unchanged contract - "a pipeline slot completed here".
    //                 Fires for skipped items too, so the cascade downstream
    //                 sees an identical trigger stream to baseline.
    // update_out:     stricter - "and it actually moved my accumulator".
    //                 Registered on the same edge as valid_out so the two are
    //                 phase-aligned for the tree.

    assign completion_out = valid_out;

    always @(posedge clk or posedge rst) begin
        if (rst)
            update_out <= 1'b0;
        else if (ce_ctrl)
            update_out <= acc_update;
        else
            update_out <= 1'b0;
    end

endmodule
