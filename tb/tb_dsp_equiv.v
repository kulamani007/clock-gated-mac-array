`timescale 1ns/1ps
// =============================================================================
// tb_dsp_equiv - checks the DSP-friendly (no datapath reset) variant against
// the asynchronously reset input-registered variant.
//
// Removing a reset to unlock DSP48 packing is exactly the kind of change that
// can leave an uninitialised register leaking into a result. The two designs
// are architecturally identical and differ only in reset style, so they must
// be cycle-for-cycle identical after reset. Any divergence means the reset was
// load-bearing after all.
// =============================================================================
module tb_dsp_equiv;
    localparam DW=16, NM=8;
    reg clk=0, rst=1;
    reg [NM-1:0] pe=0; reg pet=0;
    reg [NM-1:0] vin=0;
    reg [NM*DW-1:0] ab=0, bb=0;
    wire [2*DW+3-1:0] r_ir, r_ds;
    wire v_ir, v_ds;
    integer div=0, chk=0, pulses=0, t, n;
    reg [31:0] lf = 32'hACE1_2345;
    function [31:0] nxt(input [31:0] s);
        begin nxt = {s[30:0], s[31]^s[21]^s[1]^s[0]}; end
    endfunction

    mac_cascade_zs_ir_top  #(.DATA_WIDTH(DW), .NUM_MACS(NM)) d_ir (
        .clk(clk),.rst(rst),.primary_enable_mac(pe),.primary_enable_tree(pet),
        .valid_in(vin),.a_bus(ab),.b_bus(bb),.result(r_ir),.result_valid(v_ir));
    mac_cascade_zs_dsp_top #(.DATA_WIDTH(DW), .NUM_MACS(NM)) d_ds (
        .clk(clk),.rst(rst),.primary_enable_mac(pe),.primary_enable_tree(pet),
        .valid_in(vin),.a_bus(ab),.b_bus(bb),.result(r_ds),.result_valid(v_ds));

    always #5 clk = ~clk;
    always @(posedge clk) if (!rst) begin
        chk = chk + 1;
        if (v_ir) pulses = pulses + 1;
        if ((r_ir !== r_ds) || (v_ir !== v_ds)) begin
            if (div < 5) $display("  divergence cyc %0d: ir=%0d/%b ds=%0d/%b",
                                  chk, r_ir, v_ir, r_ds, v_ds);
            div = div + 1;
        end
    end

    initial begin
        rst=1; repeat(10) @(negedge clk); rst=0; @(negedge clk);
        for (t=0; t<3000; t=t+1) begin
            if (t % 17 == 0) begin
                vin = 0; @(negedge clk);
            end else begin
                for (n=0;n<NM;n=n+1) begin
                    lf = nxt(lf);
                    if ((lf[6:0] % 100) < 45) begin
                        if (n[0]) begin ab[n*DW+:DW]=0; bb[n*DW+:DW]=lf[23:8]; end
                        else      begin ab[n*DW+:DW]=lf[23:8]; bb[n*DW+:DW]=0; end
                    end else begin
                        ab[n*DW+:DW]=lf[23:8]; bb[n*DW+:DW]=lf[31:16];
                    end
                end
                vin = {NM{1'b1}};
                @(negedge clk);
            end
        end
        vin=0; repeat(30) @(negedge clk);
        $display("cycles=%0d result_valid pulses=%0d divergences=%0d", chk, pulses, div);
        if (pulses==0) $display("RESULT: INVALID - vacuous test");
        else if (div==0) $display("RESULT: PASS - DSP-friendly reset style is bit-identical");
        else $display("RESULT: FAIL - %0d divergences", div);
        $finish;
    end
endmodule
