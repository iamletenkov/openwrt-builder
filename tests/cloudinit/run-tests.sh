#!/bin/sh
# Тест-харнесс wrt.cloudinit — гоняется на билд-хосте (POSIX sh + awk).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../overlay" && pwd)
LIB="$ROOT/usr/lib/wrt-cloudinit/lib"
WRT="$ROOT/etc/init.d/wrt.cloudinit"
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
	"$WRT" || die "shellcheck wrt.cloudinit"
sh -n "$WRT" || die "sh -n wrt.cloudinit"
for f in "$ROOT"/etc/uci-defaults/*; do
	shellcheck -s dash -e SC2046,SC2086 "$f" || die "shellcheck $f"
done

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

# --- parse_toplevel_ssh_keys (Proxmox: --sshkeys) ---
PVE="$FIX/proxmox-flat-user"
assert_eq "parse_toplevel_ssh_keys: ключи верхнего уровня" \
"ssh-ed25519 AAAAC3NzaPVE one@pve
ssh-rsa AAAAB3NzaPVE two@pve" \
"$(parse_toplevel_ssh_keys "$PVE/user-data")"
assert_eq "parse_toplevel_ssh_keys: ключи из users: не берутся" "" \
"$(parse_toplevel_ssh_keys "$BSW/user-data")"

# --- provisioned_instance_id ---
TMP=$(mktemp -d)
WRT_STATE_DIR="$TMP/state"
assert_eq "provisioned_instance_id: пусто до провижна" "" "$(provisioned_instance_id)"
mark_provisioned "pve-1" >/dev/null
assert_eq "provisioned_instance_id: после провижна" "pve-1" "$(provisioned_instance_id)"
rm -rf "$TMP"
unset WRT_STATE_DIR

# --- next_id_from ---
IDF=$(mktemp)
printf 'root:x:0:0::/root:/bin/ash\nnobody:*:65534:65534:nobody:/var:/bin/false\n' > "$IDF"
assert_eq "next_id_from: nobody (65534) не сдвигает нумерацию" "1000" "$(next_id_from "$IDF" 1000)"
printf 'ops:x:1000:1000::/home/ops:/bin/ash\n' >> "$IDF"
assert_eq "next_id_from: следующий после 1000" "1001" "$(next_id_from "$IDF" 1000)"
rm -f "$IDF"

# --- seed.sh: доверенный источник сида ---
# Поддельный sysfs: корень на vda2; vda3 — cidata на загрузочном диске;
# vdb1 — второй диск; sda1 — USB-флешка; sr0 — привод гипервизора (IDE);
# sr1 — USB-привод; mmcblk0 — SD (для проверки «съёмности»).
FS=$(mktemp -d)
mkdev() { # <путь в devices> <maj:min> [partition-номер]
	mkdir -p "$FS/devices/$1"
	n=$(basename "$1")
	mkdir -p "$FS/class/block" "$FS/dev/block"
	ln -s "../../devices/$1" "$FS/class/block/$n"
	ln -s "../../devices/$1" "$FS/dev/block/$2"
	[ -n "${3:-}" ] && echo "$3" > "$FS/devices/$1/partition"
	return 0
}
mkdev pci0/virtio1/block/vda 254:0
mkdev pci0/virtio1/block/vda/vda2 254:2 2
mkdev pci0/virtio1/block/vda/vda3 254:3 3
mkdev pci0/virtio2/block/vdb 254:16
mkdev pci0/virtio2/block/vdb/vdb1 254:17 1
mkdev pci0/usb1/1-1/host6/target6/block/sda 8:0
mkdev pci0/usb1/1-1/host6/target6/block/sda/sda1 8:1 1
mkdev pci0/ata2/host1/target1/block/sr0 11:0
mkdev pci0/usb2/2-1/host7/target7/block/sr1 11:1
mkdev platform/mmc0/block/mmcblk0 179:0
mkdev platform/mmc0/block/mmcblk0/mmcblk0p3 179:3 3
echo 1 > "$FS/devices/pci0/ata2/host1/target1/block/sr0/removable"
echo 1 > "$FS/devices/pci0/usb1/1-1/host6/target6/block/sda/removable"
MI="$FS/mountinfo"
printf '%s\n' \
	'22 1 254:2 / / rw,noatime - ext4 /dev/root rw' \
	'23 22 0:5 / /proc rw - proc proc rw' > "$MI"
CPU="$FS/cpuinfo"; printf 'flags\t\t: fpu sse2 hypervisor\n' > "$CPU"
WRT_SYS=$FS WRT_MOUNTINFO=$MI WRT_CPUINFO=$CPU
assert_eq "seed: root_disk = vda" "vda" "$(root_disk)"
assert_eq "seed: cidata на загрузочном диске → bootdisk" "bootdisk" "$(classify_seed_dev /dev/vda3)"
assert_eq "seed: второй диск → untrusted" "untrusted" "$(classify_seed_dev /dev/vdb1)"
assert_eq "seed: второй диск целиком → untrusted" "untrusted" "$(classify_seed_dev vdb)"
assert_eq "seed: USB-флешка → untrusted" "untrusted" "$(classify_seed_dev /dev/sda1)"
assert_eq "seed: привод гипервизора → hypervisor" "hypervisor" "$(classify_seed_dev /dev/sr0)"
assert_eq "seed: USB-привод → untrusted" "untrusted" "$(classify_seed_dev /dev/sr1)"
assert_eq "seed: несуществующее устройство → untrusted" "untrusted" "$(classify_seed_dev /dev/nope0)"
if seed_dev_removable /dev/sr0; then die "seed: привод гипервизора не съёмный"; else pass "seed: привод гипервизора не съёмный"; fi
if seed_dev_removable /dev/vda3; then die "seed: virtio-диск не съёмный"; else pass "seed: virtio-диск не съёмный"; fi
if seed_dev_removable /dev/mmcblk0p3; then pass "seed: SD-карта съёмная"; else die "seed: SD-карта съёмная"; fi
# Железо (нет флага hypervisor и DMI гипервизора): CD-привод не доверенный.
printf 'flags\t\t: fpu sse2\n' > "$CPU"
assert_eq "seed: CD-привод на железе → untrusted" "untrusted" "$(classify_seed_dev /dev/sr0)"
mkdir -p "$FS/class/dmi/id"; echo QEMU > "$FS/class/dmi/id/sys_vendor"
assert_eq "seed: arm-ВМ без флага, DMI QEMU → hypervisor" "hypervisor" "$(classify_seed_dev /dev/sr0)"
# RPi: корень на SD — cidata на той же карте доверенная, флешка — нет.
printf '%s\n' '22 1 179:2 / / rw - ext4 /dev/root rw' > "$MI"
mkdev platform/mmc0/block/mmcblk0/mmcblk0p2 179:2 2
assert_eq "seed: RPi, cidata на SD-карте корня → bootdisk" "bootdisk" "$(classify_seed_dev /dev/mmcblk0p3)"
assert_eq "seed: RPi, cidata на флешке → untrusted" "untrusted" "$(classify_seed_dev /dev/sda1)"
# squashfs: /dev/root смонтирован на /rom
printf '%s\n' '15 1 254:2 / /rom ro - squashfs /dev/root ro' '16 1 0:20 / / rw - overlay overlayfs:/overlay rw' > "$MI"
assert_eq "seed: squashfs, root_disk по /rom = vda" "vda" "$(root_disk)"
unset WRT_SYS WRT_MOUNTINFO WRT_CPUINFO
rm -rf "$FS"

# --- luci.sh: LuCI с WAN закрыта, пока пароль root пуст ---
# Дыра: сид без единого пароля оставлял root с пустым паролем, а правило
# «LuCI с WAN» открытым — rpcd пускал в LuCI под root без пароля из WAN.
# uci подменяется функцией поверх файла «ключ=значение».
LT=$(mktemp -d)
UCI_DB="$LT/uci"; : > "$UCI_DB"
uci() {
	[ "$1" = -q ] && shift
	case "$1" in
		get) awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); f = 1 } END { exit !f }' "$UCI_DB" ;;
		set) grep -v "^${2%%=*}=" "$UCI_DB" > "$UCI_DB.t"; echo "$2" >> "$UCI_DB.t"; mv "$UCI_DB.t" "$UCI_DB" ;;
		commit) echo "$2" >> "$LT/commits" ;;
	esac
}
WRT_SHADOW="$LT/shadow"
printf 'root:::0:99999:7:::\n' > "$WRT_SHADOW"
if root_password_empty; then pass "root_password_empty: пустое поле → пуст"; else die "root_password_empty: пустое поле → пуст"; fi
printf 'daemon:*:0:0:99999:7:::\n' > "$WRT_SHADOW"
if root_password_empty; then pass "root_password_empty: строки root нет → пуст"; else die "root_password_empty: строки root нет → пуст"; fi
if luci_wan_sync; then die "luci_wan_sync: нет правила → ничего"; else pass "luci_wan_sync: нет правила → ничего"; fi
# Правило заводит apply_network_config без enabled, то есть включённым.
uci set firewall.wrt_luci_wan=rule
printf 'root:::0:99999:7:::\n' > "$WRT_SHADOW"
if luci_wan_sync; then pass "luci_wan_sync: пустой пароль → правило меняется"; else die "luci_wan_sync: пустой пароль → правило меняется"; fi
assert_eq "luci_wan_sync: пустой пароль → LuCI с WAN выключена" "0" "$(uci get firewall.wrt_luci_wan.enabled)"
assert_eq "luci_wan_sync: изменение закоммичено" "firewall" "$(cat "$LT/commits")"
if luci_wan_sync; then die "luci_wan_sync: повтор без изменений → 1"; else pass "luci_wan_sync: повтор без изменений → 1"; fi
printf 'root:$6$salt$hash:20000:0:99999:7:::\n' > "$WRT_SHADOW"
if root_password_empty; then die "root_password_empty: хеш → не пуст"; else pass "root_password_empty: хеш → не пуст"; fi
if luci_wan_sync; then pass "luci_wan_sync: пароль задан → правило меняется"; else die "luci_wan_sync: пароль задан → правило меняется"; fi
assert_eq "luci_wan_sync: пароль задан → LuCI с WAN включена" "1" "$(uci get firewall.wrt_luci_wan.enabled)"
# Само правило в init-скрипте — только именованное: безусловное fw_allow_wan
# для LuCI вернуло бы дыру мимо luci_wan_sync.
if grep -q 'fw_allow_wan Allow-LuCI' "$WRT" || ! grep -q 'uci set firewall.wrt_luci_wan=rule' "$WRT"; then
	die "wrt.cloudinit: LuCI с WAN — только через правило wrt_luci_wan"
else
	pass "wrt.cloudinit: LuCI с WAN — только через правило wrt_luci_wan"
fi

# --- wrt.cloudinit: хеш пользователя из `users:` доходит до root ---
# `parse_users | while` в ash — подоболочка: CI_ADMIN_HASH терялся, и при
# сиде без chpasswd root оставался с пустым паролем. Функции init-скрипта
# подгружаются в подоболочке; всё, что трогает систему, подменено.
UDD="$LT/seed"; mkdir -p "$UDD"
grep -v '^hostname:' "$BSW/user-data" | \
	awk '/^chpasswd:/ { skip = 1; next } skip && /^[^ ]/ { skip = 0 } !skip' > "$UDD/user-data"
got=$(
	# shellcheck disable=SC1090
	. "$WRT"
	CIDATA=$UDD
	logger() { :; }
	create_ci_admin() { [ -n "$CI_ADMIN_HASH" ] || CI_ADMIN_HASH=$2; }
	install_ssh_keys() { :; }
	install_key_lines() { :; }
	set_root_password() { :; }
	stage_runcmd() { :; }
	apply_user_data
	printf '%s' "$CI_ADMIN_HASH"
)
case "$got" in
	\$6\$*) pass "apply_user_data: хеш из users: виден ensure_root_not_open" ;;
	*)      die  "apply_user_data: хеш из users: потерян (подоболочка?)" ;;
esac
rm -rf "$LT"
unset WRT_SHADOW

# --- write_network_uci: чужие секции переживают провижн ----------------------
# Раньше провижн сида (первая загрузка или новый instance-id) стирал
# /etc/config/network, dhcp и firewall целиком: интерфейс awg0 расширения
# amneziawg, его пир, зона VPN и forwarding в неё пропадали. Теперь
# wrt.cloudinit удаляет только свои секции (lib/owned.sh) и пишет их заново.
# Фикстура uci-foreign — вывод настоящего `uci -X show` с корневой ФС
# релиза: стоковые секции (сеть x86 по board.d, firewall и dhcp пакетов) плюс
# чужие — awg0, awg0_peer, анонимный wireguard_wg0, зона awg, forwarding
# lan→awg, правило Allow-AWG-Port, include podkop и сервер dnsmasq.
# uci подменяется эмулятором поверх файлов «uci -X show» в $UCI_DIR.
UT=$(mktemp -d)
UCI_DIR="$UT/uci"
uci() {
	while :; do case "$1" in -q|-X) shift ;; *) break ;; esac; done
	_c=$1; shift
	case "$_c" in
	show) cat "$UCI_DIR/$1" 2>/dev/null ;;
	get)
		awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/\047/, "", v); print v; f = 1 } END { exit !f }' "$UCI_DIR/${1%%.*}" 2>/dev/null ;;
	set|add_list)
		_p=${1%%=*} _v=${1#*=} _f="$UCI_DIR/${1%%.*}"
		touch "$_f"
		case "${_p#*.}" in *.*) _v="'$_v'" ;; esac
		awk -v k="$_p" -v v="$_v" -v add="$([ "$_c" = add_list ] && echo 1)" '
			index($0, k "=") == 1 { if (add) print $0 " " v; else print k "=" v; f = 1; next }
			{ print }
			END { if (!f) print k "=" v }' "$_f" > "$_f.t" && mv "$_f.t" "$_f" ;;
	delete)
		_f="$UCI_DIR/${1%%.*}"
		[ -f "$_f" ] || return 1
		awk -v k="$1" 'index($0, k "=") != 1 && index($0, k ".") != 1' "$_f" > "$_f.t" && mv "$_f.t" "$_f" ;;
	commit) : ;;
	*) echo "uci-emu: нет команды $_c" >&2; return 1 ;;
	esac
}
# prov FIXTURE: провижн сида фикстуры поверх текущего $UCI_DIR (подоболочка:
# функции init-скрипта не протекают в харнесс).
prov() (
	# shellcheck disable=SC1090
	. "$WRT"
	CIDATA="$FIX/$1"
	logger() { :; }
	write_network_uci
)
# sec_of PKG TYPE OPT VAL: имена секций типа TYPE с OPT=VAL (по одной в строке).
sec_of() {
	awk -v p="$1" -v t="$2" -v o="$3" -v v="'$4'" -F= '
		{ split($1, k, ".") }
		k[1] == p && !k[3] && $2 == t { ty[k[2]] = 1 }
		k[1] == p && k[3] == o && $2 == v { hit[k[2]] = 1 }
		END { for (s in hit) if (s in ty) print s }' "$UCI_DIR/$1"
}
cnt() { sec_of "$@" | grep -c .; }
mkdir -p "$UCI_DIR"
cp "$FIX/uci-foreign/network" "$FIX/uci-foreign/firewall" "$FIX/uci-foreign/dhcp" "$UCI_DIR/"
WRT_SHADOW="$UT/shadow"
printf 'root:$6$salt$hash:20000:0:99999:7:::\n' > "$WRT_SHADOW"

if prov multi-lan; then pass "write_network_uci: провижн multi-lan"; else die "write_network_uci: провижн multi-lan"; fi
# чужое — на месте
assert_eq "network: чужой интерфейс awg0 сохранён" "amneziawg" "$(uci -q get network.awg0.proto)"
assert_eq "network: пир awg0_peer сохранён" "peerkey" "$(uci -q get network.awg0_peer.public_key)"
assert_eq "network: анонимный wireguard_wg0 сохранён" "1" "$(cnt network wireguard_wg0 description manual)"
assert_eq "network: globals сохранены" "fd12:3456:789a::/48" "$(uci -q get network.globals.ula_prefix)"
assert_eq "firewall: чужая зона awg сохранена" "1" "$(cnt firewall zone name awg)"
assert_eq "firewall: forwarding lan→awg сохранён" "1" "$(cnt firewall forwarding dest awg)"
assert_eq "firewall: чужое правило сохранено" "1" "$(cnt firewall rule name Allow-AWG-Port)"
assert_eq "firewall: include podkop сохранён" "/usr/lib/podkop/fw.sh" "$(uci -q get firewall.podkop.path)"
assert_eq "dhcp: настройки dnsmasq (сервер podkop) сохранены" "127.0.0.42" "$(uci -q get dhcp.cfg01411c.server)"
assert_eq "dhcp: секция dnsmasq одна" "1" "$(grep -c '=dnsmasq$' "$UCI_DIR/dhcp")"
# своё — переписано по сиду
assert_eq "network: wan на eth0 по сиду" "eth0" "$(uci -q get network.wan.device)"
assert_eq "network: lan на мосту br-lan" "br-lan" "$(uci -q get network.lan.device)"
assert_eq "network: lan1 по сиду" "192.168.52.1" "$(uci -q get network.lan1.ipaddr)"
assert_eq "network: стоковый wan6 на LAN-порту удалён" "" "$(uci -q get network.wan6)"
assert_eq "network: мост br-lan один, порт по сиду" "eth1" \
"$(for s in $(sec_of network device name br-lan); do uci -q get "network.$s.ports"; done)"
assert_eq "firewall: defaults одна" "1" "$(grep -c '=defaults$' "$UCI_DIR/firewall")"
assert_eq "firewall: зона lan одна" "1" "$(cnt firewall zone name lan)"
assert_eq "firewall: зона wan одна" "1" "$(cnt firewall zone name wan)"
assert_eq "firewall: forwarding lan→wan один" "1" "$(cnt firewall forwarding dest wan)"
# Точный набор правил с WAN: стоковые сняты, свои — по одному, чужое — на месте.
assert_eq "firewall: правила с WAN — ровно свои и чужое" \
"Allow-AWG-Port
Allow-DHCP-Renew
Allow-LuCI-from-WAN
Allow-Ping
Allow-SSH-from-WAN" \
"$(for s in $(sec_of firewall rule src wan); do uci -q get "firewall.$s.name"; done | sort)"
assert_eq "firewall: WAN — input REJECT" "REJECT" \
"$(for s in $(sec_of firewall zone name wan); do uci -q get "firewall.$s.input"; done)"
assert_eq "firewall: defaults — input REJECT" "REJECT" \
"$(for s in $(sed -n 's/^firewall\.\([^.=]*\)=defaults$/\1/p' "$UCI_DIR/firewall"); do uci -q get "firewall.$s.input"; done)"
assert_eq "firewall: SSH с WAN открыт" "1" "$(cnt firewall rule name Allow-SSH-from-WAN)"
assert_eq "firewall: правило LuCI с WAN на месте" "rule" "$(uci -q get firewall.wrt_luci_wan)"

# Повтор того же сида — тот же результат байт в байт, даже если своё
# испортили руками: своё пересоздаётся, а не дописывается.
for p in network firewall dhcp; do cp "$UCI_DIR/$p" "$UT/$p.1"; done
uci set network.lan.ipaddr=10.9.9.9
uci set network.wan.stale=1
prov multi-lan >/dev/null
same=1
for p in network firewall dhcp; do cmp -s "$UCI_DIR/$p" "$UT/$p.1" || same=0; done
assert_eq "write_network_uci: повторный провижн идемпотентен" "1" "$same"

# Сид сменился (новый instance-id, LAN стало меньше): lan1 и его мост
# уходят, чужое остаётся.
prov wan-dhcp-lan-static >/dev/null
assert_eq "новый сид: lan1 удалён" "" "$(uci -q get network.lan1)"
assert_eq "новый сид: br-lan1 удалён" "0" "$(cnt network device name br-lan1)"
assert_eq "новый сид: dhcp lan1 удалён" "" "$(uci -q get dhcp.lan1)"
assert_eq "новый сид: awg0 на месте" "amneziawg" "$(uci -q get network.awg0.proto)"
assert_eq "новый сид: зона awg на месте" "1" "$(cnt firewall zone name awg)"
rm -rf "$UT"
unset WRT_SHADOW UCI_DIR

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
