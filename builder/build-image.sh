#!/usr/bin/env bash
# Сборка образа OpenWrt 25.12+ (apk) через ImageBuilder.
#
# Поддерживаются только релизы с apk (25.12 и новее): ImageBuilder 24.10 и
# старше (opkg, repositories.conf) отвергается сразу, а не ломается посреди
# сборки. Таргеты: x86/64, armsr/armv8, bcm27xx/bcm2711 (RPi 4),
# bcm27xx/bcm2712 (RPi 5).
set -euo pipefail

# ---- Параметры (env) ----
OPENWRT_RELEASE=${OPENWRT_RELEASE:-25.12.6}
TARGET=${TARGET:-x86}
SUBTARGET=${SUBTARGET:-64}
PROFILE=${PROFILE:-generic}
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
# По умолчанию не больше 4 потоков: сборщик часто живёт на общем хосте.
JOBS=${JOBS:-$(( $(nproc) < 4 ? $(nproc) : 4 ))}
# Базовый URL релизов. По умолчанию HTTPS; подписи apk проверяются всегда.
MIRROR=${MIRROR:-https://downloads.openwrt.org}
ARCHIVE_MIRROR=${ARCHIVE_MIRROR:-https://archive.openwrt.org}

WORK_DIR=${WORK_DIR:-/work}
CONFIG_DIR=${CONFIG_DIR:-${WORK_DIR}/config}
PACKAGES_FILE=${PACKAGES_FILE:-${CONFIG_DIR}/packages.txt}
FEEDS_FILE=${FEEDS_FILE:-${CONFIG_DIR}/feeds.txt}
LOCAL_PKG_FILE=${LOCAL_PKG_FILE:-${CONFIG_DIR}/local-packages.txt}
KEYS_DIR=${KEYS_DIR:-${CONFIG_DIR}/keys}
OVERLAY_DIR=${OVERLAY_DIR:-${WORK_DIR}/overlay}   # файлы образа из репозитория
FILES_DIR=${FILES_DIR:-${WORK_DIR}/files}         # пользовательский overlay (gitignored)
OUTPUT_ROOT=${OUTPUT_ROOT:-${WORK_DIR}/output}
CACHE_DIR=${CACHE_DIR:-${WORK_DIR}/cache}

case "$OPENWRT_RELEASE" in
  [0-9][0-9].[0-9]*) ;;
  *) echo "→ OPENWRT_RELEASE='$OPENWRT_RELEASE' не похож на номер релиза" >&2; exit 1 ;;
