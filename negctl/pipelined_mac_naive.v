// =============================================================================
// pipelined_mac_naive  -  INTENTIONALLY WRONG. NOT PART OF THE DESIGN.
//
// This is the "obvious" implementation of zero-skip that the brief describes
// literally: detect a zero operand and suppress the MAC's clock-enable for
// that cycle. It exists ONLY as a negative control, to prove that
// tb_zero_skip's equivalence checker actually has teeth and to document, in
// runnable form, why the shipped design splits the enable instead.
//
// The defect: ce is SHARED by the multiply stage, the accumulate stage and
// the validity tracker. Suppressing it on a zero cycle also freezes an
// unrelated in-flight item that is mid-drain. Because the measured drain
// window has zero slack, a zero landing in the last drain cycle of a burst
// permanently strands that item's accumulate.
//
// MEASURED: drops 131 of 208 results (63%), diverges on 278/284 cycles.
// =============================================================================

module pipelined_mac_naive #(
    parameter DATA_WIDTH = 16
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
    output wire                      update_out
);

    wire ce_raw, operation_active;

    completion_aware_gate #(.DRAIN_DEPTH(2)) gate_inst (
        .clk(clk), .rst(rst),
        .primary_enable(primary_enable),
        .trigger_in(valid_in),
        .ce(ce_raw), .operation_active(operation_active));

    // <<< THE NAIVE MOVE: one shared enable, masked by zero detection >>>
    wire operand_zero = ~(|a) | ~(|b);
    wire ce = ce_raw & ~(valid_in & operand_zero);

    reg [2*DATA_WIDTH-1:0] mult_stage;
    always @(posedge clk or posedge rst) begin
        if (rst) mult_stage <= 0;
        else if (ce) mult_stage <= ({{DATA_WIDTH{1'b0}}, a}) * ({{DATA_WIDTH{1'b0}}, b});
    end

    reg valid_pipe;
    always @(posedge clk or posedge rst) begin
        if (rst) valid_pipe <= 1'b0;
        else if (ce) valid_pipe <= valid_in;
        else valid_pipe <= 1'b0;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin acc <= 0; valid_out <= 1'b0; end
        else if (ce) begin
            if (valid_pipe) acc <= acc + mult_stage;
            valid_out <= valid_pipe;
        end else valid_out <= 1'b0;
    end

    assign completion_out = valid_out;
    assign update_out     = valid_out;

endmodule


module mac_array_naive #(parameter DATA_WIDTH=16, parameter NUM_MACS=8)(
    input wire clk, rst,
    input wire [NUM_MACS-1:0] primary_enable, valid_in,
    input wire [NUM_MACS*DATA_WIDTH-1:0] a_bus, b_bus,
    output wire [NUM_MACS*(2*DATA_WIDTH)-1:0] acc_bus,
    output wire [NUM_MACS-1:0] valid_out, completion_out, update_out);
    genvar i;
    generate for (i=0;i<NUM_MACS;i=i+1) begin : MAC_ARRAY
        pipelined_mac_naive #(.DATA_WIDTH(DATA_WIDTH)) mac_inst (
            .clk(clk), .rst(rst),
            .primary_enable(primary_enable[i]), .valid_in(valid_in[i]),
            .a(a_bus[i*DATA_WIDTH +: DATA_WIDTH]),
            .b(b_bus[i*DATA_WIDTH +: DATA_WIDTH]),
            .acc(acc_bus[i*(2*DATA_WIDTH) +: (2*DATA_WIDTH)]),
            .valid_out(valid_out[i]), .completion_out(completion_out[i]),
            .update_out(update_out[i]));
    end endgenerate
endmodule


module mac_cascade_naive_top #(parameter DATA_WIDTH=16, parameter NUM_MACS=8)(
    input wire clk, rst,
    input wire [NUM_MACS-1:0] primary_enable_mac,
    input wire primary_enable_tree,
    input wire [NUM_MACS-1:0] valid_in,
    input wire [NUM_MACS*DATA_WIDTH-1:0] a_bus, b_bus,
    output wire [2*DATA_WIDTH+3-1:0] result,
    output wire result_valid);

    wire [NUM_MACS*(2*DATA_WIDTH)-1:0] acc_bus;
    wire [NUM_MACS-1:0] mvo, cbus, ubus;

    mac_array_naive #(.DATA_WIDTH(DATA_WIDTH), .NUM_MACS(NUM_MACS)) mac_array_inst (
        .clk(clk), .rst(rst), .primary_enable(primary_enable_mac),
        .valid_in(valid_in), .a_bus(a_bus), .b_bus(b_bus),
        .acc_bus(acc_bus), .valid_out(mvo), .completion_out(cbus), .update_out(ubus));

    // baseline (non-sparse) tree, so the experiment isolates the MAC-side change
    adder_tree_stage #(.DATA_WIDTH(DATA_WIDTH), .NUM_MACS(NUM_MACS)) adder_tree_inst (
        .clk(clk), .rst(rst), .primary_enable(primary_enable_tree),
        .completion_in(cbus), .acc_bus(acc_bus),
        .sum_out(result), .sum_valid(result_valid));
endmodule
