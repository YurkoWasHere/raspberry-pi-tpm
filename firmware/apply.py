#!/usr/bin/env python3
"""Apply the measured-boot payload to a stock bootcode.bin.

The payload blob is one assembled section that starts at the hook address rounded down to 4 (so
alignment inside it matches real addresses): its 4 bytes at the hook replace the `bl` there, and its
bytes from PAYLOAD_ADDR on are appended at file offset PAYLOAD_ADDR - LOAD_ADDR (zero-padded).

Only the exact stock bootcode.bin the payload was written for is accepted.

  apply.py <stock bootcode.bin> <tpm-measure.blob> <out> [--no-uart]
"""
import hashlib, sys

LOAD_ADDR = 0x80000000
HOOK_ADDR = 0x80001662                 # bl 0x80001720: runs after every file bootcode.bin reads
PAYLOAD_ADDR = 0x80010000
STOCK_SHA256 = "4245ec23b58158dc3e55f3e065eb4ecc0c0705d76c8db506e9f824941feee32e"  # raspi-firmware 1:1.20260915-1
HOOK_ORIG = bytes.fromhex("80905f00")


def patch(stock: bytes, blob: bytes, uart: bool = True) -> bytes:
    if hashlib.sha256(stock).hexdigest() != STOCK_SHA256:
        raise ValueError("not the stock bootcode.bin this payload was written for "
                         f"(need sha256 {STOCK_SHA256[:16]}…, raspi-firmware 1:1.20260915-1)")
    img = bytearray(stock)
    hook_off = HOOK_ADDR - LOAD_ADDR
    if img[hook_off:hook_off + 4] != HOOK_ORIG:
        raise ValueError("hook site does not hold the expected instruction")
    base = HOOK_ADDR & ~3
    img[hook_off:hook_off + 4] = blob[HOOK_ADDR - base:HOOK_ADDR - base + 4]
    if uart:
        img[img.index(b"BOOT_UART=0") + 10] = ord("1")   # bootcode.bin (and our TPM lines) log to serial
    off = PAYLOAD_ADDR - LOAD_ADDR
    return bytes(img + bytes(off - len(img)) + blob[PAYLOAD_ADDR - base:])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 3:
        sys.exit(__doc__)
    stock, blob, out = args
    img = patch(open(stock, "rb").read(), open(blob, "rb").read(), uart="--no-uart" not in sys.argv)
    open(out, "wb").write(img)
    print(f"{out}: {len(img)} bytes, sha256 {hashlib.sha256(img).hexdigest()}")


if __name__ == "__main__":
    main()
