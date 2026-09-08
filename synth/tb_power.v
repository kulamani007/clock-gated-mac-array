`timescale 1ns/1ps
// =============================================================================
// tb_power - SAIF-generating stimulus for Vivado power analysis.
//
// Drives CONTINUOUS traffic at a controlled operand-sparsity level using a
// DETERMINISTIC LFSR, so that all three designs (baseline, zero-skip,
// input-registered zero-skip) see BIT-IDENTICAL stimulus at a given sparsity.
// That is what makes the resulting power comparison fair: the only variable
// is the gating architecture, never the data.
//
// Select the DUT with a define:  -d DUT_BASE | -d DUT_ZS | -d DUT_IR
// Select sparsity with:          -d SPARSITY_PCT=<0..100>
// =============================================================================

`ifndef SPARSITY_PCT
  `define SPARSITY_PCT 50
`endif
`ifndef RUN_CYC
  `define RUN_CYC 2000
`endif

// A post-implementation netlist has no parameters - synthesis has already
// resolved them - so the override list must disappear for netlist simulation.
`ifdef NETLIST_SIM
  `define DUTPARAMS
`else
  `define DUTPARAMS #(.DATA_WIDTH(DW), .NUM_MACS(NM))
`endif

module tb_power;
    localparam SPARSITY   = `SPARSITY_PCT;   // percent of items with zero product
    localparam RUN_CYCLES = `RUN_CYC;
    localparam DW = 16;
    localparam NM = 8;

    reg clk = 0, rst = 1;
    reg [NM-1:0]    pe_mac  = 0;
    reg             pe_tree = 0;
    reg [NM-1:0]    valid_in = 0;
    reg [NM*DW-1:0] a_bus = 0, b_bus = 0;

    wire [2*DW+3-1:0] result;
    wire              result_valid;

`ifdef DUT_BASE
    mac_cascade_top `DUTPARAMS dut (
`endif
`ifdef DUT_ZS
    mac_cascade_zs_top `DUTPARAMS dut (
`endif
`ifdef DUT_IR
    mac_cascade_zs_ir_top `DUTPARAMS dut (
`endif
`ifdef DUT_DSP
    mac_cascade_zs_dsp_top `DUTPARAMS dut (
`endif
`ifdef DUT_DSP0
    mac_cascade_dsp_nogate_top `DUTPARAMS dut (
`endif
        .clk(clk), .rst(rst),
        .primary_enable_mac(pe_mac), .primary_enable_tree(pe_tree),
        .valid_in(valid_in), .a_bus(a_bus), .b_bus(b_bus),
        .result(result), .result_valid(result_valid));

    always #5 clk = ~clk;          // 100 MHz

    // ---- deterministic 32-bit LFSR (identical across all DUTs) -------------
    reg [31:0] lfsr = 32'hACE1_2345;
    function [31:0] nxt(input [31:0] s);
        begin
            nxt = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
        end
    endfunction

    integer t, n;
    reg [6:0] draw;

    initial begin
        rst = 1;
        repeat (10) @(negedge clk);
        rst = 0;
        @(negedge clk);

        for (t = 0; t < RUN_CYCLES; t = t + 1) begin
            for (n = 0; n < NM; n = n + 1) begin
                lfsr = nxt(lfsr);
                draw = lfsr[6:0] % 100;
                if (draw < SPARSITY) begin
                    // zero product - alternate which operand is zeroed so both
                    // a==0 and b==0 detection paths are exercised
                    if (n[0]) begin
                        a_bus[n*DW +: DW] = 16'd0;
                        b_bus[n*DW +: DW] = lfsr[23:8];
                    end else begin
                        a_bus[n*DW +: DW] = lfsr[23:8];
                        b_bus[n*DW +: DW] = 16'd0;
                    end
                end else begin
                    a_bus[n*DW +: DW] = lfsr[23:8];
                    b_bus[n*DW +: DW] = lfsr[31:16];
                end
            end
            valid_in = {NM{1'b1}};
            @(negedge clk);
        end

        valid_in = 0;
        repeat (20) @(negedge clk);
        $display("tb_power done: SPARSITY=%0d RUN_CYCLES=%0d final_result=%0d",
                 SPARSITY, RUN_CYCLES, result);
        $finish;
    end
endmodule
