#!/bin/sh
# Какие секции network, dhcp и firewall принадлежат wrt.cloudinit.
#
# Провижн сида (первая загрузка или новый instance-id) раньше стирал эти
# конфиги целиком: интерфейсы и зоны других программ (awg0 расширения
# amneziawg, wg*, include podkop) пропадали. Теперь удаляются только свои
# секции — те, что wrt.cloudinit пишет сам, и стоковые секции образа, которые
# они заменяют, — а всё остальное остаётся как было.
#
# Своё:
#   network  — interface loopback, wan, wan6 (стоковый, на LAN-порту под
#              сидом), lan, lanN; device-мосты br_lanN / name br-lanN;
#   dhcp     — dhcp wan, lan, lanN (dnsmasq не удаляется: в нём настройки
#              других программ, например сервер podkop);
#   firewall — defaults; зоны с именем lan и wan; forwarding между ними;
#              стоковые правила OpenWrt (по имени);
#   любая секция с именем wrt_* — свои именованные секции.
# Зоны lan и wan — свои целиком: что в них добавили руками, сид перепишет.

# Стоковые правила firewall OpenWrt 25.12 и прежние анонимные правила
# wrt.cloudinit (до именованных wrt_*).
WRT_OWNED_FW_RULES="Allow-DHCP-Renew Allow-Ping Allow-IGMP Allow-DHCPv6 Allow-MLD"
WRT_OWNED_FW_RULES="$WRT_OWNED_FW_RULES Allow-ICMPv6-Input Allow-ICMPv6-Forward"
WRT_OWNED_FW_RULES="$WRT_OWNED_FW_RULES Allow-IPSec-ESP Allow-ISAKMP"
WRT_OWNED_FW_RULES="$WRT_OWNED_FW_RULES Allow-SSH-from-WAN Allow-LuCI-from-WAN"

# owned_sections PKG → имена своих секций PKG по выводу `uci -X show PKG`
# на stdin (анонимные — cfgXXXXXX, их `uci delete` принимает и они не
# сдвигаются при удалении, в отличие от @type[N]).
owned_sections() {
	awk -v pkg="$1" -v rules="$WRT_OWNED_FW_RULES" '
	function val(s, o,   v) {
		v = opt[s, o]
		sub(/^\047/, "", v)
		sub(/\047.*$/, "", v)
		return v
	}
	function lanwan(z) { return z == "lan" || z == "wan" }
	function owned(s, t,   nm) {
		if (s ~ /^wrt_/) return 1
		nm = val(s, "name")
		if (pkg == "network") {
			if (t == "interface") return s ~ /^(loopback|wan|wan6|lan[0-9]*)$/
			if (t == "device") return s ~ /^br_lan[0-9]*$/ || nm ~ /^br-lan[0-9]*$/
			return 0
		}
		if (pkg == "dhcp") return t == "dhcp" && s ~ /^(wan|lan[0-9]*)$/
		if (pkg == "firewall") {
			if (t == "defaults") return 1
			if (t == "zone") return lanwan(nm)
			if (t == "forwarding") return lanwan(val(s, "src")) && lanwan(val(s, "dest"))
			if (t == "rule") return nm in stock
		}
		return 0
	}
	BEGIN {
		n = split(rules, r, " ")
		for (i = 1; i <= n; i++) if (r[i] != "") stock[r[i]] = 1
	}
	{
		key = $0
		sub(/=.*/, "", key)
		v = substr($0, length(key) + 2)
		m = split(key, k, ".")
		if (k[1] != pkg) next
		if (m == 2) {
			if (!(k[2] in type)) order[++cnt] = k[2]
			type[k[2]] = v
		} else if (m == 3) {
			opt[k[2], k[3]] = v
		}
	}
	END { for (i = 1; i <= cnt; i++) if (owned(order[i], type[order[i]])) print order[i] }'
}

# purge_owned PKG → удалить свои секции PKG (без commit). Список снимается
# целиком до первого delete.
purge_owned() {
	local secs s
	secs=$(uci -q -X show "$1" 2>/dev/null | owned_sections "$1")
	for s in $secs; do
		uci -q delete "$1.$s"
	done
	return 0
}

# dnsmasq_section → имя первой секции dnsmasq (cfgXXXXXX у анонимной); нет
# секции — пусто.
dnsmasq_section() {
	uci -q -X show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([A-Za-z0-9_]*\)=dnsmasq$/\1/p' | head -n 1
}
