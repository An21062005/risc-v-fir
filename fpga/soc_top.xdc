# Constraint clock 100 MHz; không gán chân board.

## 100 MHz system clock on port clk
create_clock -period 10.000 -name sys_clk [get_ports clk]

# # rst_n is asynchronous (button / external): it only drives the async
set_false_path -from [get_ports rst_n]

# # cpu_irq / bus_error are observation outputs (LED / debug), no external
set_false_path -to [get_ports {cpu_irq bus_error}]
