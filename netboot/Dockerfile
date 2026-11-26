FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      dnsmasq nfs-kernel-server kmod iproute2 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
