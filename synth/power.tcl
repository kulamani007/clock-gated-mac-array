# =============================================================================
# power.tcl - SAIF-driven power analysis on a routed checkpoint.
# usage: vivado -mode batch -source power.tcl -tclargs <tag> <saiffile> <label>
# =============================================================================
set tag   [lindex $argv 0]
set saif  [lindex $argv 1]
set label [lindex $argv 2]

set here [pwd]
open_checkpoint [file join $here dcp ${tag}_routed.dcp]

read_saif -strip_path tb_power/dut [file join $here saif $saif]

set rptf [file join $here rpt power_${tag}_${label}.rpt]
report_power -file $rptf

# ---- parse the report back out into a CSV row ------------------------------
set dyn  "NA"
set tot  "NA"
set conf "NA"
set sig  "NA"
set logic "NA"
set dsp  "NA"
set clk  "NA"

set fh [open $rptf r]
set data [read $fh]
close $fh
foreach line [split $data "\n"] {
    if {[regexp {Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)} $line -> v]} { set tot $v }
    if {[regexp {Dynamic \(W\)\s*\|\s*([0-9.]+)}            $line -> v]} { set dyn $v }
    if {[regexp {Confidence Level\s*\|\s*(\S+)}             $line -> v]} { set conf $v }
    if {[regexp {^\|\s*Signals\s*\|\s*([0-9.]+)}            $line -> v]} { set sig $v }
    if {[regexp {^\|\s*Slice Logic\s*\|\s*([0-9.]+)}        $line -> v]} { set logic $v }
    if {[regexp {^\|\s*DSPs\s*\|\s*([0-9.]+)}               $line -> v]} { set dsp $v }
    if {[regexp {^\|\s*Clocks\s*\|\s*([0-9.]+)}             $line -> v]} { set clk $v }
}

set sf [open [file join $here rpt summary_power.csv] a]
puts $sf "$tag,$label,$tot,$dyn,$clk,$sig,$logic,$dsp,$conf"
close $sf

puts "POWERSUM $tag $label total=$tot dynamic=$dyn clocks=$clk signals=$sig logic=$logic dsp=$dsp conf=$conf"
exit
