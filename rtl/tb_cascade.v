`timescale 1ns/1ps

module tb_cascade;

    parameter DATA_WIDTH = 16;
    parameter NUM_MACS   = 8;

    reg clk = 0;
    reg rst = 1;

    reg [NUM_MACS-1:0]            primary_enable_mac = 0;
    reg                           primary_enable_tree = 0;
    reg [NUM_MACS-1:0]            valid_in = 0;
    reg [NUM_MACS*DATA_WIDTH-1:0] a_bus = 0;
    reg [NUM_MACS*DATA_WIDTH-1:0] b_bus = 0;

    wire [2*DATA_WIDTH+3-1:0] result;
    wire                      result_valid;

    integer expected_sum;
    integer cycle_count;
    integer errors = 0;

    mac_cascade_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_MACS  (NUM_MACS)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .primary_enable_mac  (primary_enable_mac),
        .primary_enable_tree (primary_enable_tree),
        .valid_in            (valid_in),
        .a_bus               (a_bus),
        .b_bus               (b_bus),
        .result              (result),
        .result_valid        (result_valid)
    );

    always #5 clk = ~clk;   // 100 MHz

    // cycle counter for trace readability
    always @(posedge clk) cycle_count = cycle_count + 1;

    // (verbose per-cycle trace removed after debugging - re-add if needed)

    task drive_all_macs(input [DATA_WIDTH-1:0] aval, input [DATA_WIDTH-1:0] bval);
        integer k;
        begin
            for (k = 0; k < NUM_MACS; k = k + 1) begin
                a_bus[k*DATA_WIDTH +: DATA_WIDTH] = aval + k;   // slightly different per MAC
                b_bus[k*DATA_WIDTH +: DATA_WIDTH] = bval;
            end
            valid_in = {NUM_MACS{1'b1}};
        end
    endtask

    task clear_valid;
        begin
            valid_in = {NUM_MACS{1'b0}};
        end
    endtask

    initial begin
        $display("=== Cascade testbench start ===");
        cycle_count = 0;
        rst = 1;
        #20;
        rst = 0;

        // ---------------------------------------------------------------
        // Test 1: single-cycle valid burst across all 8 MACs
        // ---------------------------------------------------------------
        @(negedge clk);
        drive_all_macs(16'd10, 16'd3);   // a = 10..17, b = 3 for all -> products 30,33,...,51
        @(negedge clk);
        clear_valid;

        // expected sum of products: sum_{k=0}^{7} (10+k)*3 = 3 * sum(10..17) = 3*108 = 324
        expected_sum = 324;

        // wait for the pulse (poll every cycle so we don't miss a 1-cycle pulse)
        wait (result_valid == 1'b1);
        $display("[T1] result_valid asserted at cycle %0d, result = %0d (expected %0d)",
                   cycle_count, result, expected_sum);
        if (result !== expected_sum) begin
            $display("[T1] FAIL: mismatch");
            errors = errors + 1;
        end else begin
            $display("[T1] PASS");
        end

        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------
        // Test 2: back-to-back bursts, no gap - verify pipeline doesn't
        // gate off mid-stream and accumulates correctly across two bursts
        // ---------------------------------------------------------------
        @(negedge clk);
        drive_all_macs(16'd1, 16'd2);   // burst A: a=1..8, b=2 -> products 2,4,..16, sum=72
        @(negedge clk);
        drive_all_macs(16'd5, 16'd2);   // burst B: a=5..12, b=2 -> products 10,12,..24, sum=136
        @(negedge clk);
        clear_valid;

        // NOTE: acc is cumulative since reset (by design - matches original
        // architecture, no per-burst clear). So this check must include
        // test 1's burst still sitting in each MAC's accumulator, plus
        // both bursts from this test.
        // per-MAC acc = (10+k)*3 [test1] + (1+k)*2 [burstA] + (5+k)*2 [burstB], summed over k=0..7
        expected_sum = 324 + 72 + 136;  // = 532

        wait (result_valid == 1'b1);
        $display("[T2] result_valid asserted at cycle %0d, result = %0d (expected %0d)",
                   cycle_count, result, expected_sum);
        if (result !== expected_sum) begin
            $display("[T2] FAIL: mismatch");
            errors = errors + 1;
        end else begin
            $display("[T2] PASS");
        end

        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------
        // Test 3: verify ce / operation_active actually drop during idle
        // (checked via internal signal probing on MAC 0 and the tree gate)
        // ---------------------------------------------------------------
        repeat (10) @(posedge clk);
        if (dut.mac_array_inst.MAC_ARRAY[0].mac_inst.gate_inst.operation_active !== 1'b0) begin
            $display("[T3] FAIL: MAC0 gate did not go idle after drain");
            errors = errors + 1;
        end else begin
            $display("[T3] PASS: MAC0 gate idle confirmed");
        end

        if (dut.adder_tree_inst.gate_inst.operation_active !== 1'b0) begin
            $display("[T3] FAIL: adder tree gate did not go idle after drain");
            errors = errors + 1;
        end else begin
            $display("[T3] PASS: adder tree gate idle confirmed");
        end

        $display("=== Cascade testbench done: %0d error(s) ===", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #2000;
        $display("TIMEOUT - result_valid never asserted as expected");
        $finish;
    end

endmodule
