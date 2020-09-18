create_clock -period 10.000 -name Genesis -waveform {0.000 5.000} [get_ports {S_Initiator\\.CLK}]
create_clock -period 2.900 -name BRAM -waveform {0.000 1.450} [get_ports {S_Target\\.CLK}]



set_clock_groups -name Genesis-to-BRAM -asynchronous -group [get_clocks BRAM] -group [get_clocks Genesis]








