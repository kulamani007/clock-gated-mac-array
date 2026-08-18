set outdir "C:/Users/routk/Downloads/clock_gated_mac_array/vivado_synth/ir_variant"
set rtl    "C:/Users/routk/Downloads/clock_gated_mac_array/rtl"

read_verilog -sv [list \
    "$rtl/completion_aware_gate.v" \
    "$rtl/zero_skip_gate.v" \
    "$rtl/pipelined_mac_zs_ir.v" \
]

synth_design -top pipelined_mac_zs_ir -part xc7k160tffg676-2 -mode out_of_context

create_clock -period 5.000 -name clk [get_ports clk] -add
set_input_delay  -clock clk 0.5 [all_inputs]
set_output_delay -clock clk 0.5 [all_outputs]

write_checkpoint -force "$outdir/post_synth.dcp"

report_timing_summary -delay_type min_max -check_timing -max_paths 5 -file "$outdir/timing_summary.rpt"
report_utilization -hierarchical -file "$outdir/utilization.rpt"
report_power -file "$outdir/power_vectorless.rpt"

set dsp_cells [get_cells -hierarchical -filter {REF_NAME =~ "DSP48E1"}]
puts "===DSP48_CELL_COUNT: [llength $dsp_cells]==="
foreach c $dsp_cells {
    puts "DSP_CELL: $c  REF_NAME: [get_property REF_NAME $c]"
}

puts "===IR_VARIANT_SYNTH_DONE==="
