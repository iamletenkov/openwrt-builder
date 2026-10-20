#!/bin/sh
# Тест-харнесс wrt.cloudinit — гоняется на билд-хосте (POSIX sh + awk).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LIB="$ROOT/lib"
FIX="$HERE/fixtures"
fail=0

pass(){ printf 'ok   - %s\n' "$1"; }
die(){ printf 'FAIL - %s\n' "$1"; fail=1; }
assert_eq(){ # desc expected actual
	if [ "$2" = "$3" ]; then pass "$1"; else
		die "$1"
		printf '       expected: [%s]\n       actual:   [%s]\n' "$2" "$3"
	fi
}

# --- source lib ---
# shellcheck disable=SC1090
for f in "$LIB"/*.sh; do . "$f"; done

# --- lint ---
for f in "$LIB"/*.sh; do
	shellcheck -s dash "$f" || die "shellcheck $f"
done
# `-o check-unassigned-uppercase` включает SC2154 («referenced but not
# assigned»). Без него линтер молчит о неопределённых переменных в верхнем
# регистре совсем: SC2154 — не обычная проверка, а опциональная, и выключена
# она по умолчанию, а не исключениями из списка `-e`. Именно так в файл
# приехало обращение к `$RPCD_SECTION_PREFIX`, которого никто не присваивал:
# секция UCI собиралась из пустоты, а прогон был зелёным.
# Почему не `--enable=all`: он даёт 1621 строку замечаний о стиле, то есть
# сторож утонул бы в шуме. Этот флаг находит ровно тот класс и ничего больше.
shellcheck -s dash -o check-unassigned-uppercase -e SC1090,SC1091,SC2034 \
	"$ROOT/wrt.cloudinit" || die "shellcheck wrt.cloudinit"
sh -n "$ROOT/wrt.cloudinit" || die "sh -n wrt.cloudinit"

# --- parse_netcfg ---
assert_eq "parse_netcfg wan-dhcp-lan-static" \
"eth0|dhcp|||
eth1|static|192.168.51.1|255.255.255.0|" \
"$(parse_netcfg "$FIX/wan-dhcp-lan-static/network-config")"

assert_eq "parse_netcfg wan-static-lan-static" \
"eth0|static|192.168.31.137|255.255.255.0|192.168.31.1
eth1|static|192.168.51.1|255.255.255.0|" \
"$(parse_netcfg "$FIX/wan-static-lan-static/network-config")"

assert_eq "parse_netcfg multi-lan" \
"eth0|dhcp|||
eth1|static|192.168.51.1|255.255.255.0|
eth2|static|192.168.52.1|255.255.255.0|" \
"$(parse_netcfg "$FIX/multi-lan/network-config")"

# --- формат bisquite: стандартный cloud-init ------------------------------
# Фикстура снята с настоящего `CloudInitGenerator`, а не написана руками:
# иначе тест проверял бы представление автора о формате, а не сам формат.
BSW="$FIX/bisquite-device-write"

assert_eq "netcfg_version: bisquite → 2" "2" "$(netcfg_version "$BSW/network-config")"
assert_eq "netcfg_version: proxmox → 1" "1" \
"$(netcfg_version "$FIX/wan-static-lan-static/network-config")"

assert_eq "parse_netcfg_any v2 (bisquite)" \
"eth0|dhcp|||
eth1|static|192.168.51.1|255.255.255.0|192.168.51.254" \
"$(parse_netcfg_any "$BSW/network-config")"

# Контроль: v1 через тот же вход разбирается по-прежнему — значит поддержка
# Proxmox не потеряна.
assert_eq "parse_netcfg_any v1 (proxmox, контроль)" \
"eth0|static|192.168.31.137|255.255.255.0|192.168.31.1
eth1|static|192.168.51.1|255.255.255.0|" \
"$(parse_netcfg_any "$FIX/wan-static-lan-static/network-config")"

assert_eq "parse_users: имя и готовый хеш" "ops" \
"$(parse_users "$BSW/user-data" | cut -d'|' -f1)"

case "$(parse_users "$BSW/user-data" | cut -d'|' -f2)" in
	\$6\$*) pass "parse_users: хеш в формате sha512-crypt" ;;
	*)      die  "parse_users: хеш не распознан" ;;
esac

# Контроль: у сида Proxmox списка users нет — парсер обязан молчать, а не
# выдумывать пользователя.
assert_eq "parse_users: proxmox → пусто" "" \
"$(parse_users "$FIX/wan-static-lan-static/meta-data")"

assert_eq "parse_ssh_keys: оба ключа" \
"ssh-ed25519 AAAAC3Nz probe@host
ssh-rsa AAAAB3Nza second@host" \
"$(parse_ssh_keys "$BSW/user-data" ops)"

assert_eq "parse_ssh_keys: чужой пользователь → пусто" "" \
"$(parse_ssh_keys "$BSW/user-data" nobody)"

# --- parse_root_password ---
# Парсер без единой проверки до 2026-09-11, при том что именно его отсутствие
# однажды дало устройство с ПУСТЫМ паролем root (см. wrt.cloudinit:136-138).
# Хеш берётся из `chpasswd: list:`, а не из списка `users:`, и делится только
# первое двоеточие: sha512-crypt сам полон `$`.
case "$(parse_root_password "$BSW/user-data")" in
	\$6\$*\$*) pass "parse_root_password: хеш root из chpasswd" ;;
	*)         die  "parse_root_password: хеш root не распознан" ;;
esac

# Контроль: в сиде Proxmox блока `chpasswd:` нет — парсер обязан вернуть
# пусто, а не подставить что-нибудь. Пустой вывод здесь значит «пароль root
# не задан», и apply_root_password на нём не трогает /etc/shadow.
assert_eq "parse_root_password: без chpasswd → пусто" "" \
"$(parse_root_password "$FIX/wan-static-lan-static/meta-data")"

# --- read_dns_v2 / read_dns_any ---
# `read_dns` разбирает v1 (Proxmox), `read_dns_v2` — v2 (бисквит), а
# `read_dns_any` выбирает по версии файла. Проверяются все три конца: обе
# реализации напрямую и диспетчер, иначе правка диспетчера прошла бы молча.
assert_eq "read_dns_v2 bisquite (первый адрес, search нет)" "8.8.8.8|" \
"$(read_dns_v2 "$BSW/network-config")"

assert_eq "read_dns_any v2 → идёт в read_dns_v2" "8.8.8.8|" \
"$(read_dns_any "$BSW/network-config")"

assert_eq "read_dns_any v1 → идёт в read_dns" "1.1.1.1|lan" \
"$(read_dns_any "$FIX/wan-dhcp-lan-static/network-config")"

# --- parse_runcmd ---
# Вторая фикстура, а не дописанный блок в первой. Решение: фикстура
# bisquite-device-write/ НЕ пересъёмывается — на ней восемь действующих
# проверок, и пересъёмка ради одного блока `runcmd:` рискует изменить
# network-config и уронить зелёные тесты. Блока `runcmd:` там нет, потому что
# у манифеста не было `firstboot-commands`: генератор ключ не пишет вовсе,
# если команд нет.
#
# Снята тем же способом, что и первая, — настоящим `CloudInitGenerator`
# (src/bisquite/infrastructure/device/cloud_init.py), вызванным из .venv
# трёхстрочным скриптом на манифесте с `firstboot-commands`. Не
# `bs device write --dry-run`: тот сид на диск не оставляет, то есть снимать
# было бы нечего. Манифест повторяет первый, поэтому network-config у двух
# фикстур совпадает байт в байт, а разница — ровно блок `runcmd:`.
#
# Вес проверки: отсутствие этого парсера один раз уже дало устройство
# с невыполненными командами первой загрузки (lib/parse.sh:235-237).
BSWR="$FIX/bisquite-device-write-runcmd"

assert_eq "parse_runcmd: обе команды, порядок сохранён" \
"uci set system.@system[0].notes='provisioned by bisquite'
/etc/init.d/uhttpd restart" \
"$(parse_runcmd "$BSWR/user-data")"

# Контроль: у сида без `firstboot-commands` ключа `runcmd:` нет — парсер
# обязан молчать. Пустой вывод здесь несущий: на нём stage_runcmd не создаёт
# /usr/libexec/bisquite-firstboot.sh, то есть пустой скрипт не подменяет
# тот, что мог положить адаптер Proxmox.
assert_eq "parse_runcmd: без runcmd → пусто" "" \
"$(parse_runcmd "$BSW/user-data")"

# Контроль версии: тот же парсер не должен путать `runcmd:` с соседними
# списками — у фикстуры с runcmd есть ещё `users:`, `chpasswd:` и `growpart:`.
assert_eq "parse_root_password: работает и на второй фикстуре" "0" \
"$(parse_root_password "$BSWR/user-data" | grep -cv '^\$6\$')"

# --- merge_authorized_keys ---
# Ключи записываются, а не дописываются: при повторном провижне (новый
# instance-id) `>>` удваивал строки. Прогон именно повторный — один вызов
# удвоения и не показал бы.
AKT=$(mktemp -d)
AKF="$AKT/authorized_keys"
AKK="ssh-ed25519 AAAAC3Nz probe@host
ssh-rsa AAAAB3Nza second@host"
printf 'ssh-rsa AAAAwhatever baked@image\n' > "$AKF"
merge_authorized_keys "$AKF" "$AKK" || die "merge_authorized_keys: первый вызов"
merge_authorized_keys "$AKF" "$AKK" || die "merge_authorized_keys: второй вызов"
merge_authorized_keys "$AKF" "$AKK" || die "merge_authorized_keys: третий вызов"
assert_eq "merge_authorized_keys: три прогона не удваивают ключи" "2" \
"$(grep -c 'probe@host\|second@host' "$AKF")"
# Чужая строка на месте: /etc/dropbear/authorized_keys общий на всех
# пользователей сида, и в образе там может лежать ключ от сборки. Затирание
# обменяло бы удвоение на потерю ключей.
assert_eq "merge_authorized_keys: чужая строка сохранена" "1" \
"$(grep -c 'baked@image' "$AKF")"
# Второй пользователь дописывается, а не вытесняет первого.
merge_authorized_keys "$AKF" "ssh-ed25519 AAAAC3Nz third@host" || \
	die "merge_authorized_keys: второй пользователь"
assert_eq "merge_authorized_keys: ключи второго пользователя рядом, не вместо" "3" \
"$(grep -c 'probe@host\|second@host\|third@host' "$AKF")"
# Пустой список ключей файла не трогает.
merge_authorized_keys "$AKF" "" || die "merge_authorized_keys: пустые ключи"
assert_eq "merge_authorized_keys: пустой список ничего не меняет" "4" \
"$(wc -l < "$AKF" | tr -d ' ')"
rm -rf "$AKT"

# --- read_dns ---
assert_eq "read_dns wan-dhcp-lan-static" "1.1.1.1|lan" \
"$(read_dns "$FIX/wan-dhcp-lan-static/network-config")"
assert_eq "read_dns wan-static-lan-static" "8.8.8.8|" \
"$(read_dns "$FIX/wan-static-lan-static/network-config")"
assert_eq "read_dns multi-lan (none)" "|" \
"$(read_dns "$FIX/multi-lan/network-config")"

# --- get_seed_instance_id ---
assert_eq "instance-id wan-dhcp-lan-static" "bisquite-a1b2c3d4" \
"$(get_seed_instance_id "$FIX/wan-dhcp-lan-static/meta-data")"
assert_eq "instance-id multi-lan" "bisquite-cafe1234" \
"$(get_seed_instance_id "$FIX/multi-lan/meta-data")"

# --- validate_netcfg ---
if validate_netcfg "$FIX/multi-lan/network-config"; then pass "validate ok"; else die "validate ok"; fi
emptyf="$(mktemp)"; printf 'version: 1\nconfig: []\n' > "$emptyf"
if validate_netcfg "$emptyf"; then die "validate empty → fail"; else pass "validate empty → fail"; fi
rm -f "$emptyf"

# --- state.sh ---
TMP=$(mktemp -d)
WRT_STATE_DIR="$TMP/state"
if already_provisioned "x1"; then die "state: empty → not provisioned"; else pass "state: empty → not provisioned"; fi
if mark_provisioned "x1"; then pass "state: mark ok"; else die "state: mark ok"; fi
if already_provisioned "x1"; then pass "state: same id → provisioned"; else die "state: same id → provisioned"; fi
if already_provisioned "x2"; then die "state: diff id → not provisioned"; else pass "state: diff id → not provisioned"; fi
if already_provisioned ""; then die "state: empty id arg → not provisioned"; else pass "state: empty id arg → not provisioned"; fi
rm -rf "$TMP"
unset WRT_STATE_DIR

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
