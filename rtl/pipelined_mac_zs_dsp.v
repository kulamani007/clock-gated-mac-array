// =============================================================================
// Module: pipelined_mac_zs_dsp
// Zero-skip, input-registered, DSP48-FRIENDLY reset style.
//
// WHY
//   pipelined_mac_zs_ir added gated operand registers so the multiplier array
//   is quiet on a skipped item. Post-implementation on xc7a100t that works
//   functionally, but Vivado left a_reg/b_reg in FABRIC (AREG=0, BREG=0) and
//   the resulting fabric-FF -> DSP48 B-pin path missed a 250 MHz target by
//   0.94 ns with ZERO logic levels - it was almost all route delay into a
//   DSP whose input registers were unused.
//
//   Root cause: every datapath register in the original design carries an
//   ASYNCHRONOUS reset. The DSP48E1's A/B/M pipeline registers support only
//   SYNCHRONOUS reset, so an async-reset register can never be absorbed into
//   the DSP. The gating is fine; the reset style is what blocks packing.
//
// FIX
//   Datapath registers (a_reg, b_reg, mult_stage) carry NO reset at all.
//   They do not need one: correctness is enforced by the valid/skip tags,
//   which ARE reset. Control registers keep their async reset - they live in
//   fabric regardless.
//
//   This is a coding-style change, not an architectural one. The gating
//   architecture is identical to pipelined_mac_zs_ir, and tb_dsp_equiv.v
//   proves the two are cycle-for-cycle bit-identical.
// =============================================================================

module pipelined_mac_zs_dsp #(
    parameter DATA_WIDTH       = 16,
    parameter ENABLE_ZERO_SKIP = 1
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
    output reg                       update_out
);

    wire ce_ctrl, ce_mult, skip, operand_zero, operation_active;

    zero_skip_gate #(
        .DATA_WIDTH       (DATA_WIDTH),
        .DRAIN_DEPTH      (3),
        .ENABLE_ZERO_SKIP (ENABLE_ZERO_SKIP),
        .AGGRESSIVE_IDLE  (0)
    ) gate_inst (
        .clk(clk), .rst(rst),
        .primary_enable(primary_enable),
        .valid_in(valid_in), .a(a), .b(b),
        .ce_ctrl(ce_ctrl), .ce_mult(ce_mult), .skip(skip),
        .operand_zero(operand_zero), .operation_active(operation_active));

    // ---- Stage 0: gated operand registers, NO RESET (DSP48-packable) -------
    reg [DATA_WIDTH-1:0] a_reg, b_reg;
    always @(posedge clk) begin
        if (ce_mult) begin
            a_reg <= a;
            b_reg <= b;
        end
    end

    // ---- control: async reset retained (stays in fabric anyway) ------------
    reg [1:0] valid_sr, skip_sr;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_sr <= 2'b00;
            skip_sr  <= 2'b00;
        end else if (ce_ctrl) begin
            valid_sr <= {valid_sr[0], valid_in};
            skip_sr  <= {skip_sr[0],  skip};
        end else begin
            valid_sr <= 2'b00;
            skip_sr  <= 2'b00;
        end
    end

    // ---- Stage 1: multiply, NO RESET (DSP48 M/P-packable) ------------------
    wire mult_load = ce_ctrl & valid_sr[0] & ~skip_sr[0];

    reg [2*DATA_WIDTH-1:0] mult_stage;
    always @(posedge clk) begin
        if (mult_load)
            mult_stage <= ({{DATA_WIDTH{1'b0}}, a_reg}) * ({{DATA_WIDTH{1'b0}}, b_reg});
    end

    // ---- Stage 2: accumulate (reset retained - acc must clear) -------------
    wire acc_update = valid_sr[1] & ~skip_sr[1];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc       <= {(2*DATA_WIDTH){1'b0}};
            valid_out <= 1'b0;
        end else if (ce_ctrl) begin
            if (acc_update)
                acc <= acc + mult_stage;
            valid_out <= valid_sr[1];
        end else begin
            valid_out <= 1'b0;
        end
    end

    assign completion_out = valid_out;

    always @(posedge clk or posedge rst) begin
        if (rst)          update_out <= 1'b0;
        else if (ce_ctrl) update_out <= acc_update;
        else              update_out <= 1'b0;
    end
endmodule


module mac_array_zs_dsp #(parameter DATA_WIDTH=16, parameter NUM_MACS=8,
                          parameter ENABLE_ZERO_SKIP=1)(
    input wire clk, rst,
    input wire [NUM_MACS-1:0] primary_enable, valid_in,
    input wire [NUM_MACS*DATA_WIDTH-1:0] a_bus, b_bus,
    output wire [NUM_MACS*(2*DATA_WIDTH)-1:0] acc_bus,
    output wire [NUM_MACS-1:0] valid_out, completion_out, update_out);
    genvar i;
    generate for (i=0;i<NUM_MACS;i=i+1) begin : MAC_ARRAY
        pipelined_mac_zs_dsp #(.DATA_WIDTH(DATA_WIDTH),
                               .ENABLE_ZERO_SKIP(ENABLE_ZERO_SKIP)) mac_inst (
            .clk(clk), .rst(rst),
            .primary_enable(primary_enable[i]), .valid_in(valid_in[i]),
            .a(a_bus[i*DATA_WIDTH +: DATA_WIDTH]),
            .b(b_bus[i*DATA_WIDTH +: DATA_WIDTH]),
            .acc(acc_bus[i*(2*DATA_WIDTH) +: (2*DATA_WIDTH)]),
            .valid_out(valid_out[i]), .completion_out(completion_out[i]),
            .update_out(update_out[i]));
    end endgenerate
