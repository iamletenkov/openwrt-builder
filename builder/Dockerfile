FROM debian:12-slim

# build‑time аргументы позволят кешировать скачивание SDK и ImageBuilder
ARG OPENWRT_RELEASE
ARG TARGET
ARG SUBTARGET

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git make gawk python3 build-essential \
    libncurses5-dev zlib1g-dev flex gettext libssl-dev \
    xz-utils zstd file rsync jq patch parted wget unzip python3-distutils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

# копируем скрипт
COPY build-image.sh /work/build-image.sh
RUN chmod +x /work/build-image.sh