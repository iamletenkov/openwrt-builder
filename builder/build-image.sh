#!/usr/bin/env bash
set -euo pipefail

# ----‑ Переменные, которые можно переопределить из compose ----
OPENWRT_RELEASE=${OPENWRT_RELEASE:-24.10.1}
TARGET=${TARGET:-x86}
SUBTARGET=${SUBTARGET:-64}
PROFILE=${PROFILE:-generic}
ROOTFS_SIZE=${ROOTFS_SIZE:-512}
JOBS=${JOBS:-$(nproc)}

IB_DIR="openwrt-imagebuilder-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}.Linux-x86_64"

CONFIG_DIR=${CONFIG_DIR:-/work/config}
PACKAGES_FILE=${PACKAGES_FILE:-${CONFIG_DIR}/packages.txt}
FEEDS_FILE=${FEEDS_FILE:-${CONFIG_DIR}/feeds.txt}

if [[ ! -f "$PACKAGES_FILE" ]]; then
  echo "→ packages file not found: $PACKAGES_FILE" >&2
  exit 1
fi

if [[ ! -f "$FEEDS_FILE" ]]; then
  echo "→ feeds file not found: $FEEDS_FILE" >&2
  exit 1
fi

# ---------- 1. Скачиваем ImageBuilder ----------
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

# ---------- 2. Подменяем репозитории на зеркало  ----------
# По-умолчанию берём пакеты с официального CDN OpenWrt.
# При необходимости можно переопределить переменной окружения
#   MIRROR=http://<ваше-зеркало>/openwrt
MIRROR=${MIRROR:-http://downloads.openwrt.org}
 
 # заменяем все вхождения downloads.openwrt.org →
 #   ${MIRROR}
 sed -i "s#https://downloads.openwrt.org#${MIRROR}#g" \
        "$IB_DIR/repositories.conf"

# ---------- 3. Подмешиваем пользовательские фиды ----------
mapfile -t CUSTOM_FEEDS < <(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$FEEDS_FILE" || true)
if (( ${#CUSTOM_FEEDS[@]} )); then
  echo "→ Adding custom feeds from $FEEDS_FILE"
  for feed in "${CUSTOM_FEEDS[@]}"; do
    if grep -Fxq "$feed" "$IB_DIR/repositories.conf"; then
      echo "   • already present: $feed"
    else
      echo "$feed" >> "$IB_DIR/repositories.conf"
      echo "   • added: $feed"
    fi
  done
else
  echo "→ No custom feeds to add."
fi

# ---------- 4. Готовим список пакетов ----------
mapfile -t PKG_ARRAY < <(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$PACKAGES_FILE" | sort -u)
PKG_ARRAY=("${PKG_ARRAY[@]/ip-tiny}")

PKGS="${PKG_ARRAY[*]}"
echo "→ Packages: $PKGS"

# ---------- 5. Сборка образов ----------
pushd "$IB_DIR" >/dev/null
  make -j"$JOBS" image V=s \
       PROFILE="$PROFILE" \
       PACKAGES="$PKGS" \
       ROOTFS_PARTSIZE="$ROOTFS_SIZE" \
       EXTRA_IMAGE_NAME="custom" \
       BIN_DIR=/work/output 
popd >/dev/null

# ---------- 6. Конвертируем образы в qcow2 ----------
shopt -s nullglob
img_gz_list=(/work/output/*.img.gz)
img_raw_list=(/work/output/*.img)
shopt -u nullglob

if (( ${#img_gz_list[@]} + ${#img_raw_list[@]} > 0 )); then
  echo "→ Converting raw images to qcow2…"

  for img_gz in "${img_gz_list[@]}"; do
    raw="${img_gz%.gz}"
    qcow2="${raw%.img}.qcow2"
    echo "   • $(basename "$img_gz") → $(basename "$qcow2")"
    if [[ ! -f "$raw" ]]; then
      set +e
      gzip -dk "$img_gz"
      status=$?
      set -e
      if (( status != 0 && status != 2 )); then
        echo "   ! gzip failed for $(basename "$img_gz") (exit $status)" >&2
        exit $status
      fi
    fi
    qemu-img convert -f raw -O qcow2 "$raw" "$qcow2"
    rm -f "$raw"
  done

  # Вдобавок обрабатываем возможные неархивированные .img, которые выдал ImageBuilder
  for img_raw in "${img_raw_list[@]}"; do
    # если файл уже удалён (например, после обработки .img.gz) — пропускаем
    [[ -f "$img_raw" ]] || continue
    qcow2="${img_raw%.img}.qcow2"
    echo "   • $(basename "$img_raw") → $(basename "$qcow2")"
    qemu-img convert -f raw -O qcow2 "$img_raw" "$qcow2"
  done
else
  echo "→ Skipping qcow2 conversion: no .img artifacts found."
fi

echo -e "
✔ Build finished. Check ./output for images."