endmodule


module mac_cascade_zs_dsp_top #(parameter DATA_WIDTH=16, parameter NUM_MACS=8,
                                parameter ENABLE_ZERO_SKIP=1)(
    input wire clk, rst,
    input wire [NUM_MACS-1:0] primary_enable_mac,
    input wire primary_enable_tree,
    input wire [NUM_MACS-1:0] valid_in,
    input wire [NUM_MACS*DATA_WIDTH-1:0] a_bus, b_bus,
    output wire [2*DATA_WIDTH+3-1:0] result,
    output wire result_valid);

    wire [NUM_MACS*(2*DATA_WIDTH)-1:0] acc_bus;
    wire [NUM_MACS-1:0] mvo, cbus, ubus;

    mac_array_zs_dsp #(.DATA_WIDTH(DATA_WIDTH), .NUM_MACS(NUM_MACS),
                       .ENABLE_ZERO_SKIP(ENABLE_ZERO_SKIP)) mac_array_inst (
        .clk(clk), .rst(rst), .primary_enable(primary_enable_mac),
        .valid_in(valid_in), .a_bus(a_bus), .b_bus(b_bus),
        .acc_bus(acc_bus), .valid_out(mvo),
        .completion_out(cbus), .update_out(ubus));

    adder_tree_stage_zs #(.DATA_WIDTH(DATA_WIDTH), .NUM_MACS(NUM_MACS),
                          .ENABLE_ZERO_SKIP(ENABLE_ZERO_SKIP)) adder_tree_inst (
        .clk(clk), .rst(rst), .primary_enable(primary_enable_tree),
        .completion_in(cbus), .update_in(ubus), .acc_bus(acc_bus),
        .sum_out(result), .sum_valid(result_valid));
endmodule

// Ungated control: identical structure, sparsity gating disabled. This is the
// correct baseline for the DSP-friendly variant - it isolates the cost/benefit
// of the GATING from the cost/benefit of the reset style and the extra stage.
module mac_cascade_dsp_nogate_top #(parameter DATA_WIDTH=16, parameter NUM_MACS=8)(
    input wire clk, rst,
    input wire [NUM_MACS-1:0] primary_enable_mac,
    input wire primary_enable_tree,
    input wire [NUM_MACS-1:0] valid_in,
    input wire [NUM_MACS*DATA_WIDTH-1:0] a_bus, b_bus,
    output wire [2*DATA_WIDTH+3-1:0] result,
    output wire result_valid);
    mac_cascade_zs_dsp_top #(.DATA_WIDTH(DATA_WIDTH), .NUM_MACS(NUM_MACS),
                             .ENABLE_ZERO_SKIP(0)) u (
        .clk(clk), .rst(rst), .primary_enable_mac(primary_enable_mac),
        .primary_enable_tree(primary_enable_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(result), .result_valid(result_valid));
endmodule
