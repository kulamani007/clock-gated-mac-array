// =============================================================================
// Module: adder_tree_stage
// Description: Sums NUM_MACS (must be a power of 2) accumulator outputs from
//              the MAC array using a registered binary adder tree.
//
//              This is the second stage in the cascade. Its gate is
//              triggered directly by the OR of all upstream MACs'
//              completion_out signals - this OR is the actual cascade
//              connection: stage 1 (MAC array) tells stage 2 (adder tree)
//              "fresh data is here, wake yourself for your own drain
//              duration."
//
//              Tree depth for 8 inputs: 8 -> 4 -> 2 -> 1, i.e. 3 registered
//              levels, so DRAIN_DEPTH = 3 for this stage's gate.
// =============================================================================

module adder_tree_stage #(
    parameter DATA_WIDTH = 16,      // matches pipelined_mac DATA_WIDTH
    parameter NUM_MACS   = 8,       // must be power of 2
    parameter ACC_WIDTH  = 2*DATA_WIDTH
)(
    input  wire                                clk,
    input  wire                                rst,

    input  wire                                primary_enable,
    input  wire [NUM_MACS-1:0]                 completion_in,   // from each MAC's completion_out

    input  wire [NUM_MACS*ACC_WIDTH-1:0]       acc_bus,         // packed per-MAC accumulator results

    output reg  [ACC_WIDTH+3-1:0]              sum_out,         // +3 guard bits for 8-way growth (log2(8)=3)
    output reg                                 sum_valid
);

    localparam TREE_DRAIN_DEPTH = 3;   // 8->4->2->1 = 3 registered add levels

    // -------------------------------------------------------------------------
    // Cascade trigger: this stage wakes the moment ANY upstream MAC completes.
    // Since all 8 MACs are driven by the same valid_in pattern in this design,
    // they complete together - but the OR keeps the stage correct even if a
    // future variant drives MACs independently.
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // Stage validity tracker - mirrors pipelined_mac's valid_pipe pattern,
    // but needs 3 cycles of delay instead of 1, since the tree is 3 levels.
    // -------------------------------------------------------------------------

    reg [TREE_DRAIN_DEPTH-1:0] valid_shift;

    always @(posedge clk or posedge rst) begin
        if (rst)
            valid_shift <= {TREE_DRAIN_DEPTH{1'b0}};
        else if (ce)
            valid_shift <= {valid_shift[TREE_DRAIN_DEPTH-2:0], trigger_in};
        else
            valid_shift <= {TREE_DRAIN_DEPTH{1'b0}};
    end

    // -------------------------------------------------------------------------
    // Level 1: 8 inputs -> 4 sums
    // -------------------------------------------------------------------------

    genvar gi;
    wire [ACC_WIDTH-1:0] mac_val [NUM_MACS-1:0];
    generate
        for (gi = 0; gi < NUM_MACS; gi = gi + 1) begin : UNPACK
            assign mac_val[gi] = acc_bus[gi*ACC_WIDTH +: ACC_WIDTH];
        end
    endgenerate

    reg [ACC_WIDTH:0] level1 [3:0];   // +1 bit growth
    integer i1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i1 = 0; i1 < 4; i1 = i1 + 1)
                level1[i1] <= {(ACC_WIDTH+1){1'b0}};
        end else if (ce) begin
            level1[0] <= mac_val[0] + mac_val[1];
            level1[1] <= mac_val[2] + mac_val[3];
            level1[2] <= mac_val[4] + mac_val[5];
            level1[3] <= mac_val[6] + mac_val[7];
        end
    end

    // -------------------------------------------------------------------------
    // Level 2: 4 sums -> 2 sums
    // -------------------------------------------------------------------------

    reg [ACC_WIDTH+1:0] level2 [1:0];   // +2 bits growth
    integer i2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i2 = 0; i2 < 2; i2 = i2 + 1)
                level2[i2] <= {(ACC_WIDTH+2){1'b0}};
        end else if (ce) begin
            level2[0] <= level1[0] + level1[1];
            level2[1] <= level1[2] + level1[3];
        end
    end

    // -------------------------------------------------------------------------
    // Level 3: 2 sums -> 1 final sum
    // -------------------------------------------------------------------------

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sum_out   <= {(ACC_WIDTH+3){1'b0}};
            sum_valid <= 1'b0;
        end else if (ce) begin
            if (valid_shift[TREE_DRAIN_DEPTH-2])   // level-2 results are valid_shift bit [1]
                sum_out <= level2[0] + level2[1];
            sum_valid <= valid_shift[TREE_DRAIN_DEPTH-1];  // oldest bit = fully drained result
        end else begin
            sum_valid <= 1'b0;
        end
    end

endmodule
