#!/usr/bin/env bash
set -euo pipefail

# ----‑ Переменные, которые можно переопределить из compose ----
OPENWRT_RELEASE=${OPENWRT_RELEASE:-24.10.1}
TARGET=${TARGET:-x86}
SUBTARGET=${SUBTARGET:-64}
PROFILE=${PROFILE:-generic}
ROOTFS_SIZE=${ROOTFS_SIZE:-512}
JOBS=${JOBS:-$(nproc)}

SDK_DIR="openwrt-sdk-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}_gcc-13.3.0_musl.Linux-x86_64"
IB_DIR="openwrt-imagebuilder-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}.Linux-x86_64"

# ---------- 1. Скачиваем SDK и собираем rc.cloud ----------
if [[ ! -d "$SDK_DIR" ]]; then
  echo "→ Fetching OpenWrt SDK…"
  for i in {1..3}; do
    curl -Lf \
      "https://archive.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/${SDK_DIR}.tar.zst" \
      -o /tmp/sdk.tar.zst && break || {
        echo "SDK download failed ($i). Retrying in 30 s…"
        sleep 30
      }
  done
  tar -I unzstd -xf /tmp/sdk.tar.zst
fi

pushd "$SDK_DIR" >/dev/null

# ──- Заменяем канонические фиды на зеркала GitHub ─────────────────────────
sed -i -e 's#https://git.openwrt.org/openwrt/openwrt.git#https://github.com/openwrt/openwrt.git#' \
       -e 's#https://git.openwrt.org/feed/packages.git#https://github.com/openwrt/packages.git#' \
       -e 's#https://git.openwrt.org/project/luci.git#https://github.com/openwrt/luci.git#' \
       -e 's#https://git.openwrt.org/feed/routing.git#https://github.com/openwrt/routing.git#' \
       -e 's#https://git.openwrt.org/feed/telephony.git#https://github.com/openwrt/telephony.git#' \
       feeds.conf.default

  # подключаем внешний фид с rc.cloud
  if ! grep -q iamletenkov/openwrt-packages feeds.conf.default; then
    echo "src-git cloud https://github.com/iamletenkov/openwrt-packages.git" >> feeds.conf.default
  fi


  ./scripts/feeds update -a
  ./scripts/feeds install -a
  ./scripts/feeds install -p cloud rc.cloud


  make defconfig
  make -j"$JOBS" package/rc.cloud/compile
  IPK=$(find bin/packages -name 'rc.cloud_*_*.ipk' | head -n1)
  echo "→ built $IPK"
  cp "$IPK" /work/
popd >/dev/null

# ---------- 2. Скачиваем ImageBuilder ----------
if [[ ! -d "$IB_DIR" ]]; then
  url="https://archive.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/${IB_DIR}.tar.zst"
  echo "→ Fetching ImageBuilder… [${url}]"
  for i in {1..3}; do
    curl -Lf \
      $url \
      -o /tmp/ib.tar.zst && break || {
        echo "ImageBuilder download failed ($i). Retrying in 30 s…"
        sleep 30
      }
  done
  tar -I unzstd -xf /tmp/ib.tar.zst
fi

# ---------- 3. Кладём ipk в каталог пакетов IB ----------
mkdir -p "$IB_DIR/packages/custom"
cp rc.cloud_*_*.ipk "$IB_DIR/packages/custom/"

# ---------- 4. Правим репозитории (HTTPS→HTTP, IPv4‑only) ----------
# sed -i 's#https://downloads.openwrt.org#http://downloads.openwrt.org#g' "$IB_DIR/repositories.conf"

# ---------- 4. Подменяем репозитории на зеркало  ----------
MIRROR=${MIRROR:-http://mirror.cyberbits.eu/openwrt}

# заменяем все вхождения downloads.openwrt.org →
#   http://mirror.cyberbits.eu/openwrt
sed -i "s#https://downloads.openwrt.org#${MIRROR}#g" \
       "$IB_DIR/repositories.conf"

# ---------- 5. Готовим список пакетов ----------
mapfile -t PKG_ARRAY < <(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' /work/packages.txt | sort -u)
PKG_ARRAY=("${PKG_ARRAY[@]/ip-tiny}")

PKGS="rc.cloud ${PKG_ARRAY[*]}"
echo "→ Packages: $PKGS"

# ---------- 6. Сборка образов ----------
pushd "$IB_DIR" >/dev/null
  make -j"$JOBS" image V=s \
       PROFILE="$PROFILE" \
       PACKAGES="$PKGS" \
       ROOTFS_PARTSIZE="$ROOTFS_SIZE" \
       EXTRA_IMAGE_NAME="custom" \
       BOOTOPTS="ds=nocloud" \
       BIN_DIR=/work/output 
popd >/dev/null

echo -e "
✔ Build finished. Check ./output for images."