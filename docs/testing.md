# Testing

Harness: [`tests/tamper-matrix.py`](../tests/tamper-matrix.py). Each case changes one boot input on the
netboot server, cold-boots the Pi via the hub, and records live PCRs, the event-log replay, the event
list, the final-DT verifier digest and the serial log, then restores the input and checks its hash.
Raw results go to `tests/results/<run>/` (JSON per case, `summary.md`; not committed).

## Tamper matrix (2026-11-25)

Every case compared event-by-event with a cold-boot baseline from the same run.

| Case | Change | Expected | Observed (changed events) | Replay = live |
|---|---|---|---|---|
| baseline ×2 | none | none | none: identical | ✓ |
| config-comment | comment line added to config.txt | PCR 1 | `config.txt` (PCR 1) only; final DT unchanged | ✓ |
| config-dtparam | `dtparam=audio=off` | PCR 1, 5 | `config.txt` (PCR 1) and `final-device-tree` (PCR 5) | ✓ |
| cmdline-arg | ` quiet` on the kernel command line | PCR 5 | `final-device-tree` only (via `/chosen/bootargs`) | ✓ |
| kernel-recompress | same kernel re-gzipped (`gzip -1`) | PCR 4 | `kernel8.img` (PCR 4) only | ✓ |
| dtb-trailing | bytes after the base DTB's `totalsize` | PCR 5 | DTB **file** event only; final DT digest unchanged | ✓ |
| overlay-content | overlay gains a property; config.txt unchanged | PCR 5 | `final-device-tree` only | ✓ |
| startelf-string | one character of a start.elf log string | PCR 0 | `start.elf` (PCR 0) only; hooks still installed | ✓ |
| unloaded-file | extra file nobody loads | none | none | ✓ |
| rootfs-change | `/etc/motd` edited | none | none (rootfs is not measured; IMA would cover it) | ✓ |
| warm-reboot (before GPIO reset) | `reboot`, no power cycle | — | PCRs accumulated, replay ≠ live | ✗ (known) |
| warm-reboot (with GPIO4 reset) | `reboot`, no power cycle | none | none after normalising `rsts` | ✓ |

Notes:
- **kernel-append was replaced.** Appending zeros to `kernel8.img` changed PCR 4 correctly, but the
  file is gzip and start.elf then failed (`kernel GZIP decompression failed`) after measuring it.
  We measure the compressed file; recompressing tests the same thing and still boots.
- **dtb-trailing** shows why both the DTB file and the final DT are measured: trailing junk in the
  file is visible in the file event but does not reach the kernel.
- **Stock vs measured** (`netboot/boot-mode.sh`): stock boots with no TPM output, all PCRs zero and no
  event log; switching back gives the reference PCRs again.

## Warm reboots and the TPM reset

The TPM's PCRs only clear on a hardware TPM reset, which a SoC reboot does not cause.
`tests/probe-tpm-reset-gpio.sh` found **RST# on GPIO 4**: pulsing it zeroed PCRs 0/1/4/5 and a
test-extended PCR 16. The firmware now pulses GPIO 4 (2 ms low, 100 ms settle) before the TPM is first
used, so every boot gets `Startup rc=0` and starts from zero.

The final DT then still differed between cold and warm boots in one property,
`/chosen/bootloader/rsts` (reset status: `0x1000` power-on, `0x1020` watchdog reboot). It is NOP'd
before hashing, like the seeds. After that a warm reboot reproduces the cold-boot PCRs exactly.

**Security consequence:** anything that can drive GPIO 4 can reset the TPM at runtime and replay
"good" measurements. That was true before the patch (it is board wiring). The `tpm-rst-guard`
overlay now blocks the `gpio` group (no `/dev/gpiomem`) and the kernel GPIO API (GPIO 4 hogged, busy
even for root); root via `/dev/mem` still succeeds, as tested. See
[security.md](security.md#tpm-reset-line-gpio-4).

## Still to test

- `start_x=1` / `start_file=` / a firmware update: hooks not installed, so PCR 4/5 get no events.
- `device_tree=` (no DT): no final-DT event.
- `include` files, conditional sections (`[gpioN=…]`), and a different config.txt served to later
  reads (TOCTOU): settings that do not reach the DT are not measured.
- initramfs (`auto_initramfs=1`), `armstub=`, `kernel=u-boot.bin`.
- Attestation round-trip: AK, `tpm2_quote`, verify signature and event-log replay off-box, and detect a
  runtime TPM reset through `clockInfo.resetCount`.
- DT > 64 KB and event log > 2 KB (fail-open limits); TPM absent (fail-open).
- SD-card boot: bootcode.bin may read files through a different routine than the hooked one.
