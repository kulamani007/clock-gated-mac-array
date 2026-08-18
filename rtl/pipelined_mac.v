// =============================================================================
// Module: pipelined_mac (refactored, cascade-ready)
// Description: 2-stage pipelined MAC. Uses the extracted
//              completion_aware_gate module instead of inline drain logic.
//
//              completion_out is exposed as a distinct signal from
//              valid_out so that downstream cascade stages have a clean
//              "new burst started" trigger to consume, separate from the
//              per-cycle "my data is valid" meaning of valid_out.
// =============================================================================

module pipelined_mac #(
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
    output wire                      completion_out   // cascade trigger for next stage
);

    // -------------------------------------------------------------------------
    // Completion-aware gating (extracted, reused)
    // -------------------------------------------------------------------------

    wire ce;
    wire operation_active;

    completion_aware_gate #(
        .DRAIN_DEPTH(2)              // 2 pipeline stages: multiply, accumulate
    ) gate_inst (
        .clk             (clk),
        .rst             (rst),
        .primary_enable  (primary_enable),
        .trigger_in      (valid_in),
        .ce              (ce),
        .operation_active(operation_active)
    );

    // -------------------------------------------------------------------------
    // Pipeline Stage 1: Multiply
    // -------------------------------------------------------------------------

    reg [2*DATA_WIDTH-1:0] mult_stage;

    always @(posedge clk or posedge rst) begin
        if (rst)
            mult_stage <= {(2*DATA_WIDTH){1'b0}};
        else if (ce)
            // explicit zero-extension - avoids silent width truncation
            mult_stage <= ({{DATA_WIDTH{1'b0}}, a}) * ({{DATA_WIDTH{1'b0}}, b});
    end

    // -------------------------------------------------------------------------
    // Pipeline validity tracker
    // -------------------------------------------------------------------------

    reg valid_pipe;

    always @(posedge clk or posedge rst) begin
        if (rst)
            valid_pipe <= 1'b0;
        else if (ce)
            valid_pipe <= valid_in;
        else
            valid_pipe <= 1'b0;
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 2: Accumulate
    // -------------------------------------------------------------------------

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc       <= {(2*DATA_WIDTH){1'b0}};
            valid_out <= 1'b0;
        end else if (ce) begin
            if (valid_pipe)
                acc <= acc + mult_stage;
            valid_out <= valid_pipe;
        end else begin
            valid_out <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Cascade trigger output
    // -------------------------------------------------------------------------
    // completion_out fires exactly when this stage produces a fresh, valid
    // result - i.e. the same cycle as valid_out. Named separately so the
    // next stage's gate consumes it as "trigger_in" rather than overloading
    // valid_out's meaning at the interface boundary.

    assign completion_out = valid_out;

endmodule
