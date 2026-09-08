# Post-implementation SAIF power analysis. Identical to power.tcl except that
# the SAIF comes from netlist simulation and the net-match rate is recorded,
# because that rate is what determines whether the number means anything.
set tag   [lindex $argv 0]
set saif  [lindex $argv 1]
set label [lindex $argv 2]

set here [pwd]
open_checkpoint [file join $here dcp ${tag}_routed.dcp]
read_saif -strip_path tb_power/dut [file join $here saifp $saif]

set rptf [file join $here rpt powerpost_${tag}_${label}.rpt]
report_power -file $rptf

set dyn NA; set tot NA; set conf NA; set sig NA
set logic NA; set dsp NA; set clk NA; set matched NA

set fh [open $rptf r]
set data [read $fh]
close $fh
foreach line [split $data "\n"] {
    if {[regexp {Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)} $line -> v]} { set tot $v }
    if {[regexp {Dynamic \(W\)\s*\|\s*([0-9.]+)}            $line -> v]} { set dyn $v }
    if {[regexp {Confidence Level\s*\|\s*(\S+)}             $line -> v]} { set conf $v }
    if {[regexp {Design Nets Matched\s*\|\s*(\d+)%}         $line -> v]} { set matched $v }
    if {[regexp {^\|\s*Signals\s*\|\s*([0-9.]+)}            $line -> v]} { set sig $v }
    if {[regexp {^\|\s*Slice Logic\s*\|\s*([0-9.]+)}        $line -> v]} { set logic $v }
    if {[regexp {^\|\s*DSPs\s*\|\s*([0-9.]+)}               $line -> v]} { set dsp $v }
    if {[regexp {^\|\s*Clocks\s*\|\s*([0-9.]+)}             $line -> v]} { set clk $v }
}

set sf [open [file join $here rpt summary_power_post.csv] a]
puts $sf "$tag,$label,$tot,$dyn,$clk,$sig,$logic,$dsp,${conf}(${matched}%)"
close $sf

puts "POSTPWR $tag $label dyn=$dyn clk=$clk dsp=$dsp conf=$conf matched=${matched}%"
exit
