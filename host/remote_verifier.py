#!/usr/bin/env python3
"""
Sovereign Remote Attestation Verifier (RFC 8032 Ed25519)
Decoupled Hardware Root of Trust for Stranded Client Intel SGX Platforms.
Conforms strictly to Table III, Equation (7), and Algorithm 2 of the manuscript.

Features:
  - Fails closed on any structural, temporal, policy, or cryptographic anomaly.
  - Zero external dependencies required: utilizes C-accelerated 'cryptography'
    when present, with a fast, self-contained RFC 8032 reference implementation
    using Extended Projective Coordinates (X:Y:Z:T) as defined in §V.
"""

import sys
import struct
import hashlib

# -----------------------------------------------------------------------------
# Fast RFC 8032 Ed25519 Arithmetic in Extended Coordinates (X:Y:Z:T)
# -----------------------------------------------------------------------------
_P = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_2D = (2 * _D) % _P
_I = pow(2, (_P - 1) // 4, _P)

def _inv(z):
    return pow(z, _P - 2, _P)

def _xrecover(y):
    xx = (y * y - 1) * _inv(_D * y * y + 1)
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = (x * _I) % _P
    if x % 2 != 0:
        x = _P - x
    return x

_By = 4 * _inv(5) % _P
_Bx = _xrecover(_By)
_Bt = (_Bx * _By) % _P
_B_ext = (_Bx, _By, 1, _Bt)

def _pt_add(P, Q):
    """Complete addition formula in extended projective coordinates (Eq. 1-4)."""
    X1, Y1, Z1, T1 = P
    X2, Y2, Z2, T2 = Q
    A = (Y1 - X1) * (Y2 - X2) % _P
    B = (Y1 + X1) * (Y2 + X2) % _P
    C = T1 * _2D * T2 % _P
    D = 2 * Z1 * Z2 % _P
    E = (B - A) % _P
    F = (D - C) % _P
    G = (D + C) % _P
    H = (B + A) % _P
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)

def _pt_dbl(P):
    """Unified doubling formula in extended projective coordinates."""
    X1, Y1, Z1, T1 = P
    A = X1 * X1 % _P
    B = Y1 * Y1 % _P
    C = 2 * Z1 * Z1 % _P
    D = (-A) % _P
    E = ((X1 + Y1) * (X1 + Y1) - A - B) % _P
    G = (D + B) % _P
    F = (G - C) % _P
    H = (D - B) % _P
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)

def _pt_scalarmult_ext(P, k):
    """Multiplies point P by scalar k using extended coordinates."""
    R = (0, 1, 1, 0)
    for bit in bin(k)[2:]:
        R = _pt_dbl(R)
        if bit == '1':
            R = _pt_add(R, P)
    return R

def _to_affine(P):
    z_inv = _inv(P[2])
    return (P[0] * z_inv % _P, P[1] * z_inv % _P)

def _decodepoint_ext(s):
    y = int.from_bytes(s, "little")
    sign = (y >> 255) & 1
    y &= (1 << 255) - 1
    x = _xrecover(y)
    if x & 1 != sign:
        x = _P - x
    return (x, y, 1, (x * y) % _P)

def _rfc8032_verify(public_key: bytes, signature: bytes, message: bytes) -> bool:
    if len(public_key) != 32 or len(signature) != 64:
        return False
    R_bytes = signature[:32]
    S_bytes = signature[32:]
    s_val = int.from_bytes(S_bytes, "little")
    if s_val >= _L:
        return False
    try:
        A_ext = _decodepoint_ext(public_key)
        R_ext = _decodepoint_ext(R_bytes)
    except Exception:
        return False
    h = hashlib.sha512(R_bytes + public_key + message).digest()
    k = int.from_bytes(h, "little") % _L
    # Verify: 8*S*B == 8*R + 8*k*A
    sB = _to_affine(_pt_scalarmult_ext(_B_ext, (8 * s_val) % _L))
    kA = _pt_scalarmult_ext(A_ext, (8 * k) % _L)
    R8 = _pt_scalarmult_ext(R_ext, 8)
    rhs = _to_affine(_pt_add(R8, kA))
    return sB == rhs

def _rfc8032_sign(secret_key_seed: bytes, message: bytes) -> tuple:
    """Deterministic Ed25519 signature generation matching hardware RTL."""
    h = hashlib.sha512(secret_key_seed).digest()
    a_bytes = bytearray(h[:32])
    a_bytes[0] &= 248
    a_bytes[31] &= 127
    a_bytes[31] |= 64
    a = int.from_bytes(a_bytes, "little")
    A = _to_affine(_pt_scalarmult_ext(_B_ext, a))
    A_bytes = (A[1] | ((A[0] & 1) << 255)).to_bytes(32, "little")
    prefix = h[32:]
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % _L
    R = _to_affine(_pt_scalarmult_ext(_B_ext, r))
    R_bytes = (R[1] | ((R[0] & 1) << 255)).to_bytes(32, "little")
    k = int.from_bytes(hashlib.sha512(R_bytes + A_bytes + message).digest(), "little") % _L
    S = (r + k * a) % _L
    S_bytes = S.to_bytes(32, "little")
    return R_bytes, S_bytes, A_bytes

# Optional fast C-library
try:
    from cryptography.hazmat.primitives.asymmetric import ed25519
    _USE_C_CRYPTO = True
except ImportError:
    _USE_C_CRYPTO = False

