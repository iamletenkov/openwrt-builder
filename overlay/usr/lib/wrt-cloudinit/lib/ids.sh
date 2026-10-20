# shellcheck shell=dash
# next_id_from <passwd|group> [нижняя граница] → следующий свободный id.
# Системные id выше 59999 (nobody/nogroup = 65534) не учитываются: прежде
# первый пользователь получал 65535 — «-1» для 16-битных uid.
next_id_from() {
	local file=$1 floor=${2:-1000}
	[ -f "$file" ] || return 1
	awk -F: -v floor="$floor" '
		BEGIN { max = floor - 1 }
		$3 >= floor && $3 < 60000 && $3 > max { max = $3 }
		END { print max + 1 }
	' "$file"
}
