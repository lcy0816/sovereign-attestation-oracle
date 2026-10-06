# Makefile for Artix-7 100T Sovereign Attestation Oracle Flow

VIVADO ?= vivado
VIVADO_FLAGS = -mode batch -notrace

.PHONY: all bitstream program clean

all: bitstream

bitstream:
	@echo "==> Running Vivado Bitstream Build..."
	$(VIVADO) $(VIVADO_FLAGS) -source build_bitstream.tcl

program:
	@echo "==> Programming FPGA via JTAG..."
	$(VIVADO) $(VIVADO_FLAGS) -source program_fpga.tcl

clean:
	@echo "==> Cleaning Vivado build artifacts..."
	rm -rf output proj_attestation_oracle *.log *.jou .Xil
