#!/bin/sh
# pass/die не падают, поэтому «A && pass || die» здесь — честный if/else.
# shellcheck disable=SC2015
# Тесты сторонних пакетов: пины в config/local-packages*.txt, их покрытие по
# таргетам и проверка манифеста образа (builder/check-manifest.sh).
# Гоняется на билд-хосте (POSIX sh + awk), сеть не нужна.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
CONF="$REPO/config"
CHECK="$REPO/builder/check-manifest.sh"
FIX="$HERE/fixtures"
fail=0

pass(){ printf 'ok   - %s\n' "$1"; }
die(){ printf 'FAIL - %s\n' "$1"; fail=1; }

# Релиз, под который собраны пины kmod: тот же, что по умолчанию в Makefile.
REL=$(awk -F'[ ?=]+' '$1 == "export" && $2 == "OPENWRT_RELEASE" { print $3 }' "$REPO/Makefile")
[ -n "$REL" ] && pass "релиз по умолчанию: $REL" || die "не найден OPENWRT_RELEASE в Makefile"

pins(){ # строки пинов файла без комментариев и пустых
	sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

# --- формат пинов -----------------------------------------------------------
for f in "$CONF"/local-packages.txt "$CONF"/local-packages-*.txt; do
	n=$(basename "$f")
	bad=$(pins "$f" | awk '
		NF != 2 { print "полей " NF ": " $0; next }
		$1 !~ /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/releases\/download\/[A-Za-z0-9_.+-]+\/[A-Za-z0-9_.+-]+\.apk$/ {
			print "URL не на фиксированный релиз GitHub: " $1; next }
		$1 ~ /\/releases\/download\/latest\// { print "latest вместо версии: " $1; next }
		$2 !~ /^[0-9a-f]{64}$/ { print "sha256 не 64 hex: " $1 }')
	[ -z "$bad" ] && pass "$n: URL фиксированного релиза + sha256" || { die "$n: формат пинов"; echo "$bad"; }
	[ -n "$(pins "$f")" ] && pass "$n: не пуст" || die "$n: пуст"
done

# --- общие (noarch) пакеты --------------------------------------------------
for p in podkop luci-app-podkop luci-theme-argon; do
	if pins "$CONF/local-packages.txt" | awk -v p="$p" '
		{ n = $1; sub(/.*\//, "", n) } n ~ ("^" p "-[0-9]") { f = 1 } END { exit !f }'; then
		pass "local-packages.txt: пин $p"
	else die "local-packages.txt: нет пина $p"; fi
done

# --- AmneziaWG по таргетам: архитектура и релиз совпадают ------------------
# <target>-<subtarget>:<arch пакетов OpenWrt>
for ta in x86-64:x86_64 armsr-armv8:aarch64_generic \
          bcm27xx-bcm2711:aarch64_cortex-a72 bcm27xx-bcm2712:aarch64_cortex-a76; do
	ts=${ta%%:*}; arch=${ta#*:}
	f="$CONF/local-packages-$ts.txt"
	[ -f "$f" ] || { die "$ts: нет $(basename "$f")"; continue; }
	for p in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
		if pins "$f" | awk -v pre="${p}_v${REL}_${arch}_" '
			{ n = $1; sub(/.*\//, "", n) } index(n, pre) == 1 { f = 1 } END { exit !f }'; then
			pass "$ts: $p под $REL / $arch"
		else die "$ts: нет пина $p под $REL / $arch"; fi
	done
	# пакеты чужой архитектуры в списке таргета — ошибка копипасты
	other=$(pins "$f" | awk -v a="_${arch}_" '{ n = $1; sub(/.*\//, "", n) } index(n, a) == 0 { print n }')
	[ -z "$other" ] && pass "$ts: чужих архитектур нет" || die "$ts: чужая архитектура: $other"
done

# один файл не пинится дважды (общий + таргет)
dups=$(for f in "$CONF"/local-packages*.txt; do pins "$f"; done | awk '{ sub(/.*\//, "", $1); print $1 }' | sort | uniq -d)
[ -z "$dups" ] && pass "пины без дублей" || die "дубли пинов: $dups"

# --- packages.txt ставит все сторонние пакеты --------------------------------
for p in kmod-amneziawg amneziawg-tools luci-proto-amneziawg podkop luci-app-podkop luci-theme-argon; do
	if pins "$CONF/packages.txt" | grep -qx "$p"; then pass "packages.txt: $p"
	else die "packages.txt: нет $p"; fi
done

# --- check-manifest.sh --------------------------------------------------------
M="$FIX/image.manifest"
if sh "$CHECK" "$M" kmod-amneziawg luci-theme-argon -wpad-basic-mbedtls >/dev/null; then
	pass "check-manifest: всё на месте → 0 (а -pkg пропущен)"
else die "check-manifest: всё на месте → 0"; fi

err=$(sh "$CHECK" "$M" kmod-amneziawg nano 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && pass "check-manifest: нет пакета → 1" || die "check-manifest: нет пакета → 1 (rc=$rc)"
case "$err" in *nano*) pass "check-manifest: называет недостающий" ;; *) die "check-manifest: не назвал nano: $err" ;; esac

# luci-app-podkop в манифесте не засчитывает podkop
sh "$CHECK" "$M" podkop >/dev/null 2>&1 && die "check-manifest: podkop засчитан по luci-app-podkop" \
	|| pass "check-manifest: имя сравнивается целиком"

sh "$CHECK" "$FIX/nonexistent.manifest" kmod-amneziawg >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "check-manifest: нет файла → 2" || die "check-manifest: нет файла → 2 (rc=$rc)"

# --- lint -------------------------------------------------------------------
shellcheck -s sh "$CHECK" && pass "shellcheck check-manifest.sh" || die "shellcheck check-manifest.sh"
shellcheck -s bash "$REPO/builder/build-image.sh" && pass "shellcheck build-image.sh" || die "shellcheck build-image.sh"
shellcheck -s sh "$0" && pass "shellcheck run-tests.sh" || die "shellcheck run-tests.sh"

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
