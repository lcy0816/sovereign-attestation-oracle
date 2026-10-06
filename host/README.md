# host/ — SGX Enclave Bridge & Remote Verifier

Host-side software and verification utilities for the SovereignOracle architecture:

- **`remote_verifier.py`**: Standalone remote verifier (Python 3, RFC 8032 Ed25519) that validates:
  1. Nonce freshness against the verifier challenge.
  2. Monotonic counter anti-replay ($CTR > \text{last\_ctr}$).
  3. Policy whitelist enforcement (`MRSIGNER` and `MIN_SVN`).
  4. In-EPC session channel binding ($H_{\text{bind}} = \text{SHA-256}(N_{\text{ver}} \parallel PK_{\text{sess}})$).
  5. Asymmetric Ed25519 digital signature issued by the hardware oracle.

- **`OracleEnclaveBridge` Specification**:
  - Target: Linux x86-64, Intel SGX SDK 2.24.
  - Generates in-EPC ephemeral session key pair via hardware `RDRAND`.
  - Derives pairing key $K_{\text{pair}}$ via `ENCLU[EGETKEY]` (`SEAL_KEY`, `KEYPOLICY=MRSIGNER`, `ATTRIBUTESMASK` enforcing `DEBUG=0`).
  - Computes silicon authentication tag $\tau_{\text{silicon}} = \text{SHA-512}(K_{\text{pair}} \parallel H_{\text{bind}} \parallel N_{\text{ver}})[0..31]$.
  - Interfaces with the discrete oracle via standard Linux serial UART (`/dev/ttyUSB*`).
