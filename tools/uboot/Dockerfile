# U-Boot for the Pi 3B+ (64-bit) with TPM 2.0 measured boot through UEFI (EFI_TCG2_PROTOCOL).
#   docker build -t uboot-rpi3-tpm tools/uboot
#   docker build --output type=local,dest=tools/uboot/out tools/uboot
FROM debian:bookworm AS build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git ca-certificates build-essential gcc-aarch64-linux-gnu bison flex bc libssl-dev \
      device-tree-compiler python3 python3-dev python3-setuptools python3-pyelftools swig \
      libgnutls28-dev uuid-dev \
 && rm -rf /var/lib/apt/lists/*
ARG UBOOT_TAG=v2026.10
RUN git clone --depth 1 --branch ${UBOOT_TAG} https://source.denx.de/u-boot/u-boot.git /src
WORKDIR /src
COPY patches/ /patches/
COPY rpi3-tpm-softspi.dtsi arch/arm/dts/
COPY rpi3-tpm.config /rpi3-tpm.config
ENV CROSS_COMPILE=aarch64-linux-gnu-
RUN for p in /patches/*.patch; do patch -p1 < "$p"; done \
 && make rpi_3_defconfig \
 && scripts/kconfig/merge_config.sh -m .config /rpi3-tpm.config \
 && make olddefconfig \
 && for opt in OF_SEPARATE SOFT_SPI TPM_V2 TPM2_TIS_SPI EFI_TCG2_PROTOCOL EFI_TCG2_PROTOCOL_MEASURE_DTB \
               ENV_IS_NOWHERE CMD_UNZIP USE_BOOTCOMMAND; do \
      grep -q "^CONFIG_${opt}=y" .config || { echo "config option ${opt} did not stick"; exit 1; }; done \
 && ! grep -qE '^CONFIG_(OF_BOARD|TPM_PCR_ALLOCATE|ENV_IS_IN_FAT)=y' .config \
 && grep -q '^CONFIG_BOOTDELAY=-2' .config \
 && make -j"$(nproc)"

FROM scratch
COPY --from=build /src/u-boot.bin /src/u-boot.dtb /src/.config /
