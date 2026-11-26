#!/usr/bin/env bash
# Install packages on the netbooted Pi, which has no internet: apt runs here against the Pi's own
# rootfs (its sources, dpkg status, arm64) to download, then the Pi installs from its local cache.
#   ./pi-apt.sh tpm2-tools [more packages...]
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
SRV=$(realpath ../srv)
PI=${PI:-pi@10.42.0.124}
APT=(apt-get -q -o Dir=/r -o Dir::State::status=/r/var/lib/dpkg/status
     -o APT::Architecture=arm64 -o APT::Architectures=arm64 -o APT::Sandbox::User=root)
docker run --rm -v "$SRV/rootfs":/r -v "$SRV/rootfs/usr/share/keyrings":/usr/share/keyrings:ro \
  debian:trixie bash -euc "${APT[*]} update -qq && ${APT[*]} install -y --download-only $*"
ssh -o BatchMode=yes -o UserKnownHostsFile=./known_hosts "$PI" \
  "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download $*" 2>&1 | grep -av -e 'SSH may not work' -e rptl.io
