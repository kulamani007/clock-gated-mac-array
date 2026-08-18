set all_parts [get_parts]
puts "TOTAL_PARTS: [llength $all_parts]"
set families {}
foreach p $all_parts {
    set fam [get_property FAMILY $p]
    if {[lsearch $families $fam] == -1} {
        lappend families $fam
    }
}
puts "===FAMILIES==="
foreach f $families {
    puts "FAMILY: $f"
}
puts "===LIST_DONE==="
