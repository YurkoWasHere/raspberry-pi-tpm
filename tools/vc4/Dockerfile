# VideoCore IV binutils (vc4-elf-objdump / vc4-elf-as) from the community port used by rpi-open-firmware.
#   docker build -t vc4-binutils tools/vc4
#   docker run --rm -v "$PWD/srv/tftp":/work:ro vc4-binutils \
#     vc4-elf-objdump -D -b binary -m vc4 --adjust-vma=0x80000000 bootcode.bin
# The port lives on the "vc4" branch and is an older binutils, so build with Debian 12 (GCC 12) and -fcommon for its pre-GCC-10 C code.
FROM debian:bookworm AS build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git ca-certificates build-essential bison flex texinfo libgmp-dev libmpfr-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch vc4 https://github.com/itszor/binutils-vc4.git /src
WORKDIR /build
RUN CFLAGS="-O2 -fcommon" CXXFLAGS="-O2 -fcommon" /src/configure --target=vc4-elf --prefix=/opt/vc4 --disable-werror --disable-nls --disable-gdb --disable-sim \
      --disable-gdbserver --disable-gprof --disable-ld --disable-gold --disable-libctf \
 && make -j"$(nproc)" MAKEINFO=true all-binutils all-gas \
 && make MAKEINFO=true install-binutils install-gas

FROM debian:bookworm-slim
COPY --from=build /opt/vc4 /opt/vc4
ENV PATH=/opt/vc4/bin:$PATH
WORKDIR /work
