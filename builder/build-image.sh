#!/usr/bin/env bash
set -euo pipefail

# ---- настраиваемые переменные ---------------------------------------------
OPENWRT_RELEASE=${OPENWRT_RELEASE:-24.10.1}
TARGET=${TARGET:-x86}
SUBTARGET=${SUBTARGET:-64}
PROFILE=${PROFILE:-generic}
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}        # MiB
JOBS=${JOBS:-$(nproc)}                  # параллельных потоков

SDK_DIR="openwrt-sdk-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}_gcc-13.3.0_musl.Linux-x86_64"
IB_DIR="openwrt-imagebuilder-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}.Linux-x86_64"

# ---- 1. скачиваем SDK и собираем rc.cloud ----------------------------------
if [[ ! -d "$SDK_DIR" ]]; then
  echo "→ Fetching OpenWrt SDK…"
  curl -Lf \
    "https://archive.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/${SDK_DIR}.tar.zst" \
    -o /tmp/sdk.tar.zst
  tar -I unzstd -xf /tmp/sdk.tar.zst
fi

pushd "$SDK_DIR" >/dev/null
  # внешние фиды
  if ! grep -q dtroyer/openwrt-packages feeds.conf.default; then
    echo "src-git cloud https://github.com/dtroyer/openwrt-packages.git" \
      >> feeds.conf.default
  fi
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  ./scripts/feeds install rc.cloud

  make defconfig
  make -j"$JOBS" package/rc.cloud/compile
  IPK=$(find bin/packages -name 'rc.cloud_*_*.ipk' | head -n1)
  echo "→ built $IPK"
  cp "$IPK" /work/
popd >/dev/null

# ---- 2. скачиваем ImageBuilder --------------------------------------------
if [[ ! -d "$IB_DIR" ]]; then
  echo "→ Fetching ImageBuilder…"
  curl -Lf \
    "https://archive.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/${IB_DIR}.tar.zst" \
    -o /tmp/ib.tar.zst
  tar -I unzstd -xf /tmp/ib.tar.zst
fi


# ---- 3. кладём ipk в IB ----------------------------------------------------
mkdir -p "$IB_DIR/packages/custom"
cp rc.cloud_*_*.ipk "$IB_DIR/packages/custom/"

# ---- 4. правим репозитории на HTTP (быстрее/IPv4-only) ---------------------
sed -i 's#https://downloads.openwrt.org#http://downloads.openwrt.org#g' \
       "$IB_DIR/repositories.conf"

# ---- 5. формируем список пакетов ------------------------------------------
PKGS=$(grep -Ev '^\s*(#|$)' /work/packages.txt | tr '\n' ' ')
PKGS="rc.cloud $PKGS"
echo "→ Packages: $PKGS"

# ---- 6. собираем образ -----------------------------------------------------
pushd "$IB_DIR" >/dev/null
  make -j"$JOBS" image \
       PROFILE="$PROFILE" \
       PACKAGES="$PKGS" \
       ROOTFS_PARTSIZE="$ROOTFS_SIZE" \
       EXTRA_IMAGE_NAME="custom" \
       BIN_DIR=/work/output
popd >/dev/null

echo -e "\n✔ Build finished. Check ./output for images."
