#!/bin/sh
# Проверка: каждый запрошенный пакет есть в манифесте образа ImageBuilder.
# Использование: check-manifest.sh <файл .manifest> <пакет>...
# Строка манифеста: "<имя> - <версия>". Аргументы "-pkg" (убрать пакет)
# пропускаются. Код 1 и список недостающих — если чего-то нет.
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <manifest> <pkg>..." >&2; exit 2; }
manifest=$1
shift
[ -f "$manifest" ] || { echo "→ нет манифеста: $manifest" >&2; exit 2; }

missing=""
for pkg in "$@"; do
	case "$pkg" in
		-*|'') continue ;;
	esac
	if ! awk -v p="$pkg" '$1 == p && $2 == "-" { found = 1 } END { exit !found }' "$manifest"; then
		missing="$missing $pkg"
	fi
done

if [ -n "$missing" ]; then
	echo "→ в образе нет запрошенных пакетов:$missing" >&2
	exit 1
fi
echo "   • манифест: все запрошенные пакеты на месте ($(basename "$manifest"))"
