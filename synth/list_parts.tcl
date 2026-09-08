puts "CANDIDATES:"
foreach p {xc7a100tcsg324-1 xc7a35tcpg236-1 xc7a200tsbg484-1 xc7z020clg400-1 xc7z010clg400-1} {
    if {[llength [get_parts -quiet $p]] > 0} { puts "OK   $p" } else { puts "MISS $p" }
}
puts "TOTAL_ARTIX [llength [get_parts -quiet xc7a*]]"
exit
