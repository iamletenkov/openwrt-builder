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
FILES_DIR=${FILES_DIR:-/work/files}
GROWPART_URL=${GROWPART_URL:-https://raw.githubusercontent.com/canonical/cloud-utils/main/bin/growpart}

if [[ ! -f "$PACKAGES_FILE" ]]; then
  echo "→ packages file not found: $PACKAGES_FILE" >&2
  exit 1
fi

if [[ ! -f "$FEEDS_FILE" ]]; then
  echo "→ feeds file not found: $FEEDS_FILE" >&2
  exit 1
fi

mkdir -p "$FILES_DIR/usr/sbin"
echo "→ Installing growpart helper into overlay…"
wget -q -O "$FILES_DIR/usr/sbin/growpart" "$GROWPART_URL"
chmod +x "$FILES_DIR/usr/sbin/growpart"

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
feeds_added=0
mapfile -t CUSTOM_FEEDS < <(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$FEEDS_FILE" || true)
if (( ${#CUSTOM_FEEDS[@]} )); then
  echo "→ Adding custom feeds from $FEEDS_FILE"
  for feed in "${CUSTOM_FEEDS[@]}"; do
    feed_trimmed="$feed"
    feed_trimmed="${feed_trimmed#"${feed_trimmed%%[![:space:]]*}"}"
    feed_trimmed="${feed_trimmed%"${feed_trimmed##*[![:space:]]}"}"
    [[ -z "$feed_trimmed" ]] && continue

    feed_type=${feed_trimmed%%[[:space:]]*}
    case "$feed_type" in
      src-git|src_git)
        echo "   ! skipping unsupported git feed (provide binary feed URL instead): $feed_trimmed"
        continue
        ;;
      src|src/gz|src-gz)
        feeds_added=1
        if grep -Fxq "$feed_trimmed" "$IB_DIR/repositories.conf"; then
          echo "   • already present: $feed_trimmed"
        else
          echo "$feed_trimmed" >> "$IB_DIR/repositories.conf"
          echo "   • added: $feed_trimmed"
        fi
        ;;
      *)
        echo "   ! ignoring unknown feed directive '$feed_type': $feed_trimmed"
        ;;
    esac
  done
else
  echo "→ No custom feeds to add."
fi

# ---------- 3a. Локальные .ipk (AmneziaWG, podkop и т.п.) ----------
# Пакеты, которых нет в фидах (или kmod-* собранные под конкретное ядро), кладём в
# локальный фид ImageBuilder'а: качаем .ipk по ссылкам из local-ipk.txt, строим
# индекс (Packages.gz) и подключаем как "src/gz file://…" ПЕРВОЙ строкой
# repositories.conf (приоритет над сетевыми фидами). Подпись снимается в 3b.
LOCAL_IPK_FILE=${LOCAL_IPK_FILE:-${CONFIG_DIR}/local-ipk.txt}
LOCAL_IPK_URLS=()
if [[ -f "$LOCAL_IPK_FILE" ]]; then
  mapfile -t LOCAL_IPK_URLS < <(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$LOCAL_IPK_FILE" || true)
fi
if (( ${#LOCAL_IPK_URLS[@]} )); then
  IB_ABS="$(cd "$IB_DIR" && pwd)"
  IPKG_INDEX="$IB_ABS/scripts/ipkg-make-index.sh"
  if [[ ! -x "$IPKG_INDEX" ]]; then
    echo "→ ipkg-make-index.sh не найден в ImageBuilder ($IPKG_INDEX)" >&2
    exit 1
  fi
  LOCAL_PKG_DIR="$IB_ABS/localpkgs"
  mkdir -p "$LOCAL_PKG_DIR"
  echo "→ Fetching local .ipk from $LOCAL_IPK_FILE"
  for url in "${LOCAL_IPK_URLS[@]}"; do
    url="${url#"${url%%[![:space:]]*}"}"; url="${url%"${url##*[![:space:]]}"}"
    [[ -z "$url" ]] && continue
    echo "   • $url"
    wget -q -P "$LOCAL_PKG_DIR" "$url" || { echo "   ! download failed: $url" >&2; exit 1; }
  done
  echo "→ Building local package index (Packages.gz)"
  ( cd "$LOCAL_PKG_DIR" && "$IPKG_INDEX" . > Packages )
  gzip -kf "$LOCAL_PKG_DIR/Packages"
  local_feed="src/gz localpkgs file://$LOCAL_PKG_DIR"
  grep -Fxq "$local_feed" "$IB_DIR/repositories.conf" \
    || sed -i "1i $local_feed" "$IB_DIR/repositories.conf"
  feeds_added=1
  echo "   • local feed: $local_feed ($(ls "$LOCAL_PKG_DIR"/*.ipk | wc -l) .ipk)"
fi

# ---------- 3b. Подпись репозиториев для сторонних фидов ----------
# Сторонние фиды (openwrt.ai и т.п.) подписаны своим usign-ключом, которого нет
# в keys/ ImageBuilder'а → opkg отверг бы их по подписи. Импорт чужого ключа в
# офлайн-сборку хрупок (ротация ключей, наличие usign в контейнере), поэтому при
# наличии кастомных фидов отключаем проверку подписи репозиториев НА ВРЕМЯ СБОРКИ.
# ImageBuilder и фиды тянутся по HTTPS, сборка идёт в контролируемом окружении.
# Чтобы доверять только конкретному ключу — положи его usign-pub в "$IB_DIR/keys/"
# (имя файла = fingerprint) и убери этот блок.
if (( feeds_added )); then
  echo "→ Custom feeds present → disabling opkg signature check for this build"
  sed -i 's/^\([[:space:]]*\)option check_signature/\1# option check_signature/' \
         "$IB_DIR/repositories.conf"
  # Подстраховка: если строки option check_signature в конфиге нет вовсе —
  # явно выключим проверку, чтобы opkg не отверг неподписанный сторонний фид.
  if ! grep -qE '^[[:space:]]*#?[[:space:]]*option check_signature' "$IB_DIR/repositories.conf"; then
    echo "option check_signature 0" >> "$IB_DIR/repositories.conf"
  fi
fi

echo "──────── repositories.conf (итоговый) ────────"
cat "$IB_DIR/repositories.conf"
echo "──────────────────────────────────────────────"

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
       FILES="$FILES_DIR" \
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
