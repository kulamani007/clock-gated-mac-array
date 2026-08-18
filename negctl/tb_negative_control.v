`timescale 1ns/1ps
// =============================================================================
// tb_negative_control - proves tb_zero_skip's equivalence check has teeth.
//
// Runs the SHIPPED zero-skip design and the INTENTIONALLY NAIVE design against
// the verified baseline on the same three directed edge cases. Expected
// outcome: shipped = 0 divergences, naive = divergences (specifically on the
// zero-at-burst-end case). A test that cannot fail proves nothing; this shows
// the checker fails when it should.
// =============================================================================

module tb_negative_control;

    parameter DW = 16;
    parameter NM = 8;

    reg clk = 0, rst = 1;
    reg [NM-1:0] pe_mac = 0;
    reg pe_tree = 0;
    reg [NM-1:0] valid_in = 0;
    reg [NM*DW-1:0] a_bus = 0, b_bus = 0;

    wire [2*DW+3-1:0] res_ref, res_zs, res_bad;
    wire rval_ref, rval_zs, rval_bad;

    integer div_zs = 0, div_bad = 0, cyc = 0, cmp = 0;
    integer pulses_ref = 0, pulses_zs = 0, pulses_bad = 0;
    integer t;

    mac_cascade_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_ref (
        .clk(clk), .rst(rst), .primary_enable_mac(pe_mac),
        .primary_enable_tree(pe_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(res_ref), .result_valid(rval_ref));

    mac_cascade_zs_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_zs (
        .clk(clk), .rst(rst), .primary_enable_mac(pe_mac),
        .primary_enable_tree(pe_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(res_zs), .result_valid(rval_zs));

    mac_cascade_naive_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) dut_bad (
        .clk(clk), .rst(rst), .primary_enable_mac(pe_mac),
        .primary_enable_tree(pe_tree), .valid_in(valid_in),
        .a_bus(a_bus), .b_bus(b_bus), .result(res_bad), .result_valid(rval_bad));

    always #5 clk = ~clk;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (!rst) begin
            cmp = cmp + 1;
            if (rval_ref) pulses_ref = pulses_ref + 1;
            if (rval_zs)  pulses_zs  = pulses_zs  + 1;
            if (rval_bad) pulses_bad = pulses_bad + 1;
            if ((res_ref !== res_zs) || (rval_ref !== rval_zs))
                div_zs = div_zs + 1;
            if ((res_ref !== res_bad) || (rval_ref !== rval_bad))
                div_bad = div_bad + 1;
        end
    end

    task drive_cycle(input [DW-1:0] ba, input [DW-1:0] bb, input zero_all);
        integer n;
        begin
            for (n = 0; n < NM; n = n + 1) begin
                a_bus[n*DW +: DW] = zero_all ? 16'd0 : (ba + n);
                b_bus[n*DW +: DW] = bb;
            end
            valid_in = {NM{1'b1}};
        end
    endtask

    task idle(input integer n);
        integer m;
        begin valid_in = 0; for (m=0;m<n;m=m+1) @(negedge clk); end
    endtask

    initial begin
        $display("=====================================================");
        $display(" NEGATIVE CONTROL: does the equivalence check fail");
        $display(" when the design is actually wrong?");
        $display("=====================================================");
        rst = 1; #23; rst = 0;
        @(negedge clk);

        // zero mid-burst
        drive_cycle(16'd10,16'd3,0); @(negedge clk);
        drive_cycle(16'd20,16'd4,1); @(negedge clk);
        drive_cycle(16'd30,16'd5,0); @(negedge clk);
        idle(15);

        // zero at burst start
        drive_cycle(16'd11,16'd3,1); @(negedge clk);
        drive_cycle(16'd12,16'd6,0); @(negedge clk);
        idle(15);

        // zero at burst END  <-- the case that should break the naive design
        drive_cycle(16'd14,16'd2,0); @(negedge clk);
        drive_cycle(16'd15,16'd3,0); @(negedge clk);
        drive_cycle(16'd16,16'd9,1); @(negedge clk);
        idle(20);

        // randomized sparse traffic
        for (t = 0; t < 200; t = t + 1) begin
            drive_cycle(16'd2 + ({$random} % 30), 16'd1 + ({$random} % 9),
                        (({$random} % 3) == 0));
            @(negedge clk);
        end
        idle(25);

        $display("\n cycles compared            : %0d", cmp);
        $display(" result_valid pulses ref    : %0d   (non-vacuity check)", pulses_ref);
        $display(" result_valid pulses zs     : %0d", pulses_zs);
        $display(" result_valid pulses naive  : %0d", pulses_bad);
        $display("");
        $display(" divergences  SHIPPED vs ref: %0d", div_zs);
        $display(" divergences  NAIVE   vs ref: %0d", div_bad);
        $display("");
        if (pulses_ref == 0)
            $display(" >> INVALID: reference never produced a result. Test is vacuous.");
        else if (div_zs == 0 && div_bad > 0)
            $display(" >> PASS: checker has teeth. Shipped design clean, naive design caught.");
        else if (div_zs != 0)
            $display(" >> FAIL: the SHIPPED design diverged. Real bug.");
        else
            $display(" >> INCONCLUSIVE: naive design was not caught - checker too weak.");
        $display("=====================================================");
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $finish; end

endmodule
