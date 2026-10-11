puts "SC88_VIVADO_VERSION=[version -short]"
if {[llength [get_parts xc7z010clg400-1]] != 1} {
    error "Target part xc7z010clg400-1 is unavailable"
}
puts "SC88_TARGET_PART_AVAILABLE"
exit 0
