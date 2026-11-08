# shellcheck shell=dash
# Чистые парсеры NoCloud v1 (Proxmox). Без сайд-эффектов.

# parse_netcfg <network-config> → построчно: iface|proto|ip|mask|gw
parse_netcfg() {
	awk '
		function ind(s){match(s,/^[ ]*/);return RLENGTH}
		function flush(){
			if(iface){
				p = proto ? proto : "dhcp"
				printf "%s|%s|%s|%s|%s\n", iface, p, ip, mask, gw
			}
			in_phys = 0; iface = proto = ip = mask = gw = ""; phys_ind = -1
		}
		/^[ ]*-[ ]*type:[ ]*physical/                       { flush(); in_phys=1; phys_ind=ind($0); next }
		in_phys && /^[ ]*-[ ]*type:/ && ind($0) <= phys_ind { flush(); next }
		in_phys {
			if($0~/^[ ]*name:/)             iface = $2
			if($0~/-[ ]*type:[ ]*static/)   proto = "static"
			if($0~/-[ ]*type:[ ]*dhcp4/)    proto = "dhcp"
			if($0~/^[ ]*address:/)          ip   = $2
			if($0~/^[ ]*netmask:/)          mask = $2
			if($0~/^[ ]*gateway:/)          gw   = $2
		}
		END{ flush() }
	' "$1" | tr -d "\"'"
}

# read_dns <network-config> → DNS|search (первый address и первый search)
read_dns() {
	awk '
		/^[ ]*-?[ ]*type:[ ]*nameserver/ { ns=1; mode=""; next }
		ns && /^[ ]*-[ ]*type:/          { ns=0 }
		ns && /^[ ]*address:/            { mode="dns";    next }
		ns && /^[ ]*search:/             { mode="search"; next }
		ns && /^[ ]*-/ {
			v=$0; sub(/^[ ]*-[ ]*/,"",v)
			if (mode=="dns"    && dns=="")  { gsub(/[^0-9.]/,"",v);         dns=v }
			if (mode=="search" && srch=="") { gsub(/[^A-Za-z0-9_.-]/,"",v); srch=v }
		}
		END { print dns"|"srch }
	' "$1"
}

# get_seed_instance_id <meta-data> → instance-id (пусто при отсутствии)
get_seed_instance_id() {
	awk -F': *' '$1=="instance-id"{print $2; exit}' "$1" 2>/dev/null | tr -d " \"'"
}

# validate_netcfg <network-config> → 0, если есть хотя бы один интерфейс
validate_netcfg() {
	parse_netcfg "$1" | grep -q '^[^|][^|]*|'
}

# ---------------------------------------------------------------------------
# Формат bisquite: стандартный cloud-init, а не диалект Proxmox.
#
# `bs device write` пишет то, что документирует сам cloud-init: список `users:`
# с `hashed_passwd` и network-config **version 2**. Диалект Proxmox (плоские
# `user:`/`password:` и network-config v1) остаётся поддержан — по нему
# приезжает сид, который генерирует сам Proxmox при `bs compose up`.
#
# Пересекался у двух форматов ровно один ключ — `hostname`. Поэтому раньше
# карта, записанная `bs device write`, давала имя хоста и больше ничего:
# пользователь, пароль и сеть молча не применялись.
# ---------------------------------------------------------------------------

