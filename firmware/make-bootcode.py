#!/usr/bin/env python3
"""Produce a measured-boot bootcode.bin from the stock Raspberry Pi firmware.

Downloads the official raspi-firmware package (or uses a bootcode.bin you already have), checks both
hashes, and applies tpm-measure.blob. Python standard library only; runs on the Pi too.

  ./make-bootcode.py                        # download raspi-firmware 1:1.20260915-1, write ./bootcode.bin
  ./make-bootcode.py --stock /boot/firmware/bootcode.bin -o bootcode.bin
  ./make-bootcode.py --no-uart              # don't enable bootcode.bin's serial log

The patched file contains Broadcom code: keep it for your own use, don't redistribute it.
"""
import argparse, hashlib, io, lzma, sys, tarfile, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apply  # noqa: E402

DEB_URL = ("http://archive.raspberrypi.com/debian/pool/main/r/raspi-firmware/"
           "raspi-firmware_1.20260915-1_all.deb")
DEB_SHA256 = "56b6f8792fb27bcc22f101a5a0d27af637e0d13e85dfc0fde5ff140abc929b0f"
MEMBER = "usr/lib/raspi-firmware/bootcode.bin"


def ar_members(data):
    """Yield (name, bytes) from a Debian package (ar archive)."""
    if data[:8] != b"!<arch>\n":
        raise ValueError("not an ar archive")
    pos = 8
    while pos < len(data):
        hdr = data[pos:pos + 60]
        name, size = hdr[:16].decode().strip().rstrip("/"), int(hdr[48:58])
        yield name, data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)


def stock_from_deb():
    print(f"downloading {DEB_URL}")
    deb = urllib.request.urlopen(DEB_URL, timeout=120).read()
    if hashlib.sha256(deb).hexdigest() != DEB_SHA256:
        sys.exit("package sha256 mismatch")
    for name, body in ar_members(deb):
        if name.startswith("data.tar"):
            if name.endswith(".xz"):
                body = lzma.decompress(body)
            with tarfile.open(fileobj=io.BytesIO(body)) as tar:
                for m in tar.getmembers():
                    f = tar.extractfile(m) if m.name.lstrip("./") == MEMBER else None
                    if f:
                        return f.read()
    sys.exit(f"{MEMBER} not found in package")


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="Produce a measured-boot bootcode.bin from stock firmware")
    ap.add_argument("--stock", help="stock bootcode.bin to patch instead of downloading")
    ap.add_argument("--blob", default=str(here / "tpm-measure.blob"))
    ap.add_argument("-o", "--out", default="bootcode.bin")
    ap.add_argument("--no-uart", action="store_true")
    a = ap.parse_args()
    stock = Path(a.stock).read_bytes() if a.stock else stock_from_deb()
    img = apply.patch(stock, Path(a.blob).read_bytes(), uart=not a.no_uart)
    Path(a.out).write_bytes(img)
    print(f"{a.out}: {len(img)} bytes, sha256 {hashlib.sha256(img).hexdigest()}")


if __name__ == "__main__":
    main()
