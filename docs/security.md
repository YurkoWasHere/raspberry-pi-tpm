# Security notes

Measured boot records what booted; it does not stop anything from booting. What the PCRs prove depends
on what a verifier checks.

## What is and isn't measured

| Covered | Not covered |
|---|---|
| `config.txt` (first read), `start.elf`, `fixup.dat` | `bootcode.bin` itself: it is the root of trust for measurement (the ROM cannot measure it) |
| base DTB, kernel, initramfs, armstub, `kernel=` file | overlay files and `cmdline.txt` as files (their effect is in the final DT) |
| final device tree (overlays, dtparams, cmdline, memory, serial) | `config.txt` settings that never reach the DT (clocks, voltages, `gpu_mem`, `enable_jtag_gpio`, …) when read from an `include`, a conditional section or a later read |
| | the root filesystem (use IMA from Linux on) |

## Ways the measurement can be skipped (fail-open)

- A different `start.elf` (`start_x`, `start_debug`, `start_file=`, a firmware update): the stage-2
  hooks are not installed, PCR 4/5 get no events.
- `device_tree=` (no DT): no final-DT event.
- TPM not answering: `NOT measured` on serial, boot continues.

**Verifier policy:** require the exact event sequence (`config.txt`, `start.elf`, `fixup.dat`, DTB,
kernel, `final-device-tree`), not only matching PCR values. A missing event is the signature of a
bypass.

## config.txt subtleties

Only the first `config.txt` read is measured; bootcode.bin and start.elf read it again. A hostile TFTP
server can serve different content later. `include` files and conditional sections (`[gpioN=…]`,
`[EDID=…]`, `[pi3+]`) make PCR 1 an incomplete description of the applied settings. Anything that
changes the DT is still caught through PCR 5.

## Never set

- `program_usb_boot_mode`, `program_usb_boot_timeout`, `program_gpio_bootmode`, any `program_*` /
  `otp_*` option: they burn OTP permanently on a Pi 3.
- TPM: `tpm2_clear`, `TPM2_PCR_Allocate` (bank changes), hierarchy/lockout changes. None are used here.

## TPM reset line (GPIO 4)

The TPM board wires RST# to GPIO 4. The firmware uses it to reset the TPM each boot, but anything that
can pulse it can reset the TPM at runtime and replay "good" measurements (true regardless of this
project: it is board wiring).

| Who | Today | Blocked by |
|---|---|---|
| user in the `gpio` group (incl. `pi`), no sudo | `/dev/gpiomem`, `/dev/gpiochip*` | `tpm-rst-guard` overlay: no `/dev/gpiomem`, GPIO 4 hogged (`EBUSY`) ✓ tested |
| root, kernel GPIO API | `gpioset` | hog: `EBUSY` ✓ tested |
| root, `/dev/mem` or a kernel module | **works** (tested) | a hardened kernel only: `STRICT_DEVMEM`, `IO_STRICT_DEVMEM`, lockdown, signed modules (stock Pi kernel has none) |
| physical access | short pin 7 to ground | hardware measures |

Detection (planned): record the TPM `resetCount` in the event log at boot; every quote carries a signed
`clockInfo.resetCount` and TPM uptime, so a runtime reset is visible to a remote verifier.

## Other

- Serial logging (`BOOT_UART`, `uart_2ndstage`) is on in the default build; turn it off with
  `make-bootcode.py --no-uart` and by removing `uart_2ndstage=1`.
- The patch is pinned to one firmware build: `apply.py` refuses any other `bootcode.bin`, and the
  stage-2 hooks check the exact start.elf bytes.
- Tested with network boot only. SD-card boot may read files through a different routine than the
  hooked one.
