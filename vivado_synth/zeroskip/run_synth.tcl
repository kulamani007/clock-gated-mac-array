set outdir "C:/Users/routk/Downloads/clock_gated_mac_array/vivado_synth/zeroskip"
set rtl    "C:/Users/routk/Downloads/clock_gated_mac_array/rtl"

read_verilog -sv [list \
    "$rtl/completion_aware_gate.v" \
    "$rtl/zero_skip_gate.v" \
    "$rtl/pipelined_mac_zs.v" \
    "$rtl/adder_tree_stage_zs.v" \
    "$rtl/mac_cascade_zs_top.v" \
]

synth_design -top mac_cascade_zs_top -part xc7k160tffg676-2 -mode out_of_context

create_clock -period 5.000 -name clk [get_ports clk] -add
set_input_delay  -clock clk 0.5 [all_inputs]
set_output_delay -clock clk 0.5 [all_outputs]

write_checkpoint -force "$outdir/post_synth.dcp"

report_timing_summary -delay_type min_max -check_timing -max_paths 5 -file "$outdir/timing_summary.rpt"
report_utilization -hierarchical -file "$outdir/utilization.rpt"
report_power -file "$outdir/power_vectorless.rpt"

puts "===ZEROSKIP_SYNTH_DONE==="
