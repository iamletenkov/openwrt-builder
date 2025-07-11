#!/usr/bin/env bash
set -euo pipefail

# ----‑ Переменные, которые можно переопределить из compose ----
OPENWRT_RELEASE=${OPENWRT_RELEASE:-24.10.1}
TARGET=${TARGET:-x86}
SUBTARGET=${SUBTARGET:-64}
PROFILE=${PROFILE:-generic}
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}   # MiB
JOBS=${JOBS:-$(nproc)}             # параллельных потоков

SDK_DIR="openwrt-sdk-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}_gcc-13.3.0_musl.Linux-x86_64"
IB_DIR="openwrt-imagebuilder-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}.Linux-x86_64"

# ---------- 1. Скачиваем SDK и собираем rc.cloud ----------
if [[ ! -d "$SDK_DIR" ]]; then
  echo "→ Fetching OpenWrt SDK… [${OPENWRT_RELEASE}]"

  echo "URL: https://archive.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/${SDK_DIR}.tar.xz" -o /tmp/sdk.tar.xz
  curl -L "https://archive.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/${SDK_DIR}.tar.xz" -o /tmp/sdk.tar.xz
  tar -xf /tmp/sdk.tar.xz
fi

pushd "$SDK_DIR" >/dev/null
  # подключаем внешний фид с rc.cloud
  if ! grep -q dtroyer/openwrt-packages feeds.conf.default; then
    echo "src-git cloud https://github.com/dtroyer/openwrt-packages.git" >> feeds.conf.default
  fi
  ./scripts/feeds update -a
  # устанавливаем все пакеты, это создаст каталог package/feeds/* и устранит ошибки ln
  ./scripts/feeds install -a
  # rc.cloud уже попал в дерево, но на всякий случай гарантируем наличие
  ./scripts/feeds install rc.cloud

  # минимальная конфигурация
  make defconfig
  # собираем только пакет rc.cloud (секунды)
  make package/rc.cloud/compile -j$JOBS
  # запоминаем путь к .ipk
  IPK=$(find bin/packages -name 'rc.cloud_*_*.ipk' | head -n1)
  echo "→ built $IPK"
  cp "$IPK" /work/
popd >/dev/null

# ---------- 2. Скачиваем ImageBuilder ----------
if [[ ! -d "$IB_DIR" ]]; then
  echo "→ Fetching ImageBuilder…"
  curl -L "https://downloads.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/${IB_DIR}.tar.xz" -o /tmp/ib.tar.xz
  tar -xf /tmp/ib.tar.xz
fi

# ---------- 3. Копируем ipk в каталог пакетов IB ----------
mkdir -p "$IB_DIR/packages/custom"
cp rc.cloud_*_*.ipk "$IB_DIR/packages/custom/"

# ---------- 4. Правим репозитории (HTTPS→HTTP, IPv4‑only) ----------
# В rare случаях uclient-fetch/mbedtls внутри ImageBuilder ломается на TLS.
# Меняем протокол на HTTP и форсируем IPv4, это повышает надёжность opkg.
if grep -q 'https://downloads.openwrt.org' "$IB_DIR/repositories.conf"; then
  sed -i 's#https://downloads.openwrt.org#http://downloads.openwrt.org#g' "$IB_DIR/repositories.conf"
fi

# ---------- 5. Подготовка списка пакетов ----------
PKGS=$(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' /work/packages.txt | tr '\n' ' ')
PKGS="rc.cloud $PKGS"
echo "→ Packages: $PKGS"

# ---------- 5. Сборка образа ----------
pushd "$IB_DIR" >/dev/null
  make -j$JOBS image PROFILE="$PROFILE" \
            PACKAGES="$PKGS" \
            ROOTFS_PARTSIZE="$ROOTFS_SIZE" \
            EXTRA_IMAGE_NAME="custom" \
            BIN_DIR=/work/output
popd >/dev/null

echo "\n✔ Build finished. Check ./output for images."