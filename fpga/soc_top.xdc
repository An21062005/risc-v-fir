## soc_top timing constraints (S4)
## Board-independent: clock and reset timing only. NO pin assignment
## (PACKAGE_PIN) and NO IOSTANDARD here, because the target board is not
## specified. Before generating a bitstream add, from the board's master XDC:
##   set_property -dict {PACKAGE_PIN <pin> IOSTANDARD <std>} [get_ports clk]
##   ... same for rst_n, cpu_irq, bus_error
## (write_bitstream would otherwise stop with DRC NSTD-1 / UCIO-1).

## 100 MHz system clock on port clk
create_clock -period 10.000 -name sys_clk [get_ports clk]

## rst_n is asynchronous (button / external): it only drives the async
## assert of reset_sync (rtl/reset_sync.v); release is synchronised inside.
set_false_path -from [get_ports rst_n]

## cpu_irq / bus_error are observation outputs (LED / debug), no external
## timing relationship -> not timed.
set_false_path -to [get_ports {cpu_irq bus_error}]
