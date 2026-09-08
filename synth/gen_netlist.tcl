# Emit a post-implementation functional simulation netlist for one design.
# Simulating THIS, rather than the RTL, is what lets the SAIF annotate the
# actual routed nets - including registers absorbed into DSP48 slices, which
# do not exist as nets in the RTL at all.
# usage: vivado -mode batch -source gen_netlist.tcl -tclargs <tag>
set tag [lindex $argv 0]
set here [pwd]
file mkdir [file join $here netlist]
open_checkpoint [file join $here dcp ${tag}_routed.dcp]
write_verilog -mode funcsim -force [file join $here netlist ${tag}_funcsim.v]
puts "NETLIST_WRITTEN $tag"
exit
