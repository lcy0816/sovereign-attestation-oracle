# SovereignOracle — Artifact (Anonymous)

**Sovereign Attestation: Decoupling Confidential Computing from Silicon Vendor
Clouds via Discrete Hardware Roots of Trust** — companion artifact for the
anonymized submission.

This repository contains the open-source hardware root-of-trust implementation
evaluated in the paper: a discrete companion security chip (Xilinx Artix-7
FPGA prototype and Synopsys SAED 14-nm FinFET ASIC signoff) that issues
vendor-independent Ed25519 attestation quotes for stranded client Intel SGX
platforms (pre-FLC Core processors, Skylake–Comet Lake).

## Repository Layout

| Directory    | Contents |
|--------------|----------|
| `rtl/crypto/`   | Synthesizable Verilog for the RFC 8032 Ed25519 signing engine: `ed25519_sign` (top), `edwards25519` (24-state point multiplier), `curve25519_felm` (field add/sub/mul over 2^255−19), `sha512_core` + `sha512_consts.vh` (also reused for the silicon authentication tag τ_silicon), `mul512_seq`, `modL_red`. Corresponds to §V and Tables VI–VII of the paper. |
| `rtl/support/`  | UART RX/TX, tactile-debounce diagnostic display driver, and Nexys A7-100T pin constraints (XDC). |
| `fpga/vivado/`  | Vivado 2024.2 build flow (Makefile, build.sh, bitstream and programming TCL) targeting the XC7A100T-1CSG324C at 40.00 MHz (WNS = +0.779 ns). |
| `asic/`         | 14-nm FinFET PPA signoff report (Synopsys Design Compiler Ultra, SAED 14-nm RVT, ss0p72v25c corner): area, gate count, power, and timing across 60 / 150 / 170.94 MHz targets. Corresponds to Table IX. |
| `host/`         | SGX enclave bridge and remote verifier (Linux, Intel SGX SDK 2.24). |
| `tests/`        | Automated hardware security evaluation suite (1,000 iterations per attack vector; Tables XII–XIII). |

## Hardware Testbed

- **Host**: Intel NUC7i5BNH, Core i5-7260U (Kaby Lake, SGX without FLC),
  Ubuntu 22.04.5 LTS, Intel SGX SDK 2.24.
- **Oracle**: Digilent Nexys 4 DDR (Xilinx Artix-7 XC7A100T-1CSG324C),
  40.00 MHz via MMCM, USB-UART at 115,200 baud.

## Building the FPGA Bitstream

```sh
cd fpga/vivado
make          # or: ./build.sh  (requires Vivado 2024.2 in PATH)
```

The flow synthesizes, places, routes, and writes the bitstream; program with
`vivado -mode batch -source program_fpga.tcl`.

## License

MIT (see `LICENSE`).

## Anonymity

This repository is anonymized for double-blind peer review. Author
identities, institutional paths, and git metadata have been removed.
