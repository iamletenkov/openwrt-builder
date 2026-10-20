FROM debian:12-slim

# Зависимости ImageBuilder OpenWrt 25.12 (apk-инструменты лежат внутри него)
# и qemu-img для qcow2.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl make gawk python3 perl file rsync unzip \
    xz-utils zstd gzip bzip2 qemu-utils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY build-image.sh /work/build-image.sh
RUN chmod +x /work/build-image.sh
