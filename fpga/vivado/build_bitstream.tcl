# ==============================================================================
# Vivado Batch Bitstream Generation Script for Artix-7 100T (Nexys A7)
# Target Part: xc7a100tcsg324-1
# ==============================================================================

set PROJECT_NAME "proj_attestation_oracle"
set PART_NAME    "xc7a100tcsg324-1"
set TOP_MODULE   "ed25519_sign"
set SCRIPT_DIR   [file dirname [file normalize [info script]]]
set PROJ_DIR     "$SCRIPT_DIR/$PROJECT_NAME"
set RTL_CRYPTO   "$SCRIPT_DIR/../../rtl/crypto"
set RTL_SUPPORT  "$SCRIPT_DIR/../../rtl/support"
set OUTPUT_DIR   "$SCRIPT_DIR/output"

puts "===================================================================="
puts "  STARTING VIVADO BITSTREAM BUILD FOR SOVEREIGN ATTESTATION ORACLE"
puts "  Part: $PART_NAME"
puts "  Top:  $TOP_MODULE"
puts "===================================================================="

# Create output and project directories
file mkdir $OUTPUT_DIR
create_project -force $PROJECT_NAME $PROJ_DIR -part $PART_NAME

# Add RTL source files
add_files [list \
    "$RTL_SUPPORT/uart_rx.v" \
    "$RTL_SUPPORT/uart_tx.v" \
    "$RTL_SUPPORT/seven_seg_controller.v" \
    "$RTL_CRYPTO/sha512_consts.vh" \
    "$RTL_CRYPTO/sha512_core.v" \
    "$RTL_CRYPTO/curve25519_felm.v" \
    "$RTL_CRYPTO/edwards25519.v" \
    "$RTL_CRYPTO/mul512_seq.v" \
    "$RTL_CRYPTO/modL_red.v" \
    "$RTL_CRYPTO/ed25519_sign.v" \
]

# Add Constraints
add_files -fileset constrs_1 -norecurse "$RTL_SUPPORT/nexys_a7_100t.xdc"
set_property top $TOP_MODULE [current_fileset]

update_compile_order -fileset sources_1

# ------------------------------------------------------------------------------
# 1. Synthesis
# ------------------------------------------------------------------------------
puts "\n==> Running Synthesis..."
synth_design -top $TOP_MODULE -part $PART_NAME -flatten_hierarchy rebuilt
write_checkpoint -force "$OUTPUT_DIR/post_synth.dcp"
report_utilization -file "$OUTPUT_DIR/synth_utilization.rpt"
report_timing_summary -file "$OUTPUT_DIR/synth_timing.rpt"

# ------------------------------------------------------------------------------
# 2. Optimization and Placement
# ------------------------------------------------------------------------------
puts "\n==> Running Logic Optimization & Placement..."
opt_design
place_design
write_checkpoint -force "$OUTPUT_DIR/post_place.dcp"
report_utilization -file "$OUTPUT_DIR/place_utilization.rpt"
report_timing_summary -file "$OUTPUT_DIR/place_timing.rpt"

# ------------------------------------------------------------------------------
# 3. Routing
# ------------------------------------------------------------------------------
puts "\n==> Running Routing..."
route_design
write_checkpoint -force "$OUTPUT_DIR/post_route.dcp"
report_utilization -hierarchical -file "$OUTPUT_DIR/hierarchical_utilization.rpt"
report_timing_summary -file "$OUTPUT_DIR/route_timing.rpt"
report_drc -file "$OUTPUT_DIR/route_drc.rpt"

# ------------------------------------------------------------------------------
# 4. Generate Bitstream
# ------------------------------------------------------------------------------
puts "\n==> Writing Bitstream..."
write_bitstream -force "$OUTPUT_DIR/top_attestation_oracle.bit"

puts "===================================================================="
puts "  BITSTREAM GENERATION COMPLETE: $OUTPUT_DIR/top_attestation_oracle.bit"
puts "===================================================================="
exit 0