def crc16_ccitt(data: bytes, init: int = 0xFFFF) -> int:
    """CRC-16-CCITT (Polynomial 0x1021, big-endian output)."""
    crc = init
    for b in data:
        crc ^= (b << 8)
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc

def verify_sovereign_quote(quote_bytes, expected_nonce, pk_sess, manifest_mrsigner,
                           manifest_mrenclave=None, min_svn=1, last_ctr=0, oracle_pubkey_bytes=None):
    """
    Validates a Sovereign Attestation Quote per Section IV and Algorithm 2:
      1. Structural parsing: 236 bytes wire quote (or 268 bytes with appended PK_FPGA).
         Layout:
           [0:32]    Nonce (32 B)
           [32:64]   MRENCLAVE (32 B)
           [64:96]   MRSIGNER (32 B)
           [96:98]   ISV_SVN (2 B, big-endian)
           [98:100]  ISV_PRODID (2 B, big-endian)
           [100:164] REPORTDATA (64 B) = H_bind[0..31] || tau_silicon[32..63]
           [164:172] Monotonic Counter CTR (8 B, big-endian)
           [172:204] Ed25519 Sig R (32 B)
           [204:236] Ed25519 Sig S (32 B)
           [236:268] (Optional) PK_FPGA (32 B)
      2. Nonce freshness against verifier challenge.
      3. Anti-replay check: CTR > last_ctr.
      4. Whitelist policy: MRSIGNER matches manifest, SVN >= min_svn, MRENCLAVE (if enforced).
      5. In-EPC session channel binding: H_bind == SHA-256(Nonce || PK_sess).
      6. Hardware Signature: Ed25519 verify(PK_FPGA, Preimage_172B, (R, S)).
         Preimage (172 B): Nonce(32) || MRENCLAVE(32) || MRSIGNER(32) ||
                           SVN(2) || PRODID(2) || REPORTDATA(64) || CTR(8)
    """
    if len(quote_bytes) < 236:
        return False, f"Quote size too short ({len(quote_bytes)} B < 236 B)"

    offset = 0
    nonce = quote_bytes[offset:offset+32]; offset += 32
    mrenclave = quote_bytes[offset:offset+32]; offset += 32
    mrsigner = quote_bytes[offset:offset+32]; offset += 32
    isv_svn, isv_prodid = struct.unpack(">HH", quote_bytes[offset:offset+4]); offset += 4
    reportdata = quote_bytes[offset:offset+64]; offset += 64
    h_bind = reportdata[0:32]
    tau_silicon = reportdata[32:64]
    ctr = struct.unpack(">Q", quote_bytes[offset:offset+8])[0]; offset += 8
    sig_r = quote_bytes[offset:offset+32]; offset += 32
    sig_s = quote_bytes[offset:offset+32]; offset += 32

    if oracle_pubkey_bytes is None:
        if len(quote_bytes) >= 268:
            oracle_pubkey_bytes = quote_bytes[236:268]
        else:
            return False, "Oracle public key (PK_FPGA) not provided and not embedded in quote."

    # 1. Nonce freshness check
    if nonce != expected_nonce:
        return False, f"Nonce mismatch: expected {expected_nonce.hex()}, got {nonce.hex()}"

    # 2. Monotonic counter anti-replay check
    if ctr <= last_ctr:
        return False, f"Replay detected: CTR ({ctr}) <= last verified counter ({last_ctr})"

    # 3. Policy whitelist & SVN checks
    if mrsigner != manifest_mrsigner:
        return False, f"Unauthorized MRSIGNER: {mrsigner.hex()} != {manifest_mrsigner.hex()}"
    if isv_svn < min_svn:
        return False, f"SVN rollback detected: enclave SVN {isv_svn} < required {min_svn}"
    if manifest_mrenclave and mrenclave != manifest_mrenclave:
        return False, f"MRENCLAVE divergence from manifest: {mrenclave.hex()} != {manifest_mrenclave.hex()}"

    # 4. In-EPC session channel binding check
    expected_h_bind = hashlib.sha256(nonce + pk_sess).digest()
    if h_bind != expected_h_bind:
        return False, "Channel binding violation: H_bind != SHA-256(Nonce || PK_sess)"

    # 5. Ed25519 signature verification over full 172-byte canonical signed preimage
    signed_preimage = (
        nonce +
        mrenclave +
        mrsigner +
        struct.pack(">HH", isv_svn, isv_prodid) +
        reportdata +
        struct.pack(">Q", ctr)
    )
    if len(signed_preimage) != 172:
        return False, f"Internal preimage length error: expected 172 B, got {len(signed_preimage)} B"

    signature = sig_r + sig_s

    # Fail closed: perform cryptographic verification
    valid_sig = False
    if _USE_C_CRYPTO:
        try:
            verifier = ed25519.Ed25519PublicKey.from_public_bytes(oracle_pubkey_bytes)
            verifier.verify(signature, signed_preimage)
            valid_sig = True
        except Exception:
            valid_sig = False
    else:
        valid_sig = _rfc8032_verify(oracle_pubkey_bytes, signature, signed_preimage)

    if not valid_sig:
        return False, "Cryptographic signature verification failed: invalid Ed25519 hardware signature"

    return True, f"Quote successfully verified (CTR={ctr}, SVN={isv_svn})"

if __name__ == "__main__":
    print("[+] Sovereign Remote Attestation Verifier loaded successfully.")
    print(f"[*] Cryptographic engine: {'C-accelerated (cryptography)' if _USE_C_CRYPTO else 'Pure-Python (RFC 8032 reference)'}")
