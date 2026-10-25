# Run with Vivado -mode batch -source ... -tclargs <build output>.
set out [file normalize [lindex $argv 0]]
open_project $out/project/soc_bd.xpr
start_gui
open_bd_design [get_files */soc_system.bd]
set layout [file join [file dirname [info script]] soc_system.layout]
if {[llength [get_bd_cells -quiet External_RAM]] && [file isfile $layout]} {
    regenerate_bd_layout -layout_file $layout
} else {
    regenerate_bd_layout
}
write_bd_layout -force -format native $out/soc_system.layout
write_bd_layout -force -format svg $out/soc_system.svg
if {![file isfile $out/soc_system.svg]} { error "Vivado did not export the diagram" }
save_bd_design
close_project
stop_gui
exit
