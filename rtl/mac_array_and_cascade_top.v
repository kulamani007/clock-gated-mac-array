// =============================================================================
// Module: mac_array_custom (cascade-ready)
// Description: Parallel array of pipelined_mac units. Exposes completion_out
//              per MAC so the next cascade stage (adder tree) can use it as
//              a trigger.
// =============================================================================

module mac_array_custom #(
    parameter DATA_WIDTH = 16,
    parameter NUM_MACS   = 8
)(
    input  wire                                   clk,
    input  wire                                   rst,

    input  wire [NUM_MACS-1:0]                    primary_enable,
    input  wire [NUM_MACS-1:0]                    valid_in,

    input  wire [NUM_MACS*DATA_WIDTH-1:0]         a_bus,
    input  wire [NUM_MACS*DATA_WIDTH-1:0]         b_bus,

    output wire [NUM_MACS*(2*DATA_WIDTH)-1:0]     acc_bus,
    output wire [NUM_MACS-1:0]                    valid_out,
    output wire [NUM_MACS-1:0]                    completion_out   // cascade bus to adder tree
);

    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i = i + 1) begin : MAC_ARRAY

            pipelined_mac #(
                .DATA_WIDTH(DATA_WIDTH)
            ) mac_inst (
                .clk            (clk),
                .rst            (rst),
                .primary_enable (primary_enable[i]),
                .valid_in       (valid_in[i]),
                .a              (a_bus [i*DATA_WIDTH      +: DATA_WIDTH]),
                .b              (b_bus [i*DATA_WIDTH      +: DATA_WIDTH]),
                .acc            (acc_bus[i*(2*DATA_WIDTH) +: (2*DATA_WIDTH)]),
                .valid_out      (valid_out[i]),
                .completion_out (completion_out[i])
            );

        end
    endgenerate

endmodule


// =============================================================================
// Module: mac_cascade_top
// Description: Top-level cascade: MAC array (stage 1) -> adder tree (stage 2).
//              This is the concrete realization of "cascade-aware completion
//              gating": stage 2's gate is triggered entirely by stage 1's
//              completion signals, with no shared centralized controller.
//              Each stage owns its own drain counter sized to its own
//              pipeline depth.
// =============================================================================

module mac_cascade_top #(
    parameter DATA_WIDTH = 16,
    parameter NUM_MACS   = 8
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

    mac_array_custom #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_MACS  (NUM_MACS)
    ) mac_array_inst (
        .clk            (clk),
        .rst            (rst),
        .primary_enable (primary_enable_mac),
        .valid_in       (valid_in),
        .a_bus          (a_bus),
        .b_bus          (b_bus),
        .acc_bus        (acc_bus),
        .valid_out      (mac_valid_out),
        .completion_out (completion_bus)
    );

    adder_tree_stage #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_MACS  (NUM_MACS)
    ) adder_tree_inst (
        .clk            (clk),
        .rst            (rst),
        .primary_enable (primary_enable_tree),
        .completion_in  (completion_bus),   // <-- the cascade connection
        .acc_bus        (acc_bus),
        .sum_out        (result),
        .sum_valid      (result_valid)
    );

endmodule
