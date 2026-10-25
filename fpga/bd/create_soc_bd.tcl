# Reproducible, wiring-only integration of the existing SoC RTL.
set repo [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set cfg [lindex $argv 2]
set image [file normalize [lindex $argv 3]]
set do_synth [expr {[llength $argv] > 4 ? [lindex $argv 4] : 0}]
if {$cfg ni {A B C}} { error "Configuration must be A, B or C" }
file mkdir $out
cd $out
set enabled [expr {$cfg ne "A"}]
set cached [expr {$cfg eq "C"}]
create_project -force soc_bd $out/project -part xc7z020clg484-1
set_property target_language Verilog [current_project]
set_property ip_repo_paths [list $repo/fpga/bd/interfaces] [current_project]
update_ip_catalog
set_property include_dirs [list $repo/rtl/packages] [get_filesets sources_1]
set_property include_dirs [list $repo/rtl/packages] [get_filesets sim_1]

set rtl_sources {}
foreach list_name {filelist_fir11.f filelist_ext_ram_sim.f} {
    set f [open $repo/rtl/$list_name r]
    foreach line [split [read $f] "\n"] {
        set line [string trim $line]
        if {[string match "*.v" $line] && $line ne "rtl/soc_top.v"} {
            add_files -norecurse $repo/$line
            lappend rtl_sources $repo/$line
        }
    }
    close $f
}
add_files -norecurse [glob $repo/fpga/bd/rtl/*.v]
add_files -norecurse [glob $repo/rtl/packages/*.vh]
foreach name {program.mem data.mem} {
    file copy -force $image/$name $out/$name
    add_files -norecurse $out/$name
}
foreach f [glob $repo/rtl/Peripherals/FIR11/*.dat] {
    file copy -force $f $out/[file tail $f]
    add_files -norecurse $out/[file tail $f]
}

create_bd_design soc_system
foreach {cell reference} {
    CPU bd_cpu
    AXI_Master bd_axi_master
    Interconnect bd_interconnect
    Timer bd_timer
    FIR_Accelerator bd_fir
    Interrupt bd_interrupt
    Reset bd_reset
} {
    create_bd_cell -type module -reference $reference $cell
}
set_property CONFIG.ENABLE_EXT_RAM $enabled [get_bd_cells Interconnect]
if {$enabled} {
    create_bd_cell -type module -reference bd_ram External_RAM
    set_property CONFIG.USE_CACHE $cached [get_bd_cells External_RAM]
    connect_bd_intf_net [get_bd_intf_pins Interconnect/M_RAM] [get_bd_intf_pins External_RAM/S_RAM]
} else {
    # Optional RAM response remains tied low exactly as in soc_top.g_no_ext_ram.
    create_bd_cell -type module -reference bd_ram_disabled RAM_Disabled
    connect_bd_intf_net [get_bd_intf_pins Interconnect/M_RAM] [get_bd_intf_pins RAM_Disabled/S_RAM]
}
foreach {source target} {
    CPU/M_CPU AXI_Master/S_CPU
    AXI_Master/M_AXI Interconnect/S_AXI
    Interconnect/M_TIMER Timer/S_MMIO
    Interconnect/M_FIR FIR_Accelerator/S_MMIO
    Interconnect/M_IRQ Interrupt/S_MMIO
    AXI_Master/M_BUSERR Interrupt/S_BUSERR
} {
    connect_bd_intf_net [get_bd_intf_pins $source] [get_bd_intf_pins $target]
}
create_bd_port -dir I -type clk -freq_hz 100000000 clk
create_bd_port -dir I -type rst rst_n
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports rst_n]
create_bd_port -dir O -type intr cpu_irq
create_bd_port -dir O bus_error
foreach cell {CPU AXI_Master Interconnect Timer FIR_Accelerator Interrupt Reset} {
    connect_bd_net [get_bd_ports clk] [get_bd_pins $cell/clk]
}
if {$enabled} { connect_bd_net [get_bd_ports clk] [get_bd_pins External_RAM/clk] }
if {!$enabled} { connect_bd_net [get_bd_ports clk] [get_bd_pins RAM_Disabled/clk] }
connect_bd_net [get_bd_ports rst_n] [get_bd_pins Reset/rst_n_in]
foreach cell {CPU AXI_Master Interconnect Timer FIR_Accelerator Interrupt} {
    connect_bd_net [get_bd_pins Reset/rst_n_out] [get_bd_pins $cell/rst_n]
}
if {$enabled} { connect_bd_net [get_bd_pins Reset/rst_n_out] [get_bd_pins External_RAM/rst_n] }
if {!$enabled} { connect_bd_net [get_bd_pins Reset/rst_n_out] [get_bd_pins RAM_Disabled/rst_n] }
connect_bd_net [get_bd_pins Timer/irq] [get_bd_pins Interrupt/timer_irq]
connect_bd_net [get_bd_pins FIR_Accelerator/irq] [get_bd_pins Interrupt/fir_irq]
connect_bd_net [get_bd_pins Interrupt/cpu_irq] [get_bd_pins CPU/irq] [get_bd_ports cpu_irq]
connect_bd_net [get_bd_pins AXI_Master/bus_error] [get_bd_ports bus_error]
# Metadata for the single existing decoder, not an extra address translator.
assign_bd_address -offset 0x00000000 -range 0x40000000 \
    -target_address_space [get_bd_addr_spaces AXI_Master/M_AXI] \
    [get_bd_addr_segs Interconnect/S_AXI/reg0]
validate_bd_design
save_bd_design
set bd [get_files */soc_system.bd]
generate_target all $bd
set wrapper [make_wrapper -files $bd -top]
add_files -norecurse $wrapper
set_property top soc_system_wrapper [get_filesets sources_1]
set_property top soc_system_wrapper [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Plain HDL manifest used by the integration simulation; includes generated BD cells.
set generated $out/project/soc_bd.gen/sources_1/bd/soc_system
foreach mode {sim synth} manifest {simulation synthesis} {
    set sources [concat $rtl_sources [glob $repo/fpga/bd/rtl/*.v] \
        [glob $generated/ip/*/$mode/*.v] [list $generated/$mode/soc_system.v] $wrapper]
    set f [open $out/${manifest}_sources.txt w]
    foreach src $sources { puts $f [file normalize $src] }
    close $f
}
write_bd_tcl -force $out/recreate_export.tcl
save_bd_design
puts "BD_CREATED cfg=$cfg top=soc_system_wrapper"
close_project

if {$do_synth} {
    # Synthesize the exported whole BD HDL without OOC black boxes or IP runs.
    create_project -in_memory -part xc7z020clg484-1
    set f [open $out/synthesis_sources.txt r]
    set sources [split [string trim [read $f]] "\n"]
    close $f
    read_verilog $sources
    read_xdc $repo/fpga/soc_top.xdc
    synth_design -top soc_system_wrapper -part xc7z020clg484-1 \
        -include_dirs [list $repo/rtl/packages] -flatten_hierarchy rebuilt
    write_checkpoint -force $out/post_synth.dcp
    report_utilization -file $out/util_synth.txt
    report_utilization -hierarchical -hierarchical_depth 5 -file $out/util_synth_hier.txt
    report_timing_summary -max_paths 10 -file $out/timing_synth.txt
    check_timing -file $out/check_timing.txt
    report_drc -file $out/drc_synth.txt
    puts "BD_SYNTH_DONE cfg=$cfg"
    close_project
}
