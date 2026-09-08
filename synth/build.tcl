# =============================================================================
# build.tcl - out-of-context synthesis + implementation for one cascade top.
#
# OOC is required (the cascade has 311 ports vs 210 user I/O on xc7a100t) and
# is also the correct choice for a core-level power study: no I/O buffer power
# contaminates the comparison.
#
# usage: vivado -mode batch -source build.tcl -tclargs <top> <tag> <part> <period_ns>
# =============================================================================

set top    [lindex $argv 0]
set tag    [lindex $argv 1]
set part   [lindex $argv 2]
set period [lindex $argv 3]

set here [pwd]
set root [file normalize [file join $here ..]]
file mkdir [file join $here rpt]
file mkdir [file join $here dcp]

read_verilog [list \
  [file join $root rtl completion_aware_gate.v] \
  [file join $root rtl pipelined_mac.v] \
  [file join $root rtl adder_tree_stage.v] \
  [file join $root rtl mac_array_and_cascade_top.v] \
  [file join $root rtl zero_skip_gate.v] \
  [file join $root rtl pipelined_mac_zs.v] \
  [file join $root rtl adder_tree_stage_zs.v] \
  [file join $root rtl mac_cascade_zs_top.v] \
  [file join $root rtl pipelined_mac_zs_ir.v] \
  [file join $root rtl pipelined_mac_zs_dsp.v] ]

# ---- constraints ------------------------------------------------------------
set xdc [file join $here rpt ${tag}.xdc]
set fh [open $xdc w]
puts $fh "create_clock -period $period -name sys_clk \[get_ports clk\]"
# Budget 20% of the period to off-core delay on BOTH inputs and outputs.
# NOTE: do NOT false-path the inputs. The baseline and plain zero-skip feed
# their multipliers directly from ports, whereas the input-registered variant
# feeds them from registers; false-pathing inputs would exclude the former's
# multiplier-input paths from analysis entirely and make the Fmax comparison
# meaningless. Timing every path uniformly is what keeps the three designs
# comparable.
puts $fh "set inp \[remove_from_collection \[get_ports -filter {DIRECTION == IN}\] \[get_ports clk\]\]"
puts $fh "set_input_delay  -clock sys_clk [expr {$period*0.2}] \$inp"
puts $fh "set_output_delay -clock sys_clk [expr {$period*0.2}] \[get_ports -filter {DIRECTION == OUT}\]"
close $fh

synth_design -top $top -part $part -mode out_of_context
read_xdc $xdc
report_utilization -file [file join $here rpt ${tag}_synth_util.rpt]

opt_design
place_design
phys_opt_design
route_design

report_utilization    -file [file join $here rpt ${tag}_impl_util.rpt]
report_timing_summary -file [file join $here rpt ${tag}_timing.rpt]
report_power          -file [file join $here rpt ${tag}_power_vecless.rpt]
write_checkpoint -force [file join $here dcp ${tag}_routed.dcp]

# ---- machine-readable summary ----------------------------------------------
set nLUT  [llength [get_cells -hier -quiet -filter {REF_NAME =~ LUT*}]]
set nFF   [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
set nDSP  [llength [get_cells -hier -quiet -filter {REF_NAME =~ DSP48*}]]
set nCARRY [llength [get_cells -hier -quiet -filter {REF_NAME =~ CARRY*}]]
set nBUFG [llength [get_cells -hier -quiet -filter {REF_NAME =~ BUFG*}]]

# clock-enable / clock-gating cells actually inferred
set nBUFGCE [llength [get_cells -hier -quiet -filter {REF_NAME =~ BUFGCE*}]]

# Are the DSP48's OWN pipeline registers being used, or is it acting as a bare
# combinational multiplier with fabric flops bolted around it? This matters:
# an unregistered DSP means the multiply array is only as quiet as whatever
# fabric register drives its A/B inputs.
set dsps [get_cells -hier -quiet -filter {REF_NAME =~ DSP48*}]
set areg 0; set breg 0; set mreg 0; set preg 0
foreach d $dsps {
    if {[get_property -quiet AREG $d] > 0} { incr areg }
    if {[get_property -quiet BREG $d] > 0} { incr breg }
    if {[get_property -quiet MREG $d] > 0} { incr mreg }
    if {[get_property -quiet PREG $d] > 0} { incr preg }
}
puts "DSPREG $tag AREG=$areg BREG=$breg MREG=$mreg PREG=$preg of [llength $dsps]"

set paths [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $paths] > 0} {
    set wns [get_property SLACK [lindex $paths 0]]
} else {
    set wns 999
}
set fmax [expr {1000.0 / ($period - $wns)}]

set sf [open [file join $here rpt summary_area.csv] a]
puts $sf "$tag,$top,$part,$period,$nLUT,$nFF,$nDSP,$nCARRY,$nBUFG,$nBUFGCE,$wns,[format %.1f $fmax]"
close $sf

puts "SUMMARY $tag LUT=$nLUT FF=$nFF DSP=$nDSP CARRY=$nCARRY BUFG=$nBUFG BUFGCE=$nBUFGCE WNS=$wns FMAX=[format %.1f $fmax]MHz"
exit
