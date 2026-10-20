# shellcheck shell=dash
# Откуда можно брать сид (NoCloud cidata). Чистые функции поверх sysfs и
# mountinfo; пути переопределяются переменными — так их проверяют тесты.
#
# Сид несёт пароль root, ssh-ключи и runcmd, то есть равен root-доступу.
# Поэтому принимается он ровно из двух источников:
#   hypervisor — CD-ROM (sr*) в виртуальной машине: в Proxmox это
#                ide2/scsiN «cloudinit, media=cdrom» (ISO9660 с меткой cidata).
#                Привод на шине USB и привод на железе сюда НЕ относятся;
#   bootdisk   — раздел с меткой cidata на том же диске, что и корень
#                (его кладёт `bs device write` в конец носителя).
# Всё остальное — флешки, вторые диски, USB-приводы — `untrusted` и не
# читается вовсе.

WRT_SYS="${WRT_SYS:-/sys}"
WRT_MOUNTINFO="${WRT_MOUNTINFO:-/proc/self/mountinfo}"
WRT_CPUINFO="${WRT_CPUINFO:-/proc/cpuinfo}"

# running_in_vm → 0, если система — гость гипервизора (флаг hypervisor в
# cpuinfo на x86 или производитель в DMI). На железе физический CD-привод
# источником сида не считается.
running_in_vm() {
	grep -qw hypervisor "$WRT_CPUINFO" 2>/dev/null && return 0
	cat "$WRT_SYS/class/dmi/id/sys_vendor" "$WRT_SYS/class/dmi/id/product_name" 2>/dev/null | \
		grep -qiE 'qemu|kvm|proxmox|vmware|virtualbox|innotek|xen|microsoft corporation|bochs'
}

# root_majmin → «major:minor» блочного устройства корня.
# Корень ext4 смонтирован как /dev/root на «/», squashfs — как /dev/root на
# «/rom»; при иной записи источника берём «/rom» или не-overlay «/».
root_majmin() {
	awk '
		{
			for (i = 7; i <= NF && $i != "-"; i++) ;
			fs = $(i + 1); src = $(i + 2)
			if (src == "/dev/root") { print $3; found = 1; exit }
			if ($5 == "/rom" || ($5 == "/" && fs != "overlay" && fs != "rootfs")) cand = $3
		}
		END { if (!found && cand != "") print cand }
	' "$WRT_MOUNTINFO" 2>/dev/null
}

# sysdir_of_majmin <maj:min> → каталог устройства в /sys/devices/...
sysdir_of_majmin() {
	readlink -f "$WRT_SYS/dev/block/$1" 2>/dev/null
}

# sysdir_of_name <sda2|sr0> → каталог устройства в /sys/devices/...
sysdir_of_name() {
	readlink -f "$WRT_SYS/class/block/$1" 2>/dev/null
}

# disk_of_sysdir <каталог> → имя диска (для раздела — родитель)
disk_of_sysdir() {
	if [ -f "$1/partition" ]; then
		basename "$(dirname "$1")"
	else
		basename "$1"
	fi
}

# root_disk → имя диска, на котором лежит корень (sda, vda, mmcblk0, nvme0n1)
root_disk() {
	local mm dir
	mm=$(root_majmin)
	[ -n "$mm" ] || return 1
	dir=$(sysdir_of_majmin "$mm")
	[ -n "$dir" ] && [ -d "$dir" ] || return 1
	disk_of_sysdir "$dir"
}

# classify_seed_dev <имя устройства> → hypervisor | bootdisk | untrusted
classify_seed_dev() {
	local name=$1 dir rdisk
	name=${name#/dev/}
	dir=$(sysdir_of_name "$name")
	if [ -z "$dir" ] || [ ! -d "$dir" ]; then
		echo untrusted
		return 0
	fi
	rdisk=$(root_disk)
	if [ -f "$dir/partition" ] && [ -n "$rdisk" ] && \
	   [ "$(disk_of_sysdir "$dir")" = "$rdisk" ]; then
		echo bootdisk
		return 0
	fi
	case "$dir" in
		*/usb[0-9]*) echo untrusted; return 0 ;;
	esac
	case "$name" in
		sr[0-9]*) if running_in_vm; then echo hypervisor; else echo untrusted; fi ;;
		*) echo untrusted ;;
	esac
}

# seed_dev_removable <имя устройства> → 0, если носитель съёмный
# (флаг removable у диска, шина USB или SD/MMC). Привод гипервизора съёмным
# не считается: Proxmox меняет его содержимое штатно при правке cloud-init.
seed_dev_removable() {
	local name=${1#/dev/} dir disk
	[ "$(classify_seed_dev "$name")" = hypervisor ] && return 1
	dir=$(sysdir_of_name "$name")
	case "$dir" in
		*/usb[0-9]*) return 0 ;;
	esac
	disk=$(disk_of_sysdir "$dir")
	case "$disk" in
		mmcblk*) return 0 ;;
	esac
	[ "$(cat "$WRT_SYS/class/block/$disk/removable" 2>/dev/null)" = 1 ]
}
