#!/usr/bin/env bash
# Package a release: only our own files (payload, overlays, scripts). No Broadcom firmware.
#   firmware/release.sh v0.1.0   -> dist/rpi3-tpm-measured-boot-v0.1.0.tar.gz (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."
ver=${1:?usage: release.sh <version>}
name=rpi3-tpm-measured-boot-$ver
firmware/build.sh >/dev/null

rm -rf "dist/$name" && mkdir -p "dist/$name/overlays"
cp firmware/tpm-measure.blob firmware/apply.py firmware/make-bootcode.py "dist/$name/"
cp firmware/overlays/*.dtbo firmware/overlays/*.dts "dist/$name/overlays/"
cp tools/verify/final-dt-digest.py "dist/$name/"
cp firmware/INSTALL.md "dist/$name/README.md"
(cd "dist/$name" && sha256sum tpm-measure.blob apply.py make-bootcode.py final-dt-digest.py overlays/* > SHA256SUMS)
if grep -rlaq "Raspberry Pi Bootcode" "dist/$name"; then echo "refusing: Broadcom firmware found in release"; exit 1; fi
tar -C dist -czf "dist/$name.tar.gz" "$name"
(cd dist && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
ls -l "dist/$name.tar.gz"; cat "dist/$name.tar.gz.sha256"