esac
major=${OPENWRT_RELEASE%%.*}
rest=${OPENWRT_RELEASE#*.}; minor=${rest%%[!0-9]*}
if (( 10#$major < 25 || (10#$major == 25 && 10#$minor < 12) )); then
  echo "→ поддерживается только OpenWrt 25.12+ (apk); образы 24.10 — в релизе v0.1.0" >&2
  exit 1
fi

TS="${TARGET}-${SUBTARGET}"
IB_NAME="openwrt-imagebuilder-${OPENWRT_RELEASE}-${TS}.Linux-x86_64"
IB_TAR="${IB_NAME}.tar.zst"
REL_PATH="releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}"
OUT_DIR="${OUTPUT_ROOT}/${OPENWRT_RELEASE}/${TS}"

for f in "$PACKAGES_FILE" "$FEEDS_FILE"; do
  [[ -f "$f" ]] || { echo "→ нет файла: $f" >&2; exit 1; }
done

# список без комментариев и пустых строк, с обрезкой пробелов
read_list() {
  [[ -f "$1" ]] || return 0
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

fetch() { # url dest
  curl -fsSL --retry 3 --retry-delay 10 --connect-timeout 30 -o "$2" "$1"
}

# ---------- 1. ImageBuilder: скачать и проверить sha256 ----------
mkdir -p "$CACHE_DIR"
if [[ ! -d "$CACHE_DIR/$IB_NAME" ]]; then
  sums="$CACHE_DIR/sha256sums-${OPENWRT_RELEASE}-${TS}"
  base=""
  for m in "$MIRROR" "$ARCHIVE_MIRROR"; do
    if fetch "${m%/}/$REL_PATH/sha256sums" "$sums"; then base="${m%/}"; break; fi
  done
  [[ -n "$base" ]] || { echo "→ релиз $OPENWRT_RELEASE для $TS не найден ни на одном зеркале" >&2; exit 1; }
  echo "→ ImageBuilder: $base/$REL_PATH/$IB_TAR"
  fetch "$base/$REL_PATH/$IB_TAR" "$CACHE_DIR/$IB_TAR"
  want=$(awk -v f="*$IB_TAR" '$2==f{print $1}' "$sums")
  [[ -n "$want" ]] || { echo "→ $IB_TAR нет в sha256sums" >&2; exit 1; }
  echo "$want  $CACHE_DIR/$IB_TAR" | sha256sum -c --quiet - || { echo "→ sha256 ImageBuilder не совпал" >&2; exit 1; }
  tar -C "$CACHE_DIR" -I zstd -xf "$CACHE_DIR/$IB_TAR"
  rm -f "$CACHE_DIR/$IB_TAR"
fi
IB_DIR="$CACHE_DIR/$IB_NAME"

if [[ ! -f "$IB_DIR/repositories" ]]; then
  echo "→ в ImageBuilder нет файла repositories (apk) — это не 25.12+?" >&2
  exit 1
fi

# ---------- 2. Репозитории: зеркало и пользовательские фиды ----------
# Эталон — копия, снятая при первой распаковке: повторный запуск не копит строки.
[[ -f "$IB_DIR/repositories.orig" ]] || cp "$IB_DIR/repositories" "$IB_DIR/repositories.orig"
cp "$IB_DIR/repositories.orig" "$IB_DIR/repositories"
if [[ "${MIRROR%/}" != "https://downloads.openwrt.org" ]]; then
  sed -i "s#https://downloads.openwrt.org#${MIRROR%/}#g" "$IB_DIR/repositories"
fi
while IFS= read -r feed; do
  case "$feed" in
    http://*/packages.adb|https://*/packages.adb|file://*/packages.adb)
      echo "$feed" >> "$IB_DIR/repositories"
      echo "   • фид: $feed" ;;
    *) echo "→ $(basename "$FEEDS_FILE"): нужен URL на packages.adb, а не '$feed'" >&2; exit 1 ;;
  esac
done < <(read_list "$FEEDS_FILE")

# Ключи сторонних фидов (*.pem, apk v3). Проверка подписей не отключается:
# фид без ключа в config/keys/ уронит сборку — так и задумано.
shopt -s nullglob
for k in "$KEYS_DIR"/*.pem; do
  cp "$k" "$IB_DIR/keys/"
  echo "   • ключ: $(basename "$k")"
done
shopt -u nullglob

# ---------- 3. Локальные .apk (по URL) ----------
# Кладутся в packages/ ImageBuilder'а: он сам строит индекс и подписывает его
# локальным ключом сборки (публичная часть попадает в образ, /etc/apk/keys).
# Строка: <url> [sha256].
while read -r url sum _; do
  name=$(basename "$url")
  [[ "$name" == *.apk ]] || { echo "→ local-packages: ожидается .apk: $url" >&2; exit 1; }
  echo "   • локальный пакет: $name"
  fetch "$url" "$IB_DIR/packages/$name"
  if [[ -n "${sum:-}" ]]; then
    echo "$sum  $IB_DIR/packages/$name" | sha256sum -c --quiet - || { echo "→ sha256 не совпал: $name" >&2; exit 1; }
  fi
done < <(read_list "$LOCAL_PKG_FILE")

echo "──────── repositories ────────"
cat "$IB_DIR/repositories"
echo "──────────────────────────────"

# ---------- 4. Список пакетов ----------
# Общий список + необязательный config/packages-<target>-<subtarget>.txt.
PKGS=$( { read_list "$PACKAGES_FILE"; read_list "${CONFIG_DIR}/packages-${TS}.txt"; } \
        | awk '!seen[$0]++' | tr '\n' ' ')
echo "→ Пакеты: $PKGS"

# ---------- 5. Overlay: файлы репозитория + пользовательские ----------
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
if [[ -d "$OVERLAY_DIR" ]]; then cp -a "$OVERLAY_DIR/." "$STAGE/"; fi
if [[ -d "$FILES_DIR" ]]; then cp -a "$FILES_DIR/." "$STAGE/"; fi
# Права на исполнение не зависят от umask/checkout хоста.
chmod 0755 "$STAGE"/etc/uci-defaults/* "$STAGE"/etc/init.d/* 2>/dev/null || true

# ---------- 6. Сборка ----------
mkdir -p "$OUT_DIR"
make -C "$IB_DIR" -j"$JOBS" image \
     PROFILE="$PROFILE" \
     PACKAGES="$PKGS" \
     ROOTFS_PARTSIZE="$ROOTFS_SIZE" \
     EXTRA_IMAGE_NAME="custom" \
     FILES="$STAGE" \
     BIN_DIR="$OUT_DIR"

# ---------- 7. qcow2 для ВМ (x86, armsr) ----------
prefix="openwrt-${OPENWRT_RELEASE}-custom-${TS}"
shopt -s nullglob
case "$TARGET" in
  x86|armsr)
    for img_gz in "$OUT_DIR"/*-combined*.img.gz; do
      raw="${img_gz%.gz}"
      echo "   • $(basename "$img_gz") → qcow2"
      # gzip выходит кодом 2 на «trailing garbage» (метаданные подписи) — это норма
      rc=0; gzip -dc "$img_gz" > "$raw" || rc=$?
      (( rc == 0 || rc == 2 )) || { echo "→ gzip: код $rc на $(basename "$img_gz")" >&2; exit "$rc"; }
      qemu-img convert -f raw -O qcow2 "$raw" "${raw%.img}.qcow2"
      rm -f "$raw"
    done ;;
esac
# Общие имена (sha256sums, profiles.json) уникализируем: в одном релизе GitHub
# лежат артефакты всех таргетов.
if [[ -f "$OUT_DIR/profiles.json" ]]; then mv "$OUT_DIR/profiles.json" "$OUT_DIR/${prefix}.profiles.json"; fi
rm -f "$OUT_DIR/sha256sums"
arts=()
for f in "$OUT_DIR"/*.img.gz "$OUT_DIR"/*.qcow2 "$OUT_DIR"/*.manifest "$OUT_DIR"/*.bin "$OUT_DIR"/*.tar.gz; do
  arts+=("$(basename "$f")")
done
shopt -u nullglob
if (( ${#arts[@]} )); then
  ( cd "$OUT_DIR" && sha256sum -- "${arts[@]}" > "${prefix}.sha256sums" )
fi

echo
echo "✔ Готово: $OUT_DIR"
ls -l "$OUT_DIR"
