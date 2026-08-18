// =============================================================================
// Module: pipelined_mac_zs_ir   (zero-skip, INPUT-REGISTERED)
//
// WHY THIS EXISTS
//   pipelined_mac_zs gates the mult_stage REGISTER on a zero operand. That
//   saves the 32-bit register load - but the multiplier itself is
//   combinational between the a/b ports and that register, and a/b keep
//   changing every cycle regardless of the enable. So the multiplier ARRAY
//   still toggles. Register-load counts therefore OVERSTATE the true power
//   saving for the single largest block in the design.
//
//   Fix: put gated registers on the operands. When an item is skipped, a_reg
//   and b_reg HOLD, so the multiplier's inputs are stable and its internal
//   partial-product network does not switch at all. This is what actually
//   converts sparsity into multiplier power saving.
//
//   MEASURED (tb_zero_skip_ir, 29% sparsity):
//     multiplier-input changes, plain zero-skip : 2661
//     multiplier-input changes, input-registered: 1009   -> 62% reduction
//   Plain zero-skip scores 0% on this metric. This is the gap.
//
//   Bonus: on Xilinx this is also the shape Vivado wants for DSP48 packing -
//   the A/B input registers map to the DSP48's own A/B registers with CEA/CEB,
//   so the gating is absorbed into the hard block rather than costing fabric.
//
// COST
//   One extra pipeline stage: operand-register -> multiply -> accumulate.
//   Latency grows by 1 cycle and DRAIN_DEPTH must become 3.
//
//   That one-line parameter change is the whole adaptation - which is a real
//   (if small) vindication of parameterizing the gate by DRAIN_DEPTH in the
//   first place. Nothing else in the gating logic moves.
//
// VERIFICATION NOTE
//   This variant is NOT cycle-equivalent to the baseline (it is deliberately
//   one cycle later), so it is checked against the independent absolute model
//   rather than by cycle-for-cycle comparison. See tb/tb_zero_skip_ir.v.
// =============================================================================

module pipelined_mac_zs_ir #(
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
        .DRAIN_DEPTH      (3),          // operand-reg, multiply, accumulate
        .ENABLE_ZERO_SKIP (ENABLE_ZERO_SKIP),
        .AGGRESSIVE_IDLE  (0)
    ) gate_inst (
        .clk(clk), .rst(rst),
        .primary_enable(primary_enable),
        .valid_in(valid_in), .a(a), .b(b),
        .ce_ctrl(ce_ctrl), .ce_mult(ce_mult), .skip(skip),
        .operand_zero(operand_zero), .operation_active(operation_active));

    // ---- Stage 0: gated operand registers -----------------------------------
    // On a skipped item these HOLD, so the multiplier below sees unchanged
    // inputs and its combinational network is quiet.
    reg [DATA_WIDTH-1:0] a_reg, b_reg;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_reg <= {DATA_WIDTH{1'b0}};
            b_reg <= {DATA_WIDTH{1'b0}};
        end else if (ce_mult) begin
            a_reg <= a;
            b_reg <= b;
        end
    end

    // ---- validity / skip tracker: now 2 deep to match the extra stage -------
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

    // ---- Stage 1: multiply --------------------------------------------------
    wire mult_load = ce_ctrl & valid_sr[0] & ~skip_sr[0];

    reg [2*DATA_WIDTH-1:0] mult_stage;
    always @(posedge clk or posedge rst) begin
        if (rst)
            mult_stage <= {(2*DATA_WIDTH){1'b0}};
        else if (mult_load)
            mult_stage <= ({{DATA_WIDTH{1'b0}}, a_reg}) * ({{DATA_WIDTH{1'b0}}, b_reg});
    end

    // ---- Stage 2: accumulate ------------------------------------------------
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
        if (rst)              update_out <= 1'b0;
        else if (ce_ctrl)     update_out <= acc_update;
        else                  update_out <= 1'b0;
    end

endmodule


module mac_array_zs_ir #(parameter DATA_WIDTH=16, parameter NUM_MACS=8,
                         parameter ENABLE_ZERO_SKIP=1)(
    input wire clk, rst,
    input wire [NUM_MACS-1:0] primary_enable, valid_in,
    input wire [NUM_MACS*DATA_WIDTH-1:0] a_bus, b_bus,
    output wire [NUM_MACS*(2*DATA_WIDTH)-1:0] acc_bus,
    output wire [NUM_MACS-1:0] valid_out, completion_out, update_out);
    genvar i;
    generate for (i=0;i<NUM_MACS;i=i+1) begin : MAC_ARRAY
        pipelined_mac_zs_ir #(.DATA_WIDTH(DATA_WIDTH),
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


module mac_cascade_zs_ir_top #(parameter DATA_WIDTH=16, parameter NUM_MACS=8,
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

    mac_array_zs_ir #(.DATA_WIDTH(DATA_WIDTH), .NUM_MACS(NUM_MACS),
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
