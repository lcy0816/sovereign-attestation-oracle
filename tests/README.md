# tests/ — Hardware Security Evaluation Suite

- **`test_security_suite.py`**: Automated security evaluation testbench reproducing the hardware attack defenses documented in Tables XII–XIII of the paper:

| Test  | Vector Description | Expected Hardware / Verifier Action |
|:-----:|:-------------------|:------------------------------------|
| **Test A**  | Genuine enclave quote request | Oracle generates valid Ed25519 quote (`STATUS_SUCCESS = 0x00`) |
| **Test B**  | Rogue `MRSIGNER` execution | Oracle rejects quote (`STATUS_ERR_POLICY_FAIL = 0x03`) |
| **Test C0** | Wholesale fabrication without EPC (no $K_{\text{pair}}$) | Oracle rejects quote (`STATUS_ERR_SILICON_AUTH_FAIL = 0x04`) |
| **Test C1** | 1-bit `MRENCLAVE` mutation | Remote verifier detects manifest divergence |
| **Test C2** | Channel binding tampering ($PK'_{\text{sess}} \ne PK_{\text{sess}}$) | Remote verifier detects $H_{\text{bind}}$ mismatch |
| **Test C3** | Stale quote replay | Remote verifier rejects non-monotonic $CTR$ |
| **Test D**  | Pushbutton policy write bypass (`CMD_SET_POLICY`) | Oracle rejects command (`STATUS_ERR_POLICY_FAIL = 0x03`) |

### Running the Suite

```sh
# Software Emulation mode (zero dependencies required)
python3 test_security_suite.py --simulate --iterations 1000

# Physical Hardware mode (over serial bus e.g. /dev/ttyUSB2)
python3 test_security_suite.py --device /dev/ttyUSB2 --baud 115200 \
    --pubkey-hex <64-char-hex-PK_FPGA> \
    --kpair-hex <64-char-hex-K_pair> \
    --iterations 1000
```

> **Note on Cryptographic Acceleration:**
> The test suite and remote verifier run completely out of the box with zero external dependencies via the self-contained RFC 8032 reference arithmetic engine in `host/remote_verifier.py`. Installing the optional `cryptography` Python package (`pip install cryptography`) automatically activates C-accelerated Ed25519 verification for maximum throughput during large (1,000+) test iterations.
