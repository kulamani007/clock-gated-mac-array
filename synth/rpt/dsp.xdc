create_clock -period 4.0 -name sys_clk [get_ports clk]
set inp [remove_from_collection [get_ports -filter {DIRECTION == IN}] [get_ports clk]]
set_input_delay  -clock sys_clk 0.8 $inp
set_output_delay -clock sys_clk 0.8 [get_ports -filter {DIRECTION == OUT}]
