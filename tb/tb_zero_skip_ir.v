`timescale 1ns/1ps
// =============================================================================
// tb_zero_skip_ir - verifies the input-registered zero-skip variant AND
// quantifies the gap it closes.
//
// TWO JOBS
//  (1) CORRECTNESS. The IR variant is deliberately one cycle later than the
//      baseline, so cycle-for-cycle equivalence is the wrong check. Instead it
//      is checked against the same independent absolute model used in
//      tb_zero_skip: after each burst fully settles, the cascade result must
//      equal the model's sum of per-lane accumulators.
//
//  (2) THE HONEST POWER QUESTION. Counts MULTIPLIER-INPUT TOGGLES - cycles on
//      which the operand values presented to the multiplier's combinational
//      network actually change. That, not register-load count, is what drives
//      switching in the partial-product array, which is the single largest
//      power consumer in the design.
//
//        baseline / plain zero-skip : multiplier inputs are the a,b PORTS,
//                                     which change every cycle the stimulus
//                                     changes them - gating the output
//                                     register does not quiet them.
//        input-registered variant   : multiplier inputs are a_reg,b_reg,
//                                     which HOLD on a skipped item.
//
//      The difference between these two columns is the saving that plain
//      zero-skip claims but does not actually deliver.
// =============================================================================

module tb_zero_skip_ir;

    parameter DW = 16;
    parameter NM = 8;

    reg clk = 0, rst = 1;
    reg [NM-1:0] pe_mac = 0;
    reg pe_tree = 0;
    reg [NM-1:0] valid_in = 0;
    reg [NM*DW-1:0] a_bus = 0, b_bus = 0;

    wire [2*DW+3-1:0] res_zs, res_ir;
    wire rval_zs, rval_ir;

    integer errors = 0;
    integer k, t, n;
    integer model_acc [0:NM-1];

    // multiplier-input toggle counters
    integer mulin_plain = 0, mulin_ir = 0;
    reg [DW-1:0] prev_a [0:NM-1];
    reg [DW-1:0] prev_b [0:NM-1];
    reg [DW-1:0] prev_ar [0:NM-1];
    reg [DW-1:0] prev_br [0:NM-1];
    integer items_total = 0, items_zero = 0;

    mac_cascade_zs_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_zs (
        .clk(clk), .rst(rst), .primary_enable_mac(pe_mac),
        .primary_enable_tree(pe_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(res_zs), .result_valid(rval_zs));

    mac_cascade_zs_ir_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_ir (
        .clk(clk), .rst(rst), .primary_enable_mac(pe_mac),
        .primary_enable_tree(pe_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(res_ir), .result_valid(rval_ir));

    always #5 clk = ~clk;

    // Hierarchical references must be resolved at elaboration time, so the
    // per-lane probes live in a generate loop (genvar), not a runtime for-loop.
    genvar gq;
    generate
        for (gq = 0; gq < NM; gq = gq + 1) begin : PROBE
            always @(posedge clk) if (!rst) begin
                // plain: multiplier sees the raw ports
                if ((a_bus[gq*DW +: DW] !== prev_a[gq]) ||
                    (b_bus[gq*DW +: DW] !== prev_b[gq]))
                    mulin_plain = mulin_plain + 1;
                prev_a[gq] = a_bus[gq*DW +: DW];
                prev_b[gq] = b_bus[gq*DW +: DW];

                // input-registered: multiplier sees the gated operand registers
                if ((dut_ir.mac_array_inst.MAC_ARRAY[gq].mac_inst.a_reg !== prev_ar[gq]) ||
                    (dut_ir.mac_array_inst.MAC_ARRAY[gq].mac_inst.b_reg !== prev_br[gq]))
                    mulin_ir = mulin_ir + 1;
                prev_ar[gq] = dut_ir.mac_array_inst.MAC_ARRAY[gq].mac_inst.a_reg;
                prev_br[gq] = dut_ir.mac_array_inst.MAC_ARRAY[gq].mac_inst.b_reg;
            end
        end
    endgenerate

    task drive_cycle(input [DW-1:0] base_a, input [DW-1:0] base_b,
                     input [NM-1:0] zero_mask, input [NM-1:0] vmask);
        begin
            for (n = 0; n < NM; n = n + 1) begin
                if (zero_mask[n]) begin
                    if (n[0]) begin
                        a_bus[n*DW +: DW] = 0;
                        b_bus[n*DW +: DW] = base_b + n;
                    end else begin
                        a_bus[n*DW +: DW] = base_a + n;
                        b_bus[n*DW +: DW] = 0;
                    end
                end else begin
                    a_bus[n*DW +: DW] = base_a + n;
                    b_bus[n*DW +: DW] = base_b;
                end
                if (vmask[n]) begin
                    items_total = items_total + 1;
                    if (zero_mask[n]) items_zero = items_zero + 1;
                    else model_acc[n] = model_acc[n] + (base_a + n) * base_b;
                end
            end
            valid_in = vmask;
        end
    endtask

    task idle_cycles(input integer c);
        integer m;
        begin
            valid_in = 0;
            for (m = 0; m < c; m = m + 1) @(negedge clk);
        end
    endtask

    task check(input [255:0] label);
        integer s;
        begin
            s = 0;
            for (n = 0; n < NM; n = n + 1) s = s + model_acc[n];
            if (res_ir !== s) begin
                $display("  !! %0s FAIL: input-registered = %0d, model = %0d",
                         label, res_ir, s);
                errors = errors + 1;
            end else if (res_zs !== s) begin
                $display("  !! %0s FAIL: plain zero-skip = %0d, model = %0d",
                         label, res_zs, s);
                errors = errors + 1;
            end else begin
                $display("  %0s PASS: both variants = %0d (model agrees)", label, s);
            end
        end
    endtask

    initial begin
        $display("================================================================");
        $display(" tb_zero_skip_ir : input-registered zero-skip");
        $display("================================================================");
        for (k = 0; k < NM; k = k + 1) begin
            model_acc[k] = 0; prev_a[k]=0; prev_b[k]=0; prev_ar[k]=0; prev_br[k]=0;
        end
        rst = 1; #23; rst = 0;
        @(negedge clk);

        $display("\n-- same edge cases as tb_zero_skip --");
        // zero mid-burst
        drive_cycle(16'd10,16'd3,8'h00,8'hFF); @(negedge clk);
        drive_cycle(16'd20,16'd4,8'hFF,8'hFF); @(negedge clk);
        drive_cycle(16'd30,16'd5,8'h00,8'hFF); @(negedge clk);
        idle_cycles(18); check("zero mid-burst   ");

        // zero at burst start
        drive_cycle(16'd11,16'd3,8'hFF,8'hFF); @(negedge clk);
        drive_cycle(16'd12,16'd6,8'h00,8'hFF); @(negedge clk);
        idle_cycles(18); check("zero burst start ");

        // zero at burst end
        drive_cycle(16'd14,16'd2,8'h00,8'hFF); @(negedge clk);
        drive_cycle(16'd15,16'd3,8'h00,8'hFF); @(negedge clk);
        drive_cycle(16'd16,16'd9,8'hFF,8'hFF); @(negedge clk);
        idle_cycles(18); check("zero burst end   ");

        // all-zero burst
        drive_cycle(16'd21,16'd5,8'hFF,8'hFF); @(negedge clk);
        idle_cycles(18); check("all-zero burst   ");

        // long zero run then resume
        for (t = 0; t < 12; t = t + 1) begin
            drive_cycle(16'd31+t[15:0],16'd3,8'hFF,8'hFF); @(negedge clk);
        end
        drive_cycle(16'd40,16'd6,8'h00,8'hFF); @(negedge clk);
        idle_cycles(18); check("long zero run    ");

        // heterogeneous
        drive_cycle(16'd50,16'd2,8'b10101010,8'hFF); @(negedge clk);
        drive_cycle(16'd51,16'd3,8'b11000011,8'hFF); @(negedge clk);
        idle_cycles(18); check("heterogeneous    ");

        // randomized
        $display("\n-- 400-cycle randomized sparse stream --");
        for (t = 0; t < 400; t = t + 1) begin
            if ($random % 5 == 0) begin
                valid_in = 0; @(negedge clk);
            end else begin
                drive_cycle(16'd2 + ({$random} % 50), 16'd1 + ({$random} % 12),
                            {$random} & {$random}, {$random});
                @(negedge clk);
            end
        end
        idle_cycles(30); check("randomized       ");

        $display("\n=========== MULTIPLIER-INPUT TOGGLE ACTIVITY ===========");
        $display(" items driven                       : %0d (zero: %0d = %0d%%)",
                 items_total, items_zero,
                 (items_total==0)?0:(100*items_zero)/items_total);
        $display(" multiplier-input changes, plain zs : %0d", mulin_plain);
        $display(" multiplier-input changes, input-reg: %0d", mulin_ir);
        $display(" reduction in multiplier switching  : %0d%%",
                 (mulin_plain==0)?0:(100*(mulin_plain-mulin_ir))/mulin_plain);
        $display("--------------------------------------------------------");
        $display(" 'plain zs' is also the BASELINE number: gating the product");
        $display(" register does not quiet the multiplier array. The gap");
        $display(" between these two rows is real power that plain zero-skip");
        $display(" claims from register-load counts but does not deliver.");
        $display("========================================================");
        if (errors == 0) $display(" RESULT: PASS - input-registered variant numerically correct");
        else             $display(" RESULT: FAIL - %0d error(s)", errors);
        $display("========================================================");
        $finish;
    end

    initial begin #300000; $display("TIMEOUT"); $finish; end

endmodule