# parse_netcfg_v2 <network-config> → построчно: iface|proto|ip|mask|gw
# Формат тот же, что у v1, чтобы вызывающий не различал версии.
parse_netcfg_v2() {
	awk '
		function ind(s){match(s,/^[ ]*/);return RLENGTH}
		function prefix_to_mask(p,   i,bits,o,r) {
			r = ""
			for (i = 0; i < 4; i++) {
				bits = p >= 8 ? 8 : (p > 0 ? p : 0)
				p -= bits
				o = 0
				# 8 бит → 255, 7 → 254 и так далее.
				if (bits > 0) o = 256 - 2 ^ (8 - bits)
				r = r (i ? "." : "") o
			}
			return r
		}
		function flush(){
			if (iface) {
				p = dhcp ? "dhcp" : (ip ? "static" : "dhcp")
				printf "%s|%s|%s|%s|%s\n", iface, p, ip, mask, gw
			}
			iface = ip = mask = gw = ""; dhcp = 0; sect = ""
		}
		/^[ ]*ethernets:[ ]*$/ { in_eth = 1; eth_ind = ind($0); next }
		in_eth && /^[ ]*[A-Za-z0-9_.-]+:[ ]*$/ && ind($0) == eth_ind + 2 {
			flush()
			iface = $1; sub(/:$/, "", iface)
			next
		}
		in_eth && iface {
			if ($0 ~ /^[ ]*dhcp4:[ ]*(true|yes)/)  dhcp = 1
			if ($0 ~ /^[ ]*addresses:/)            { sect = "addr";   next }
			if ($0 ~ /^[ ]*routes:/)               { sect = "routes"; next }
			if ($0 ~ /^[ ]*nameservers:/)          { sect = "ns";     next }
			if ($0 ~ /^[ ]*gateway4:/)             { gw = $2; next }
			if (sect == "addr" && $0 ~ /^[ ]*-/ && ip == "") {
				v = $0; sub(/^[ ]*-[ ]*/, "", v); gsub(/[" ]/, "", v)
				n = index(v, "/")
				if (n) { ip = substr(v, 1, n - 1); mask = prefix_to_mask(substr(v, n + 1) + 0) }
				else   { ip = v; mask = "255.255.255.0" }
			}
			if (sect == "routes" && $0 ~ /^[ ]*(-[ ]*)?via:/ && gw == "") {
				v = $0; sub(/^[ ]*-?[ ]*via:[ ]*/, "", v); gsub(/[" ]/, "", v); gw = v
			}
		}
		END { flush() }
	' "$1" | tr -d "\"'"
}

# netcfg_version <network-config> → 2, если это network-config v2, иначе 1
netcfg_version() {
	if grep -qE '^[ ]*version:[ ]*2[ ]*$' "$1" 2>/dev/null && \
	   grep -qE '^[ ]*ethernets:' "$1" 2>/dev/null; then
		echo 2
	else
		echo 1
	fi
}

# parse_netcfg_any <network-config> → разбор независимо от версии
parse_netcfg_any() {
	if [ "$(netcfg_version "$1")" = 2 ]; then
		parse_netcfg_v2 "$1"
	else
		parse_netcfg "$1"
	fi
}

# parse_users <user-data> → построчно: name|hash
# Разбирает список `users:` стандартного cloud-config. `hashed_passwd`
# предпочитается `passwd`: оба означают готовый хеш, но первый — канонический.
parse_users() {
	awk '
		function ind(s){match(s,/^[ ]*/);return RLENGTH}
		function flush(){
			if (name != "" && name != "default") printf "%s|%s\n", name, hash
			name = hash = ""
		}
		/^[ ]*users:[ ]*$/ { in_users = 1; u_ind = ind($0); next }
		in_users && /^[ ]*[a-z_]+:/ && ind($0) <= u_ind { flush(); in_users = 0 }
		in_users && /^[ ]*-[ ]*name:/ {
			flush()
			v = $0; sub(/^[ ]*-[ ]*name:[ ]*/, "", v); gsub(/[" ]/, "", v); name = v
			next
		}
		in_users && name != "" {
			if ($0 ~ /^[ ]*hashed_passwd:/) {
				v = $0; sub(/^[ ]*hashed_passwd:[ ]*/, "", v); gsub(/["]/, "", v); hash = v
			}
			else if ($0 ~ /^[ ]*passwd:/ && hash == "") {
				v = $0; sub(/^[ ]*passwd:[ ]*/, "", v); gsub(/["]/, "", v); hash = v
			}
		}
		END { flush() }
	' "$1"
}

# parse_ssh_keys <user-data> <username> → построчно ключи этого пользователя
parse_ssh_keys() {
	awk -v want="$2" '
		function ind(s){match(s,/^[ ]*/);return RLENGTH}
		/^[ ]*users:[ ]*$/ { in_users = 1; next }
		in_users && /^[ ]*-[ ]*name:/ {
			v = $0; sub(/^[ ]*-[ ]*name:[ ]*/, "", v); gsub(/[" ]/, "", v)
			cur = v; keys = 0; next
		}
		in_users && cur == want && /^[ ]*ssh_authorized_keys:/ { keys = 1; k_ind = ind($0); next }
		in_users && keys && /^[ ]*-/ && ind($0) > k_ind - 2 {
			v = $0; sub(/^[ ]*-[ ]*/, "", v); gsub(/["]/, "", v)
			if (v != "") print v
			next
		}
		in_users && keys { keys = 0 }
	' "$1"
}

# parse_root_password <user-data> → хеш пароля root (пусто, если не задан)
#
# Бисквит пишет его через `chpasswd: list: - root:$6$...`, а не в списке
# `users:`. Раньше это не читалось вовсе, и устройство приезжало с ПУСТЫМ
# паролем root — то есть в дефолтном состоянии OpenWrt, хотя манифест просил
# другое. Двоеточие делится только первое: хеш sha512-crypt сам содержит `$`.
parse_root_password() {
	awk '
		function ind(s){match(s,/^[ ]*/);return RLENGTH}
		/^[ ]*chpasswd:[ ]*$/ { in_cp = 1; cp_ind = ind($0); next }
		in_cp && /^[ ]*[a-z_]+:/ && ind($0) <= cp_ind { in_cp = 0 }
		in_cp && /^[ ]*-[ ]*root:/ {
			v = $0
			sub(/^[ ]*-[ ]*root:[ ]*/, "", v)
			gsub(/["]/, "", v)
			print v
			exit
		}
	' "$1"
}

# read_dns_v2 <network-config> → DNS|search (первый адрес и первый домен)
read_dns_v2() {
	awk '
		/^[ ]*nameservers:[ ]*$/ { ns = 1; mode = ""; next }
		ns && /^[ ]*addresses:[ ]*$/ { mode = "dns";    next }
		ns && /^[ ]*search:[ ]*$/    { mode = "search"; next }
		ns && /^[ ]*-/ {
			v = $0; sub(/^[ ]*-[ ]*/, "", v)
			gsub(/[^0-9A-Za-z.:_-]/, "", v)
			if (mode == "dns"    && dns  == "") dns  = v
			if (mode == "search" && srch == "") srch = v
			next
		}
		ns && /^[ ]*[a-z_]+:/ { ns = 0; mode = "" }
		END { print dns "|" srch }
	' "$1"
}

# read_dns_any <network-config> → DNS|search независимо от версии
read_dns_any() {
	if [ "$(netcfg_version "$1")" = 2 ]; then
		read_dns_v2 "$1"
	else
		read_dns "$1"
	fi
}

# parse_runcmd <user-data> → построчно команды из `runcmd:`
#
# Бисквит кладёт firstboot-команды манифеста именно сюда. Агент читал только
# /usr/libexec/bisquite-firstboot.sh, который наполняет Proxmox-адаптер, —
# поэтому команды из `bs device write` не выполнялись никогда.
#
# parse_runcmd <user-data> skipped → по строке на пропущенный элемент:
# `multiline` (блочный `|`/`>`) или `malformed` (незакрытые кавычки,
# неподдержанное экранирование). Содержимое элемента не выводится: в нём бывают
# секреты (код подключения), а вывод идёт в журнал.
#
# Элемент — строка `- …` и все следующие строки с отступом БОЛЬШЕ, чем у его
# `-`. Отступ проверяется раньше, чем `-`: yaml.dump сворачивает длинную строку
# на ширине 80, и продолжение может начаться с `-n`/`-d`/`-a` (`[ -n "$seed" ]`,
# `mktemp -d`, `wipefs -a`) — это часть команды, а не новый элемент.
# Склейка — через пробел (свёрнутый plain и кавычки); `'…'` — кавычки снимаются,
# `''` → `'`; `"…"` — кавычки снимаются, `\"`, `\\`, `\ ` и `\` в конце строки
# (перенос без пробела) — как пишет PyYAML. Прочие экранирования не
# поддержаны: элемент пропускается, а не исполняется не тем, что написал автор.
parse_runcmd() {
	awk -v mode="${2:-}" '
		function ind(s){match(s,/^[ ]*/);return RLENGTH}
		function skip(why) { if (mode == "skipped") print why }
		# odd_bs(s) → 1, если s кончается нечётным числом обратных косых
		function odd_bs(s,   n) {
			n = 0
			while (n < length(s) && substr(s, length(s) - n, 1) == "\\") n++
			return n % 2
		}
		function add(s) {
			sub(/^[ ]+/, "", s)
			if (buf == "") { buf = s; return }
			if (substr(buf, 1, 1) == "\"" && odd_bs(buf))
				buf = substr(buf, 1, length(buf) - 1) s
			else
				buf = buf " " s
		}
		function unq1(s,   i, c, n, r) {
			n = length(s); r = ""
			for (i = 2; i <= n; i++) {
				c = substr(s, i, 1)
				if (c != q) { r = r c; continue }
				if (i < n && substr(s, i + 1, 1) == q) { r = r q; i++; continue }
				if (i == n) return r
				break
			}
			bad = 1; return ""
		}
		function unq2(s,   i, c, e, n, r) {
			n = length(s); r = ""
			for (i = 2; i <= n; i++) {
				c = substr(s, i, 1)
				if (c == "\\") {
					e = substr(s, i + 1, 1); i++
					if (e == "\\" || e == "\"" || e == " ") { r = r e; continue }
					break
				}
				if (c != "\"") { r = r c; continue }
				if (i == n) return r
				break
			}
			bad = 1; return ""
		}
		function flush(   c, v) {
			if (!open) return
			open = 0; v = buf; buf = ""; bad = 0
			c = substr(v, 1, 1)
			if (c == "|" || c == ">") { skip("multiline"); return }
			if (c == q) v = unq1(v)
			else if (c == "\"") v = unq2(v)
			if (bad) { skip("malformed"); return }
			if (v != "" && mode == "") print v
		}
		BEGIN { q = sprintf("%c", 39) }
		{ line = $0; sub(/[ \t\r]+$/, "", line) }
		!in_rc {
			if (line ~ /^[ ]*runcmd:$/) { in_rc = 1; rc_ind = ind(line) }
			next
		}
		line == "" { next }
		{ n = ind(line); c1 = substr(buf, 1, 1) }
		# Продолжение элемента — по отступу, до проверки на `-`. Строка-комментарий
		# внутри кавычек — текст, вне их — комментарий YAML.
		open && n > it_ind {
			if (line ~ /^[ ]*#/ && c1 != q && c1 != "\"") next
			add(line); next
		}
		line ~ /^[ ]*#/ { next }
		n >= rc_ind && (line ~ /^[ ]*-$/ || line ~ /^[ ]*- /) {
			flush(); open = 1; it_ind = n
			v = line; sub(/^[ ]*-[ ]*/, "", v); buf = v
			next
		}
		n <= rc_ind { flush(); in_rc = 0 }
		END { flush() }
	' "$1"
}

# parse_toplevel_ssh_keys <user-data> → ключи из `ssh_authorized_keys:` верхнего
# уровня. Так их пишет Proxmox (`qm set --sshkeys`): ключи «пользователя по
# умолчанию», а не элемента списка `users:`.
parse_toplevel_ssh_keys() {
	awk '
		/^ssh_authorized_keys:[ ]*$/ { on = 1; next }
		on && /^[ ]*-/ {
			v = $0; sub(/^[ ]*-[ ]*/, "", v); gsub(/["\047]/, "", v)
			if (v != "") print v
			next
		}
		on && /^[^ ]/ { on = 0 }
	' "$1"
}
