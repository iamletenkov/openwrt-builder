# shellcheck shell=dash
# Доступ к LuCI с WAN зависит от пароля root.
#
# Чистый OpenWrt — root без пароля, и rpcd пускает в LuCI по пустому паролю.
# Если сид не дал ни одного пароля, правило «LuCI с WAN» (секция
# firewall.wrt_luci_wan) остаётся выключенным: зона WAN режет 80/443, LuCI
# доступна только из LAN. Как только у root появился пароль, правило
# включается — при провижне сразу, иначе на следующей загрузке (luci_wan_sync
# зовётся из wrt.cloudinit на каждом старте).
#
# WRT_SHADOW переопределяем (тесты).

WRT_SHADOW="${WRT_SHADOW:-/etc/shadow}"

# root_password_empty → 0, если пароль root пуст или строки root нет вовсе
# (сомнение трактуем как «пуст» — WAN остаётся закрытым).
root_password_empty() {
	awk -F: '$1 == "root" { found = 1; pw = $2; exit }
		END { exit !(!found || pw == "") }' "$WRT_SHADOW" 2>/dev/null
}

# luci_wan_sync → выставить firewall.wrt_luci_wan.enabled по паролю root.
# Код 0 — правило изменено (вызывающий перезагружает firewall), 1 — нет
# изменений или правила нет.
luci_wan_sync() {
	local want cur
	[ "$(uci -q get firewall.wrt_luci_wan)" = rule ] || return 1
	if root_password_empty; then want=0; else want=1; fi
	cur=$(uci -q get firewall.wrt_luci_wan.enabled)
	[ "${cur:-1}" = "$want" ] && return 1
	uci -q set firewall.wrt_luci_wan.enabled="$want" || return 1
	uci -q commit firewall
}
