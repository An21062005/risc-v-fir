# Synthesis soc_top và xuất báo cáo; tùy chọn place/route, không tạo bitstream.

set proj   [file normalize [lindex $argv 0]]
set image  [file normalize [lindex $argv 1]]
set out    [file normalize [lindex $argv 2]]
set impl   [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0}]
set cfg    [expr {[llength $argv] > 4 ? [lindex $argv 4] : "C"}]
set part   xc7z020clg484-1   ;# resource/timing reference only; board/pins not specified

file mkdir $out
cd $out
foreach f {program.mem data.mem} { file copy -force $image/$f $out/$f }
foreach f [glob $proj/rtl/Peripherals/FIR11/*.dat] { file copy -force $f $out/ }

set files {}
set lists [list $proj/rtl/filelist_fir11.f]
if {$cfg eq "C"} { lappend lists $proj/rtl/filelist_ext_ram_sim.f }
foreach fl $lists {
    set fh [open $fl r]
    foreach line [split [read $fh] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string match "//*" $line] || [string match "+*" $line]} continue
        if {[string match "*.v" $line]} { lappend files $proj/$line }
    }
    close $fh
}
read_verilog $files
read_xdc $proj/fpga/soc_top.xdc

set generics {}
if {$cfg eq "C"} { set generics {ENABLE_EXT_RAM=1 EXT_RAM_USE_CACHE=1} }
synth_design -top soc_top -part $part -include_dirs [list $proj/rtl/packages] \
    -generic $generics -flatten_hierarchy rebuilt
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/util_synth.txt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/util_synth_hier.txt
report_timing_summary -max_paths 10 -file $out/timing_synth.txt
check_timing -file $out/check_timing.txt
report_methodology -file $out/methodology_synth.txt
report_drc -file $out/drc_synth.txt

if {$impl} {
    opt_design
    place_design
    route_design
    write_checkpoint -force $out/post_route.dcp
    report_utilization -file $out/util_route.txt
    report_timing_summary -max_paths 10 -report_unconstrained -file $out/timing_route.txt
    report_clock_utilization -file $out/clock_util.txt
    report_drc -file $out/drc_route.txt
}
puts "SYNTH_SOC_DONE cfg=$cfg impl=$impl"
