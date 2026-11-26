# Firmware notes (reverse engineering)

Firmware: `raspi-firmware` 1:1.20260915-1 (`bootcode.bin` sha256 `4245ec23…`, `start.elf` `32f99080…`,
`fixup.dat` `7853f2b5…`). All addresses are specific to these files. Disassembled with the
binutils-vc4 port (`tools/vc4`); the disassembly itself is not in this repo.

```bash
docker build -t vc4-binutils tools/vc4
docker run --rm -v "$PWD/re":/work vc4-binutils \
  vc4-elf-objdump -D -b binary -m vc4 --adjust-vma=0x80000000 bootcode.bin > re/bootcode.dis
```

## Boot sequence (network boot, from the TFTP log)

| Loader | Files requested |
|---|---|
| Boot ROM | `bootcode.bin` (DHCP + TFTP by the ROM) |
| bootcode.bin | `bootsig.bin` (missing), `<serial>/start.elf` (missing), `autoboot.txt`, `config.txt`, `recovery.elf`, `start.elf`, `fixup.dat` |
| start.elf | `dt-blob.bin`, `bootcfg.txt`, base DTB, `overlays/overlay_map.dtb` + every `dtoverlay`, `cmdline.txt`, `armstub8.bin` (missing: built-in stub used), `kernel8.img` |

bootcode.bin has its own USB, LAN9514/LAN7515, DHCP and TFTP stack; it prints its banner twice
(re-initialises after the first `config.txt` read) and reads `config.txt` again unmeasured.
start.elf reads `config.txt` a third time. start.elf adds its own kernel arguments and builds the final
device tree in memory.

## bootcode.bin

Raw VideoCore IV image, no header or version string, loaded at `0x80000000`, entry `0x80000200`,
`gp = 0x8000C000`, core-0 stack top `0x8000D708` (the zero gap at `0x80009F59-0x8000BFFF` is .bss,
not free space). `BOOT_UART=0` at file offset `0x9D9A` is the documented serial-log switch.

| Address | What |
|---|---|
| `0x800014FC` | `read_file(ctx, name, dest, max)` |
| `0x80001650` | prints `Read File: %s, %d (bytes)`, then `0x80001720(buf, len)` at `0x80001662` (**hook**) |
| `0x80001720` | streaming hash update (no-op unless signed boot is enabled) |
| `0x800016D0` | signed-boot setup: reads the flag at `0x7E20F000` (bit 0), `2ndsig.bin`, OTP key |
| `0x8000166E` | signature verify (returns 0 when signed boot is off) |
| `~0x80008400` | SHA-1 (HMAC-SHA1 signed boot, disabled on retail boards) |
| `0x80006378` | loads start.elf → `0xC0100000`, fixup.dat → `0xC0080000`, applies fixups, ELF load, verify, hand-off |
| `0x800090D6` / `0x80006AE4` / `0x80006B66` | `printf` / `memcpy` / `memset` |

## fixup.dat

A relocation list that bootcode.bin applies to the start.elf **file buffer** before loading the ELF.
Positions start at buffer − 2; byte `b ≥ 2` advances `b − 1` halfwords; `b ∈ {0,1}` reads a 24-bit
little-endian advance then subtracts/adds the pass delta to the halfword there; each of two passes ends
exactly at the file end. Pass 0 (7076 entries) moves start.elf from link `0x0EC02800` to runtime
`0x3EC02800` on this 1 GB board. No entry touches the bytes the payload patches.

## start.elf

ELF, ThreadX RTOS, runtime = link + `0x30000000` here.

| Link address | What |
|---|---|
| `0x0ED7A0E4` | `load_file()`; `0x0ED7A164..73` after `fread` (`r6` buffer, `r7` length, `r10` name, `r12` FILE) is the **load hook** |
| `0x0ED79E8E` | after "Device tree loaded to" (`r7` DT address, `r10` size), before the ARM is released: **DT hook** |
| `0x0EDEA6E6` / `0x0EDEA8FE` / `0x0EDEA4AC` | SHA-256 init / update / final |
| `0x0EE25492` / `0x0EE2549A` | log category / `log(cat, level, fmt, …)` (`MESS:` lines) |
| `0x0ECE14A0` | `fclose` |
| `0x0EC7A810` | DT fixups: writes `/chosen/rng-seed`, `kaslr-seed` |

## Assembler gotchas (binutils-vc4)

- `.word` is 16-bit; use `.long` for 32-bit data. A misaligned 32-bit load hangs the VPU.
- `ldb r1,(r0-1)` silently assembles as a **pc-relative** load; step the pointer instead.
- No linker in the build: the payload is one section starting at the hook address rounded down to 4,
  so branches and `lea` resolve at assembly time and `.balign` matches real addresses.
