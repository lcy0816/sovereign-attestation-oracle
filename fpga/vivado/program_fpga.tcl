# ==============================================================================
# Vivado Batch FPGA Programming Script
# Project: 02-sovereign-attestation-oracle
# ==============================================================================

set SCRIPT_DIR   [file dirname [file normalize [info script]]]
set BITSTREAM    "$SCRIPT_DIR/output/top_attestation_oracle.bit"

if {![file exists $BITSTREAM]} {
    puts "[-] Error: Bitstream file not found: $BITSTREAM"
    puts "[-] Please run 'make bitstream' first."
    exit 1
}

puts "===================================================================="
puts "  PROGRAMMING ARTIX-7 100T (SOVEREIGN ATTESTATION ORACLE)"
puts "  Bitstream: $BITSTREAM"
puts "===================================================================="

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
current_hw_target [get_hw_targets -nocase "*"]
open_hw_target

set_property PROGRAM.FILE $BITSTREAM [get_hw_devices xc7a100t_0]
program_hw_devices [get_hw_devices xc7a100t_0]
refresh_hw_device [lindex [get_hw_devices xc7a100t_0] 0]

puts "===================================================================="
puts "  FPGA PROGRAMMED SUCCESSFULLY!"
puts "===================================================================="
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
