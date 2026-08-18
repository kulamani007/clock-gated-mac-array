// =============================================================================
// Module: mac_array_zs / mac_cascade_zs_top
// Sparsity-aware cascade: zero-skip MAC array -> zero-skip adder tree.
//
// Port-compatible with mac_cascade_top so the two can be driven by identical
// stimulus and compared cycle-for-cycle. The only added wire between the two
// stages is update_bus - the "my accumulator actually moved" companion to the
// existing completion_bus. That single extra bus is what turns per-MAC
// zero-skip into a cascade-level sparsity mechanism.
// =============================================================================

module mac_array_zs #(
    parameter DATA_WIDTH       = 16,
    parameter NUM_MACS         = 8,
    parameter ENABLE_ZERO_SKIP = 1,
    parameter AGGRESSIVE_IDLE  = 0
)(
    input  wire                                   clk,
    input  wire                                   rst,

    input  wire [NUM_MACS-1:0]                    primary_enable,
    input  wire [NUM_MACS-1:0]                    valid_in,

    input  wire [NUM_MACS*DATA_WIDTH-1:0]         a_bus,
    input  wire [NUM_MACS*DATA_WIDTH-1:0]         b_bus,

    output wire [NUM_MACS*(2*DATA_WIDTH)-1:0]     acc_bus,
    output wire [NUM_MACS-1:0]                    valid_out,
    output wire [NUM_MACS-1:0]                    completion_out,
    output wire [NUM_MACS-1:0]                    update_out
);

    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i = i + 1) begin : MAC_ARRAY

            pipelined_mac_zs #(
                .DATA_WIDTH      (DATA_WIDTH),
                .ENABLE_ZERO_SKIP(ENABLE_ZERO_SKIP),
                .AGGRESSIVE_IDLE (AGGRESSIVE_IDLE)
            ) mac_inst (
                .clk            (clk),
                .rst            (rst),
                .primary_enable (primary_enable[i]),
                .valid_in       (valid_in[i]),
                .a              (a_bus [i*DATA_WIDTH      +: DATA_WIDTH]),
                .b              (b_bus [i*DATA_WIDTH      +: DATA_WIDTH]),
                .acc            (acc_bus[i*(2*DATA_WIDTH) +: (2*DATA_WIDTH)]),
                .valid_out      (valid_out[i]),
                .completion_out (completion_out[i]),
                .update_out     (update_out[i])
            );

        end
    endgenerate

endmodule


module mac_cascade_zs_top #(
    parameter DATA_WIDTH       = 16,
    parameter NUM_MACS         = 8,
    parameter ENABLE_ZERO_SKIP = 1,
    parameter AGGRESSIVE_IDLE  = 0
)(
    input  wire                              clk,
    input  wire                              rst,

    input  wire [NUM_MACS-1:0]               primary_enable_mac,
    input  wire                              primary_enable_tree,
    input  wire [NUM_MACS-1:0]               valid_in,

    input  wire [NUM_MACS*DATA_WIDTH-1:0]    a_bus,
    input  wire [NUM_MACS*DATA_WIDTH-1:0]    b_bus,

    output wire [2*DATA_WIDTH+3-1:0]         result,
    output wire                              result_valid
);

    wire [NUM_MACS*(2*DATA_WIDTH)-1:0] acc_bus;
    wire [NUM_MACS-1:0]                mac_valid_out;
    wire [NUM_MACS-1:0]                completion_bus;
    wire [NUM_MACS-1:0]                update_bus;

    mac_array_zs #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .ENABLE_ZERO_SKIP(ENABLE_ZERO_SKIP),
        .AGGRESSIVE_IDLE (AGGRESSIVE_IDLE)
    ) mac_array_inst (
        .clk            (clk),
        .rst            (rst),
        .primary_enable (primary_enable_mac),
        .valid_in       (valid_in),
        .a_bus          (a_bus),
        .b_bus          (b_bus),
        .acc_bus        (acc_bus),
        .valid_out      (mac_valid_out),
        .completion_out (completion_bus),
        .update_out     (update_bus)
    );

    adder_tree_stage_zs #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .ENABLE_ZERO_SKIP(ENABLE_ZERO_SKIP)
    ) adder_tree_inst (
        .clk            (clk),
        .rst            (rst),
        .primary_enable (primary_enable_tree),
        .completion_in  (completion_bus),
        .update_in      (update_bus),
        .acc_bus        (acc_bus),
        .sum_out        (result),
        .sum_valid      (result_valid)
    );

endmodule
