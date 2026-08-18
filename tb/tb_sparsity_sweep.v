`timescale 1ns/1ps
// =============================================================================
// tb_sparsity_sweep - switching-activity characterization vs operand sparsity.
//
// Drives CONTINUOUS traffic (valid_in high every cycle) so the drain-cycle
// overhead is amortized away and the numbers isolate the pure sparsity effect.
// Reported separately from the bursty case, because conflating the two is how
// clock-gating papers end up quoting numbers that do not reproduce.
//
// Counts REGISTER LOAD EVENTS on the wide banks:
//   mult_stage : 2*DW bits x NUM_MACS      (dominates - it is the multiplier)
//   acc        : 2*DW bits x NUM_MACS
//   tree L1/L2 : the adder-tree partial-sum registers
// Register load events are the right proxy: a load is what makes the register
// output toggle, which is what drives both the flop's own dynamic power and
// the downstream combinational cone it feeds.
// =============================================================================

module tb_sparsity_sweep;

    parameter DW = 16;
    parameter NM = 8;
    parameter RUN_CYCLES = 500;

    reg clk = 0, rst = 1;
    reg [NM-1:0] pe_mac = 0;
    reg pe_tree = 0;
    reg [NM-1:0] valid_in = 0;
    reg [NM*DW-1:0] a_bus = 0, b_bus = 0;

    wire [2*DW+3-1:0] res_ref, res_zs;
    wire rval_ref, rval_zs;

    integer mult_ref, mult_zs, acc_ref, acc_zs, l1_ref, l1_zs, l2_ref, l2_zs;
    integer counting;
    integer divergences;
    integer s_idx, t, n;
    integer sparsity_pct;
    integer zero_items, total_items;
    real    mult_red, acc_red, l1_red, l2_red;

    mac_cascade_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_ref (
        .clk(clk), .rst(rst), .primary_enable_mac(pe_mac),
        .primary_enable_tree(pe_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(res_ref), .result_valid(rval_ref));

    mac_cascade_zs_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_zs (
        .clk(clk), .rst(rst), .primary_enable_mac(pe_mac),
        .primary_enable_tree(pe_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(res_zs), .result_valid(rval_zs));

    always #5 clk = ~clk;

    genvar gv;
    generate
        for (gv = 0; gv < NM; gv = gv + 1) begin : ACT
            always @(posedge clk) if (!rst && counting) begin
                if (dut_ref.mac_array_inst.MAC_ARRAY[gv].mac_inst.ce)
                    mult_ref = mult_ref + 1;
                if (dut_ref.mac_array_inst.MAC_ARRAY[gv].mac_inst.ce &&
                    dut_ref.mac_array_inst.MAC_ARRAY[gv].mac_inst.valid_pipe)
                    acc_ref = acc_ref + 1;
                if (dut_zs.mac_array_inst.MAC_ARRAY[gv].mac_inst.gate_inst.ce_mult)
                    mult_zs = mult_zs + 1;
                if (dut_zs.mac_array_inst.MAC_ARRAY[gv].mac_inst.ce_ctrl &&
                    dut_zs.mac_array_inst.MAC_ARRAY[gv].mac_inst.acc_update)
                    acc_zs = acc_zs + 1;
            end
        end
    endgenerate

    integer j;
    always @(posedge clk) if (!rst && counting) begin
        if (dut_ref.adder_tree_inst.ce) begin
            l1_ref = l1_ref + 4;
            l2_ref = l2_ref + 2;
        end
        if (dut_zs.adder_tree_inst.ce) begin
            for (j = 0; j < 4; j = j + 1)
                if (dut_zs.adder_tree_inst.l1_en[j]) l1_zs = l1_zs + 1;
            for (j = 0; j < 2; j = j + 1)
                if (dut_zs.adder_tree_inst.l2_en[j]) l2_zs = l2_zs + 1;
        end
        if ((res_ref !== res_zs) || (rval_ref !== rval_zs))
            divergences = divergences + 1;
    end

    // deterministic pseudo-random lane sparsity at a target rate
    function automatic is_zero_lane(input integer rate_pct);
        begin
            is_zero_lane = (({$random} % 100) < rate_pct);
        end
    endfunction

    initial begin
        $display("==========================================================================");
        $display(" SPARSITY SWEEP - continuous traffic, %0d cycles per point, %0d lanes",
                 RUN_CYCLES, NM);
        $display("==========================================================================");
        $display(" sparsity |  mult-reg loads    |  acc-reg loads     | treeL1 | treeL2 | div");
        $display("   (%%)    |  base -> zskip  %%  |  base -> zskip  %%  |   %%    |   %%    |");
        $display("--------------------------------------------------------------------------");

        rst = 1; #23; rst = 0;
        @(negedge clk);

        for (s_idx = 0; s_idx <= 8; s_idx = s_idx + 1) begin
            sparsity_pct = s_idx * 12;   // 0,12,24,...,96
            if (sparsity_pct > 95) sparsity_pct = 95;

            // settle & reset counters
            valid_in = 0;
            repeat (20) @(negedge clk);
            mult_ref=0; mult_zs=0; acc_ref=0; acc_zs=0;
            l1_ref=0; l1_zs=0; l2_ref=0; l2_zs=0;
            divergences=0; zero_items=0; total_items=0;
            counting = 1;

            for (t = 0; t < RUN_CYCLES; t = t + 1) begin
                for (n = 0; n < NM; n = n + 1) begin
                    if (is_zero_lane(sparsity_pct)) begin
                        a_bus[n*DW +: DW] = 16'd0;
                        b_bus[n*DW +: DW] = 16'd3;
                        zero_items = zero_items + 1;
                    end else begin
                        a_bus[n*DW +: DW] = 16'd1 + n;
                        b_bus[n*DW +: DW] = 16'd3;
                    end
                    total_items = total_items + 1;
                end
                valid_in = {NM{1'b1}};   // CONTINUOUS - no drain overhead
                @(negedge clk);
            end
            counting = 0;
            valid_in = 0;
            repeat (20) @(negedge clk);

            mult_red = (mult_ref==0) ? 0.0 : 100.0*(mult_ref-mult_zs)/mult_ref;
            acc_red  = (acc_ref ==0) ? 0.0 : 100.0*(acc_ref -acc_zs )/acc_ref;
            l1_red   = (l1_ref  ==0) ? 0.0 : 100.0*(l1_ref  -l1_zs  )/l1_ref;
            l2_red   = (l2_ref  ==0) ? 0.0 : 100.0*(l2_ref  -l2_zs  )/l2_ref;

            $display("  %2d (%2d) | %6d -> %6d %5.1f | %6d -> %6d %5.1f | %5.1f  | %5.1f  | %0d",
                     sparsity_pct, (100*zero_items)/total_items,
                     mult_ref, mult_zs, mult_red,
                     acc_ref,  acc_zs,  acc_red,
                     l1_red, l2_red, divergences);
        end

        $display("--------------------------------------------------------------------------");
        $display(" 'sparsity' = requested %%; '( )' = actually measured zero-item %%.");
        $display(" div = cycles where zero-skip output differed from baseline. Must be 0.");
        $display("==========================================================================");
        $finish;
    end

    initial begin #900000; $display("TIMEOUT"); $finish; end

endmodule
