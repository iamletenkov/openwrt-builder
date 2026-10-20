# trixie: e2fsprogs >= 1.47.1 умеет mke2fs -d <tar> (пересборка ext4 корня без root)
FROM debian:13-slim

# Зависимости ImageBuilder OpenWrt 25.12 (apk-инструменты лежат внутри него;
# distutils для его prereq-проверки даёт python3-setuptools), qemu-img для
# qcow2, e2fsprogs (+libarchive для -d <tar>) и sfdisk для пересборки ext4 корня.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget make gawk patch python3 python3-setuptools perl \
    file rsync unzip xz-utils zstd gzip bzip2 qemu-utils e2fsprogs libarchive13t64 fdisk && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY build-image.sh check-manifest.sh /work/
RUN chmod +x /work/build-image.sh /work/check-manifest.sh
