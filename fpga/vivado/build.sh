#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v vivado &> /dev/null; then
    echo "[-] Error: 'vivado' not found in PATH."
    echo "[-] Ensure you have sourced Vivado settings (e.g., 'source <vivado_install_dir>/settings64.sh')"
    exit 1
fi

echo "[+] Starting Vivado bitstream synthesis for Sovereign Attestation Oracle..."
vivado -mode batch -notrace -source build_bitstream.tcl
echo "[+] Done! Bitstream generated at: $SCRIPT_DIR/output/top_attestation_oracle.bit"
