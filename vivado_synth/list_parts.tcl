set matches [get_parts -filter {FAMILY == "kintex7"}]
puts "KINTEX7_COUNT: [llength $matches]"
foreach p $matches {
    puts "PART: $p"
}
puts "===LIST_DONE==="
