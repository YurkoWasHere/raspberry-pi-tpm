# Test rig: reproducing the measured-boot Pi from scratch

Everything below runs on the host without sudo (Docker does the privileged parts). Measured boot
only: nothing here writes OTP, enables secure/signed boot, or changes TPM PCR banks or hierarchies.

## 1. Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 3 Model B+ | network boot enabled (default on the 3B+); no SD card |
| Infineon SLB9670 TPM 2.0 board on the GPIO header | SPI0 CE1 (GPIO 7/9/10/11); **RST# on GPIO 4** (board pull-up), found with `tests/probe-tpm-reset-gpio.sh` |
| USB-serial adapter (PL2303) | Pi pin 6 GND, pin 8 (GPIO14 TX) → adapter RX, pin 10 (GPIO15 RX) → adapter TX; 115200 8N1; shows up as `/dev/ttyUSB0` |
| Dedicated host NIC, cabled straight to the Pi | never the LAN interface |
| Hub with per-port power switching (MEGA4, VIA VL817 `2109:2817`) | Pi power from port 3, so the host can cold-boot it |

## 2. Host prerequisites

Docker (with compose), `nmcli`, Python 3, `xz`, `ssh`. Images built here: `netboot-netboot` (compose),
`vc4-binutils` (`tools/vc4`), `pi-uhubctl` (`tools/uhubctl`).

```bash
docker build -t vc4-binutils tools/vc4          # VideoCore IV assembler/disassembler (~5 min)
docker build -t pi-uhubctl tools/uhubctl         # hub power control
```

## 3. OS image and netboot tree

```bash
mkdir -p images && cd images
curl -LO https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-10-06/2026-10-06-raspios-trixie-arm64-lite.img.xz
echo "483db18a48da399b5b7022ffae9a07bc6d99daab30e593aedac09b69ff422843  2026-10-06-raspios-trixie-arm64-lite.img.xz" | sha256sum -c
xz -dk 2026-10-06-raspios-trixie-arm64-lite.img.xz && cd ..

netboot/prepare.sh images/2026-10-06-raspios-trixie-arm64-lite.img   # -> srv/tftp, srv/rootfs
netboot/configure-rootfs.sh                                          # NFS root, pi user + SSH key, TPM overlays
```

Copy `netboot/.env.example` to `netboot/.env` and edit it: `IFACE` (the Pi-facing NIC), `PI_HUB`/`PI_HUB_PORT` (from `uhubctl` output).
Then:

```bash
nmcli dev set <IFACE> managed no
cd netboot && docker compose up -d && cd ..      # refuses to start on an interface with a default route
```

Serial console capture (optional but used throughout):
`stty -F /dev/ttyUSB0 115200 raw -echo -ixon && cat /dev/ttyUSB0 > netboot/serial.log`

## 4. Stock firmware: where every file comes from

The image's boot files are the stock Debian packages; untouched copies live in the rootfs, so stock
can always be restored from there (`netboot/boot-mode.sh stock` does exactly that).

| File served from `srv/tftp` | Stock copy in `srv/rootfs` | Package (in the image) | sha256 |
|---|---|---|---|
| `bootcode.bin` | `/usr/lib/raspi-firmware/bootcode.bin` | `raspi-firmware` 1:1.20260915-1 | `4245ec23b58158dc3e55f3e065eb4ecc0c0705d76c8db506e9f824941feee32e` |
| `start.elf` | `/usr/lib/raspi-firmware/start.elf` | `raspi-firmware` | `32f990801e7765bae6fe5cb940ba5eeff02dd0dac8dc5474db5b3fd345281790` |
| `fixup.dat` | `/usr/lib/raspi-firmware/fixup.dat` | `raspi-firmware` | `7853f2b51e4489f8b3ce6f9c52fd0afdda38c7383961524e0883d34afcb4827b` |
| `bcm2710-rpi-3-b-plus.dtb` | `/usr/lib/linux-image-6.18.50+rpt-rpi-v8/broadcom/` | `linux-image-6.18.50+rpt-rpi-v8` 1:6.18.50-1+rpt1 | `d41256bdc25b09dbba0bcdb27592560561d39752ebb09c64e82a449e3271807d` |
| `overlays/tpm-slb9670.dtbo` | `/usr/lib/linux-image-6.18.50+rpt-rpi-v8/overlays/` | same kernel package | `69606575e5e586d690719744c682b57c2b57bb8c89dc606190f88954d47b1483` |
| `kernel8.img` (gzip Image) | `/boot/vmlinuz-6.18.50+rpt-rpi-v8` | same kernel package | `c9f5af153236ec42eb012700e39ff43d02bc7c5f2ab71abad6da1f20880343e0` |
| TPM kernel modules | `/lib/modules/6.18.50+rpt-rpi-v8/kernel/drivers/char/tpm/` (`tpm_tis_spi.ko.xz` …) | same kernel package | — |

Upstream for the firmware is the `raspberrypi/firmware` repository (`boot/`), shipped to Debian as
`raspi-firmware` from `archive.raspberrypi.com`. The patch is pinned to the hashes above: `firmware/apply.py`
refuses any other `bootcode.bin`, and the start.elf hooks are only installed if the patched bytes
match (otherwise stage 2 is skipped and boot continues unmeasured past fixup.dat).

## 5. Build and install the measured-boot firmware

```bash
firmware/build.sh                 # payload + overlays; patches the stock bootcode.bin from
                                  # srv/rootfs/usr/lib/raspi-firmware/ (sha256-checked)
netboot/boot-mode.sh measured     # installs bootcode.bin + both overlays, enables them in config.txt
netboot/pi-power.sh cycle         # cold boot
```

Switch back at any time: `netboot/boot-mode.sh stock && netboot/pi-power.sh cycle`.

## 6. Check it

On serial: `TPM: reset via GPIO4`, `Startup rc=00000000`, one `->` line per file
(config.txt PCR1; start.elf, fixup.dat PCR0; the DTB and final-device-tree PCR5; kernel8.img PCR4).

On the Pi (`ssh -o UserKnownHostsFile=netboot/known_hosts pi@10.42.0.124`):

```bash
sudo tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements   # replayed PCRs at the end
tpm2_pcrread sha256:0,1,4,5                                             # must equal the replay
sudo python3 final-dt-digest.py                                         # tools/verify/, equals the final-device-tree event
```

Reference values for this firmware, image and config, with both overlays (cold or warm boot):

| PCR | sha256 |
|---|---|
| 0 | `abe3171f05d4c7888c15072dbe5de2d77b0cf1adddb8d3973c4b006681803660` |
| 1 | `5cd05d90e42afa1723e950fe1ee054f9c4ddf7533dfe3a573f5cbcd7680a0af0` |
| 4 | `4153bac859a09916258bb16beb237cd5d99d53c4085e1595fb232e499808630b` |
| 5 | `4aeb584c81eff2425bb2937b5ede5a5fd79d3d08b12ae6d85a868c8ff82ff006` |

PCR 1 and 5 depend on `config.txt`, `cmdline.txt` and overlays, so any edit to those changes them.

## 7. Tests

```bash
tests/tamper-matrix.py                      # all cases, ~30 min of cold boots
tests/tamper-matrix.py baseline-a warm-reboot
```

Results land in `tests/results/<run>/` (JSON per case plus `summary.md`, not committed); see [testing.md](testing.md).
