# Raspberry Pi 3 measured boot: install

This archive contains only project code: the assembled payload, the patcher and two device-tree
overlays. It contains no Broadcom firmware; `make-bootcode.py` downloads the stock file from
Raspberry Pi's archive and patches it on your machine. Keep the patched file for your own use.

| File | |
|---|---|
| `tpm-measure.blob` | measuring payload (VideoCore IV code), applied to the stock `bootcode.bin` |
| `make-bootcode.py`, `apply.py` | fetch stock firmware, verify sha256, patch (Python 3 stdlib only) |
| `overlays/tpm-eventlog.dtbo` | reserves the event-log memory and points the kernel's TPM driver at it |
| `overlays/tpm-rst-guard.dtbo` | claims the TPM reset pin (GPIO 4) and disables `/dev/gpiomem` |
| `final-dt-digest.py` | recomputes the final-device-tree measurement from `/sys/firmware/fdt` |
| `SHA256SUMS` | checksums of the above |

## Requirements

- Raspberry Pi 3 Model B+ with an Infineon SLB9670 TPM on SPI0 CE1, RST# on GPIO 4.
- Firmware `raspi-firmware` 1:1.20260915-1: `bootcode.bin` sha256 `4245ec23…`, `start.elf` `32f99080…`,
  `fixup.dat` `7853f2b5…` (Raspberry Pi OS Lite 2026-10-06). Use exactly these `start.elf` and
  `fixup.dat` next to the patched `bootcode.bin`.
- Tested with network boot. SD-card boot is untested.

## Steps

```bash
sha256sum -c SHA256SUMS
./make-bootcode.py                 # or: ./make-bootcode.py --stock /boot/firmware/bootcode.bin
```

Copy to the boot partition (or TFTP root): `bootcode.bin`, `overlays/tpm-eventlog.dtbo`,
`overlays/tpm-rst-guard.dtbo`. In `config.txt`:

```ini
dtparam=spi=on
dtoverlay=tpm-slb9670
dtoverlay=tpm-eventlog
dtoverlay=tpm-rst-guard
enable_uart=1
uart_2ndstage=1
```

Without a serial console, use `./make-bootcode.py --no-uart` and drop the last two lines.

Note: on Raspberry Pi OS, an update of the `raspi-firmware` package overwrites `bootcode.bin`
(and changes `start.elf`). Hold the package (`sudo apt-mark hold raspi-firmware`) or re-run this.

## Check

Serial console (115200): `TPM: reset via GPIO4`, `TPM: Startup rc=00000000`, then one line per measured
file. On the Pi:

```bash
sudo tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements
tpm2_pcrread sha256:0,1,4,5          # equals the "pcrs:" section of the event log
sudo python3 final-dt-digest.py      # equals the final-device-tree event digest
```

Expected events: `config.txt` (PCR 1), `start.elf` and `fixup.dat` (PCR 0), the base `.dtb` (PCR 5),
`kernel8.img` (PCR 4), `final-device-tree` (PCR 5). A missing event means a stage was skipped.

Uninstall: put back the stock `bootcode.bin` and remove the two `dtoverlay` lines.
