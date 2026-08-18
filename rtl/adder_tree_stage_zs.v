// =============================================================================
// Module: adder_tree_stage_zs
// Sparsity-aware variant of adder_tree_stage: HIERARCHICAL ZERO-SKIP
// PROPAGATION.
//
// THE IDEA
//   Per-MAC zero-skip alone is a local trick. The cascade makes a stronger
//   claim available: if a MAC's accumulator did not change this pass, then
//   every partial sum in the tree that depends only on unchanged
//   accumulators is ALSO unchanged, so its register can be held instead of
//   reloaded. The "nothing happened here" information propagates up the
//   tree in lockstep with the data it describes.
//
//   update_in[i] = "MAC i's accumulator actually moved" (phase-aligned with
//   completion_in). From it:
//     l1_en[j] = update_in[2j] | update_in[2j+1]
//     l2_en[k] = l1_chg[2k]    | l1_chg[2k+1]        (l1_chg = registered l1_en)
//     l3_en    = |l2_chg                              (l2_chg = registered l2_en)
//
//   Each enable is registered on the same edge as the data it guards, so the
//   change-flags shift up the tree in the same pipeline phase as the partial
//   sums. Holding a register whose inputs provably did not change is
//   bit-exact, so this is lossless.
//
//   NOTE this is a different mechanism from "the operand is zero so do not
//   clock it" (cf. Imagination Technologies CN110007896B). Here the tree
//   sums ACCUMULATORS - persistent state, rarely zero - so the exploitable
//   property is UNCHANGED-ness, not zero-ness.
//
// HONEST SCOPE NOTE
//   This is a SECOND-ORDER saving. The tree contains 7 adders against the
//   array's 8 multipliers, and a level-1 adder is only gated when BOTH MACs
//   feeding it are idle - under unstructured sparsity s that is only s^2 per
//   pair (measured: s=0.48 -> 22.7% L1 saving, model predicts 23%). It
//   matters for structured / block sparsity and it is what makes this a
//   cascade-level contribution rather than a per-MAC one; it is not where
//   the bulk of the power goes. Do not oversell it.
//
// The completion/drain path (trigger_in, the gate, valid_shift, sum_valid)
// is UNCHANGED from adder_tree_stage.v. Only register enables are added.
// =============================================================================

module adder_tree_stage_zs #(
    parameter DATA_WIDTH       = 16,
    parameter NUM_MACS         = 8,
    parameter ACC_WIDTH        = 2*DATA_WIDTH,
    parameter ENABLE_ZERO_SKIP = 1
)(
    input  wire                                clk,
    input  wire                                rst,

    input  wire                                primary_enable,
    input  wire [NUM_MACS-1:0]                 completion_in,
    input  wire [NUM_MACS-1:0]                 update_in,       // NEW: acc-changed flags

    input  wire [NUM_MACS*ACC_WIDTH-1:0]       acc_bus,

    output reg  [ACC_WIDTH+3-1:0]              sum_out,
    output reg                                 sum_valid
);

    localparam TREE_DRAIN_DEPTH = 3;

    // ---- completion path: byte-identical to the baseline module -------------

    wire trigger_in = |completion_in;

    wire ce;
    wire operation_active;

    completion_aware_gate #(
        .DRAIN_DEPTH(TREE_DRAIN_DEPTH)
    ) gate_inst (
        .clk             (clk),
        .rst             (rst),
        .primary_enable  (primary_enable),
        .trigger_in      (trigger_in),
        .ce              (ce),
        .operation_active(operation_active)
    );

    reg [TREE_DRAIN_DEPTH-1:0] valid_shift;

    always @(posedge clk or posedge rst) begin
        if (rst)
            valid_shift <= {TREE_DRAIN_DEPTH{1'b0}};
        else if (ce)
            valid_shift <= {valid_shift[TREE_DRAIN_DEPTH-2:0], trigger_in};
        else
            valid_shift <= {TREE_DRAIN_DEPTH{1'b0}};
    end

    // ---- change-flag pipeline (the new part) --------------------------------

    wire [3:0] l1_en_raw;
    assign l1_en_raw[0] = update_in[0] | update_in[1];
    assign l1_en_raw[1] = update_in[2] | update_in[3];
    assign l1_en_raw[2] = update_in[4] | update_in[5];
    assign l1_en_raw[3] = update_in[6] | update_in[7];

    reg [3:0] l1_chg;
    reg [1:0] l2_chg;

    wire [1:0] l2_en_raw;
    assign l2_en_raw[0] = l1_chg[0] | l1_chg[1];
    assign l2_en_raw[1] = l1_chg[2] | l1_chg[3];

    // ENABLE_ZERO_SKIP=0 forces every enable high -> exactly the baseline tree.
    wire [3:0] l1_en = ENABLE_ZERO_SKIP[0] ? l1_en_raw : 4'hF;
    wire [1:0] l2_en = ENABLE_ZERO_SKIP[0] ? l2_en_raw : 2'h3;
    wire       l3_en = ENABLE_ZERO_SKIP[0] ? (|l2_chg) : 1'b1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            l1_chg <= 4'h0;
            l2_chg <= 2'h0;
        end else if (ce) begin
            l1_chg <= l1_en_raw;
            l2_chg <= l2_en_raw;
        end
    end

    // ---- data path ----------------------------------------------------------

    genvar gi;
    wire [ACC_WIDTH-1:0] mac_val [NUM_MACS-1:0];
    generate
        for (gi = 0; gi < NUM_MACS; gi = gi + 1) begin : UNPACK
            assign mac_val[gi] = acc_bus[gi*ACC_WIDTH +: ACC_WIDTH];
        end
    endgenerate

    // Level 1: 8 -> 4, each pair independently gated
    reg [ACC_WIDTH:0] level1 [3:0];
    integer i1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i1 = 0; i1 < 4; i1 = i1 + 1)
                level1[i1] <= {(ACC_WIDTH+1){1'b0}};
        end else if (ce) begin
            if (l1_en[0]) level1[0] <= mac_val[0] + mac_val[1];
            if (l1_en[1]) level1[1] <= mac_val[2] + mac_val[3];
            if (l1_en[2]) level1[2] <= mac_val[4] + mac_val[5];
            if (l1_en[3]) level1[3] <= mac_val[6] + mac_val[7];
        end
    end

    // Level 2: 4 -> 2
    reg [ACC_WIDTH+1:0] level2 [1:0];
    integer i2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i2 = 0; i2 < 2; i2 = i2 + 1)
                level2[i2] <= {(ACC_WIDTH+2){1'b0}};
        end else if (ce) begin
            if (l2_en[0]) level2[0] <= level1[0] + level1[1];
            if (l2_en[1]) level2[1] <= level1[2] + level1[3];
        end
    end

    // Level 3: 2 -> 1
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sum_out   <= {(ACC_WIDTH+3){1'b0}};
            sum_valid <= 1'b0;
        end else if (ce) begin
            if (valid_shift[TREE_DRAIN_DEPTH-2] && l3_en)
                sum_out <= level2[0] + level2[1];
            sum_valid <= valid_shift[TREE_DRAIN_DEPTH-1];
        end else begin
            sum_valid <= 1'b0;
        end
    end

endmodule
