`timescale 1ns/1ps
// =============================================================================
// tb_zero_skip - verification for extension #2 (sparsity-driven zero-skip)
//
// METHOD
//   The baseline mac_cascade_top is already verified (tb_cascade, 0 errors),
//   so it is used as a GOLDEN REFERENCE. Both DUTs are driven from the exact
//   same stimulus wires and compared CYCLE-FOR-CYCLE on (result, result_valid).
//   Zero-skip is lossless by construction, so ANY divergence at ANY cycle is a
//   bug - this is a far stronger statement than "the final number looked right".
//
//   On top of equivalence, an independent absolute model tracks what each
//   lane's accumulator should contain, so a fault that somehow corrupted BOTH
//   DUTs identically would still be caught.
//
//   Activity counters on the wide-register enables give the switching-activity
//   numbers the power estimate is built from - measured, not assumed.
//
//   See negctl/tb_negative_control.v for proof that this checker can fail.
// =============================================================================

module tb_zero_skip;

    parameter DW = 16;
    parameter NM = 8;

    reg clk = 0;
    reg rst = 1;

    reg [NM-1:0]    pe_mac  = 0;
    reg             pe_tree = 0;
    reg [NM-1:0]    valid_in = 0;
    reg [NM*DW-1:0] a_bus = 0, b_bus = 0;

    wire [2*DW+3-1:0] res_ref,  res_zs;
    wire              rval_ref, rval_zs;

    integer errors   = 0;
    integer checks   = 0;
    integer cyc      = 0;
    integer compare_en = 0;

    // ---- absolute model -----------------------------------------------------
    integer model_acc [0:NM-1];
    integer k, t;

    // ---- activity counters --------------------------------------------------
    integer act_mult_ref = 0, act_mult_zs = 0;   // wide multiplier-reg loads
    integer act_acc_ref  = 0, act_acc_zs  = 0;   // wide accumulator-reg loads
    integer act_l1_ref   = 0, act_l1_zs   = 0;   // level-1 adder-reg loads
    integer act_l2_ref   = 0, act_l2_zs   = 0;
    integer items_total  = 0, items_zero  = 0;

    // -------------------------------------------------------------------------
    // DUTs - identical stimulus
    // -------------------------------------------------------------------------

    mac_cascade_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_ref (
        .clk(clk), .rst(rst),
        .primary_enable_mac(pe_mac), .primary_enable_tree(pe_tree),
        .valid_in(valid_in), .a_bus(a_bus), .b_bus(b_bus),
        .result(res_ref), .result_valid(rval_ref));

    mac_cascade_zs_top #(.DATA_WIDTH(DW), .NUM_MACS(NM),
                         .ENABLE_ZERO_SKIP(1), .AGGRESSIVE_IDLE(0)) dut_zs (
        .clk(clk), .rst(rst),
        .primary_enable_mac(pe_mac), .primary_enable_tree(pe_tree),
        .valid_in(valid_in), .a_bus(a_bus), .b_bus(b_bus),
        .result(res_zs), .result_valid(rval_zs));

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Continuous cycle-for-cycle equivalence checker
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (!rst && compare_en) begin
            checks = checks + 1;
            if (rval_ref !== rval_zs) begin
                $display("  !! CYCLE %0d: result_valid MISMATCH ref=%b zs=%b",
                         cyc, rval_ref, rval_zs);
                errors = errors + 1;
            end
            if (res_ref !== res_zs) begin
                $display("  !! CYCLE %0d: result MISMATCH ref=%0d zs=%0d",
                         cyc, res_ref, res_zs);
                errors = errors + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Activity counters (sampled at the edge the register would load)
    // -------------------------------------------------------------------------
    genvar gv;
    generate
        for (gv = 0; gv < NM; gv = gv + 1) begin : ACT
            always @(posedge clk) if (!rst) begin
                // baseline: mult_stage reloads on every ce cycle
                if (dut_ref.mac_array_inst.MAC_ARRAY[gv].mac_inst.ce)
                    act_mult_ref = act_mult_ref + 1;
                if (dut_ref.mac_array_inst.MAC_ARRAY[gv].mac_inst.ce &&
                    dut_ref.mac_array_inst.MAC_ARRAY[gv].mac_inst.valid_pipe)
                    act_acc_ref = act_acc_ref + 1;

                // zero-skip: split enables
                if (dut_zs.mac_array_inst.MAC_ARRAY[gv].mac_inst.gate_inst.ce_mult)
                    act_mult_zs = act_mult_zs + 1;
                if (dut_zs.mac_array_inst.MAC_ARRAY[gv].mac_inst.ce_ctrl &&
                    dut_zs.mac_array_inst.MAC_ARRAY[gv].mac_inst.acc_update)
                    act_acc_zs = act_acc_zs + 1;
            end
        end
    endgenerate

    integer j;
    always @(posedge clk) if (!rst) begin
        if (dut_ref.adder_tree_inst.ce) act_l1_ref = act_l1_ref + 4;
        if (dut_ref.adder_tree_inst.ce) act_l2_ref = act_l2_ref + 2;
        if (dut_zs.adder_tree_inst.ce) begin
            for (j = 0; j < 4; j = j + 1)
                if (dut_zs.adder_tree_inst.l1_en[j]) act_l1_zs = act_l1_zs + 1;
            for (j = 0; j < 2; j = j + 1)
                if (dut_zs.adder_tree_inst.l2_en[j]) act_l2_zs = act_l2_zs + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Stimulus helpers
    // -------------------------------------------------------------------------

    // Drive one cycle of data on all lanes. zero_mask[k]=1 forces lane k's
    // operands so the product is zero (alternating which operand is zeroed,
    // to prove BOTH a==0 and b==0 are detected).
    task drive_cycle(input [DW-1:0] base_a, input [DW-1:0] base_b,
                     input [NM-1:0] zero_mask, input [NM-1:0] vmask);
        integer n;
        begin
            for (n = 0; n < NM; n = n + 1) begin
                if (zero_mask[n]) begin
                    if (n[0]) begin           // odd lane: zero the 'a' operand
                        a_bus[n*DW +: DW] = 0;
                        b_bus[n*DW +: DW] = base_b + n;
                    end else begin            // even lane: zero the 'b' operand
                        a_bus[n*DW +: DW] = base_a + n;
                        b_bus[n*DW +: DW] = 0;
                    end
                end else begin
                    a_bus[n*DW +: DW] = base_a + n;
                    b_bus[n*DW +: DW] = base_b;
                end
                // absolute model
                if (vmask[n]) begin
                    items_total = items_total + 1;
                    if (zero_mask[n]) items_zero = items_zero + 1;
                    else model_acc[n] = model_acc[n]
                                        + (base_a + n) * base_b;
                end
            end
            valid_in = vmask;
        end
    endtask

    task idle_cycles(input integer n);
        integer m;
        begin
            valid_in = 0;
            for (m = 0; m < n; m = m + 1) @(negedge clk);
        end
    endtask

    task check_settled(input [255:0] label);
        integer n;
        integer expect_sum;
        begin
            expect_sum = 0;
            for (n = 0; n < NM; n = n + 1) expect_sum = expect_sum + model_acc[n];
            if (res_zs !== expect_sum) begin
                $display("  !! %0s: settled ABSOLUTE mismatch: zs=%0d model=%0d",
                         label, res_zs, expect_sum);
                errors = errors + 1;
            end else begin
                $display("  %0s: settled result = %0d  (matches independent model)",
                         label, res_zs);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("================================================================");
        $display(" tb_zero_skip : zero-skip vs verified baseline, cycle-exact");
        $display("================================================================");
        for (k = 0; k < NM; k = k + 1) model_acc[k] = 0;

        rst = 1; #23; rst = 0;
        @(negedge clk);
        compare_en = 1;

        // ---------------------------------------------------------------
        // Z1: zero MID-BURST.  [nonzero, zero, nonzero], valid high throughout
        //     Risk: the zero cycle must not suppress the accumulate of the
        //     item that entered the cycle before it.
        // ---------------------------------------------------------------
        $display("\n-- Z1: zero mid-burst (nz, z, nz) --");
        drive_cycle(16'd10, 16'd3, 8'h00, 8'hFF); @(negedge clk);
        drive_cycle(16'd20, 16'd4, 8'hFF, 8'hFF); @(negedge clk);
        drive_cycle(16'd30, 16'd5, 8'h00, 8'hFF); @(negedge clk);
        idle_cycles(15);
        check_settled("Z1");

        // ---------------------------------------------------------------
        // Z2: zero at BURST START. [zero, nonzero, nonzero]
        //     Risk: a design that gates the trigger would never start the
        //     pipeline, losing the whole burst.
        // ---------------------------------------------------------------
        $display("\n-- Z2: zero at burst start (z, nz, nz) --");
        drive_cycle(16'd11, 16'd3, 8'hFF, 8'hFF); @(negedge clk);
        drive_cycle(16'd12, 16'd6, 8'h00, 8'hFF); @(negedge clk);
        drive_cycle(16'd13, 16'd7, 8'h00, 8'hFF); @(negedge clk);
        idle_cycles(15);
        check_settled("Z2");

        // ---------------------------------------------------------------
        // Z3: zero at BURST END. [nonzero, nonzero, zero]  << the killer case
        //     Risk: the trailing zero lands INSIDE the drain window of the
        //     preceding non-zero item. Masking a shared ce here drops that
        //     item's accumulate and the result never appears.
        // ---------------------------------------------------------------
        $display("\n-- Z3: zero at burst end (nz, nz, z)  [drain-window case] --");
        drive_cycle(16'd14, 16'd2, 8'h00, 8'hFF); @(negedge clk);
        drive_cycle(16'd15, 16'd3, 8'h00, 8'hFF); @(negedge clk);
        drive_cycle(16'd16, 16'd9, 8'hFF, 8'hFF); @(negedge clk);
        idle_cycles(15);
        check_settled("Z3");

        // ---------------------------------------------------------------
        // Z4: entire burst is zero on every lane.
        // ---------------------------------------------------------------
        $display("\n-- Z4: all-zero burst (every lane, every cycle) --");
        drive_cycle(16'd21, 16'd5, 8'hFF, 8'hFF); @(negedge clk);
        drive_cycle(16'd22, 16'd5, 8'hFF, 8'hFF); @(negedge clk);
        idle_cycles(15);
        check_settled("Z4");

        // ---------------------------------------------------------------
        // Z5: LONG zero run, then non-zero resumes. This is the case the
        //     brief calls out: no spurious flush, no dropped result on resume.
        // ---------------------------------------------------------------
        $display("\n-- Z5: 12-cycle zero run, then non-zero resumes --");
        for (t = 0; t < 12; t = t + 1) begin
            drive_cycle(16'd31 + t[15:0], 16'd3, 8'hFF, 8'hFF); @(negedge clk);
        end
        drive_cycle(16'd40, 16'd6, 8'h00, 8'hFF); @(negedge clk);
        drive_cycle(16'd41, 16'd7, 8'h00, 8'hFF); @(negedge clk);
        idle_cycles(15);
        check_settled("Z5");

        // ---------------------------------------------------------------
        // Z6: heterogeneous - some lanes zero, some not, same cycle.
        //     Exercises the per-lane update_out -> tree level gating.
        // ---------------------------------------------------------------
        $display("\n-- Z6: per-lane heterogeneous sparsity --");
        drive_cycle(16'd50, 16'd2, 8'b10101010, 8'hFF); @(negedge clk);
        drive_cycle(16'd51, 16'd3, 8'b11000011, 8'hFF); @(negedge clk);
        drive_cycle(16'd52, 16'd4, 8'b00001111, 8'hFF); @(negedge clk);
        idle_cycles(15);
        check_settled("Z6");

        // ---------------------------------------------------------------
        // Z7: a whole level-1 PAIR idle (lanes 0,1 zero) - proves the tree
        //     level-1 adder can be held and still produce the right sum.
        // ---------------------------------------------------------------
        $display("\n-- Z7: full level-1 pair idle (lanes 0+1 zero) --");
        drive_cycle(16'd60, 16'd3, 8'b00000011, 8'hFF); @(negedge clk);
        idle_cycles(15);
        check_settled("Z7");

        // ---------------------------------------------------------------
        // Z8: single-cycle bursts separated by gaps, alternating sparsity.
        //     Each burst fully drains before the next - checks the gate
        //     re-arms cleanly from idle after a skipped item.
        // ---------------------------------------------------------------
        $display("\n-- Z8: isolated single-cycle bursts, alternating sparsity --");
        for (t = 0; t < 6; t = t + 1) begin
            drive_cycle(16'd70 + t[15:0], 16'd2,
                        (t[0] ? 8'hFF : 8'h00), 8'hFF); @(negedge clk);
            idle_cycles(9);
        end
        check_settled("Z8");

        // ---------------------------------------------------------------
        // Z9: partial valid_in masks combined with sparsity - lanes that are
        //     not even valid must not be counted as zero-skips.
        // ---------------------------------------------------------------
        $display("\n-- Z9: partial valid_in mask + sparsity --");
        drive_cycle(16'd80, 16'd3, 8'b00110011, 8'b11110000); @(negedge clk);
        drive_cycle(16'd81, 16'd4, 8'b11110000, 8'b00111100); @(negedge clk);
        idle_cycles(15);
        check_settled("Z9");

        // ---------------------------------------------------------------
        // Z10: randomized sparse stream - 400 cycles, random sparsity level,
        //      random valid gaps. This is where unforeseen interactions show.
        // ---------------------------------------------------------------
        $display("\n-- Z10: 400-cycle randomized sparse stream --");
        for (t = 0; t < 400; t = t + 1) begin
            if ($random % 5 == 0) begin
                valid_in = 0;
                @(negedge clk);
            end else begin
                drive_cycle(16'd2 + ({$random} % 50),
                            16'd1 + ({$random} % 12),
                            {$random} & {$random},   // biased toward more zeros
                            {$random});
                @(negedge clk);
            end
        end
        idle_cycles(25);
        check_settled("Z10");

        // ---------------------------------------------------------------
        // Idle-state check: both gates must still return to fully idle.
        // ---------------------------------------------------------------
        $display("\n-- Z11: gates return to idle after sparse traffic --");
        if (dut_zs.mac_array_inst.MAC_ARRAY[0].mac_inst.gate_inst.gate_inst.operation_active !== 1'b0) begin
            $display("  !! Z11 FAIL: MAC0 zero-skip gate did not go idle");
            errors = errors + 1;
        end else $display("  Z11: MAC0 gate idle confirmed");
        if (dut_zs.adder_tree_inst.gate_inst.operation_active !== 1'b0) begin
            $display("  !! Z11 FAIL: tree gate did not go idle");
            errors = errors + 1;
        end else $display("  Z11: tree gate idle confirmed");

        // ---------------------------------------------------------------
        $display("\n================ ACTIVITY (measured) ===================");
        $display(" items driven          : %0d   (of which zero-product: %0d = %0d%%)",
                 items_total, items_zero,
                 (items_total==0) ? 0 : (100*items_zero)/items_total);
        $display(" mult-reg loads  ref/zs: %0d / %0d   -> %0d%% reduction",
                 act_mult_ref, act_mult_zs,
                 (act_mult_ref==0)?0:(100*(act_mult_ref-act_mult_zs))/act_mult_ref);
        $display(" acc-reg  loads  ref/zs: %0d / %0d   -> %0d%% reduction",
                 act_acc_ref, act_acc_zs,
                 (act_acc_ref==0)?0:(100*(act_acc_ref-act_acc_zs))/act_acc_ref);
        $display(" tree L1  loads  ref/zs: %0d / %0d   -> %0d%% reduction",
                 act_l1_ref, act_l1_zs,
                 (act_l1_ref==0)?0:(100*(act_l1_ref-act_l1_zs))/act_l1_ref);
        $display(" tree L2  loads  ref/zs: %0d / %0d   -> %0d%% reduction",
                 act_l2_ref, act_l2_zs,
                 (act_l2_ref==0)?0:(100*(act_l2_ref-act_l2_zs))/act_l2_ref);
        $display("========================================================");
        $display(" cycles compared: %0d", checks);
        if (errors == 0)
            $display(" RESULT: PASS - zero-skip is cycle-for-cycle identical to baseline");
        else
            $display(" RESULT: FAIL - %0d error(s)", errors);
        $display("========================================================");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
