# shellcheck shell=dash
# Состояние provision-once. WRT_STATE_DIR переопределяем (тесты).

WRT_STATE_DIR="${WRT_STATE_DIR:-/etc/wrt-cloudinit}"

_wrt_state_file() { printf '%s/instance-id' "$WRT_STATE_DIR"; }

# already_provisioned <instance-id> → 0, если сохранённый id == аргумент (непуст)
already_provisioned() {
	f=$(_wrt_state_file)
	[ -f "$f" ] || return 1
	[ -n "$1" ] && [ "$1" = "$(cat "$f" 2>/dev/null)" ]
}

# mark_provisioned <instance-id> → записать id
mark_provisioned() {
	mkdir -p "$WRT_STATE_DIR" || return 1
	printf '%s\n' "$1" > "$(_wrt_state_file)"
}
