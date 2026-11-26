#!/usr/bin/env python3
"""Expected PCR 5 'final-device-tree' digests, computed from the device tree Linux received.

The patched firmware measures the final DT with /chosen/rng-seed and /chosen/kaslr-seed (random
per boot; the kernel NOPs rng-seed itself after using it) and /chosen/bootloader/rsts (reset
reason: 0x1000 after power-on, 0x1020 after a reboot) replaced by FDT_NOP tokens, and
with the alignment padding after node names and property values zeroed (start.elf leaves it
uninitialised). Doing the same to /sys/firmware/fdt must reproduce the event-log digest.
Usage (on the Pi): sudo python3 final-dt-digest.py [/sys/firmware/fdt]
"""
import hashlib, struct, sys

SEEDS = (b"rng-seed", b"kaslr-seed", b"rsts")   # rsts: /chosen/bootloader reset reason (cold vs warm)
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP = 1, 2, 3, 4


def nop_seeds(blob):
    d = bytearray(blob)
    magic, total, off_struct, off_strings = struct.unpack(">IIII", d[:16])
    if magic != 0xD00DFEED:
        sys.exit("not a flattened device tree")
    size_struct = struct.unpack(">I", d[36:40])[0]
    p, end = off_struct, off_struct + size_struct
    while p < end:
        tok = struct.unpack(">I", d[p:p + 4])[0]
        if tok == FDT_BEGIN_NODE:
            name_end = d.index(0, p + 4) + 1
            p = (name_end + 3) & ~3
            d[name_end:p] = bytes(p - name_end)
        elif tok == FDT_PROP:
            length, nameoff = struct.unpack(">II", d[p + 4:p + 12])
            name = bytes(d[off_strings + nameoff:d.index(0, off_strings + nameoff)])
            nxt = (p + 12 + length + 3) & ~3
            d[p + 12 + length:nxt] = bytes(nxt - (p + 12 + length))
            if name in SEEDS:
                d[p:nxt] = struct.pack(">I", FDT_NOP) * ((nxt - p) // 4)
            p = nxt
        elif tok in (FDT_END_NODE, FDT_NOP):
            p += 4
        else:
            break
    return bytes(d[:total])


blob = nop_seeds(open(sys.argv[1] if len(sys.argv) > 1 else "/sys/firmware/fdt", "rb").read())
print("sha1  ", hashlib.sha1(blob).hexdigest())
print("sha256", hashlib.sha256(blob).hexdigest())
