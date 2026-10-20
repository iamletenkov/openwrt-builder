# openwrt-builder

Сборка образов **OpenWrt 25.12+** (пакетный менеджер apk) через ImageBuilder в
Docker. В образ встроены аналог cloud-init (`wrt.cloudinit`) и авторесайз
корня на весь диск. Образы 24.10 (opkg) — только в релизе `v0.1.0`.

## Таргеты

| Назначение | `TARGET` | `SUBTARGET` | `PROFILE` | Что брать |
|---|---|---|---|---|
| ВМ / железо x86-64 | `x86` | `64` | `generic` | `…-ext4-combined-efi.qcow2` (ВМ), `.img.gz` (железо) |
| ВМ / серверы arm64 (EFI) | `armsr` | `armv8` | `generic` | `…-ext4-combined-efi.qcow2` |
| Raspberry Pi 4 | `bcm27xx` | `bcm2711` | `rpi-4` | `…-ext4-factory.img.gz` |
| Raspberry Pi 5 | `bcm27xx` | `bcm2712` | `rpi-5` | `…-ext4-factory.img.gz` |

Брать **ext4**-образы: только у них корень растёт онлайн. У squashfs overlay
на f2fs онлайн не растёт.

## Сборка

```bash
make build                                                   # x86-64, 25.12.6
make build TARGET=armsr SUBTARGET=armv8
make build TARGET=bcm27xx SUBTARGET=bcm2711 PROFILE=rpi-4
make build OPENWRT_RELEASE=25.12.6 ROOTFS_SIZE=2048 JOBS=6
make test                                                    # тесты скриптов образа
```

Артефакты — в `output/<релиз>/<target>-<subtarget>/`, ImageBuilder кешируется в
`cache/` (`make distclean` удаляет оба). Из GitHub: Actions → *Build OpenWrt
Images* → *Run workflow* (релиз, таргет или «все», флаг `publish` создаёт релиз);
тег `v*.*.*` собирает все таргеты и публикует релиз; pull request — тесты,
actionlint и сборка всех таргетов без релиза.

| Переменная | По умолчанию | |
|---|---|---|
| `OPENWRT_RELEASE` | `25.12.6` | релиз OpenWrt, не ниже 25.12 |
| `TARGET` / `SUBTARGET` / `PROFILE` | `x86` / `64` / `generic` | см. таблицу выше |
| `ROOTFS_SIZE` | `1024` | размер корневого раздела, МиБ (на устройстве растёт до размера диска) |
| `JOBS` | `4` | потоки make |
| `MIRROR` | `https://downloads.openwrt.org` | зеркало релизов |

## Конфигурация

- `config/packages.txt` — пакеты (по одному в строке, `-pkg` убирает пакет);
  `config/packages-<target>-<subtarget>.txt` — добавки для таргета.
- `config/feeds.txt` — доп. apk-фиды: URL на `packages.adb`; ключ фида (`*.pem`)
  — в `config/keys/`. Проверка подписей не отключается.
- `config/local-packages.txt` — сторонние `.apk` по URL (с sha256).
- `overlay/` — файлы образа из репозитория (cloud-init, ресайз); `files/` —
  свой overlay (gitignored), кладётся поверх.

ImageBuilder проверяется по `sha256sums` релиза. ext4-корень после
ImageBuilder пересобирается `mke2fs -d` (тот же UUID и метка): ФС от
`make_ext4fs` ядро онлайн не расширяет. Метаданные sysupgrade в `.img.gz` при
этом теряются — обновлять такой образ через sysupgrade только с `-F`.

## Что делает образ при первой загрузке

1. `70-rootpt-resize` и `80-rootfs-resize` (uci-defaults) — раздел и ext4
   корня до конца диска (или до раздела `cidata`), онлайн, без перезагрузки.
   Журнал: `logread | grep -E 'rootpt|rootfs'`. Отключить — создать
   `/etc/rootpt-resize` и `/etc/rootfs-resize`.
2. `wrt.cloudinit` (S47) — NoCloud: имя хоста, пользователь, пароль (хеш),
   ssh-ключи (`users:` и верхнего уровня, как у Proxmox `--sshkeys`), пароль
   root (`chpasswd`), `runcmd`, сеть (v1 Proxmox и v2): первый NIC — WAN,
   остальные — LAN-мосты с DHCP-сервером и NAT. На WAN открыты только SSH,
   LuCI (80/443), ping и продление DHCP.

**Откуда берётся сид.** Только CD-ROM гипервизора в ВМ (Proxmox
`ide2: …:cloudinit,media=cdrom`, ISO с меткой `cidata`) или раздел `cidata`
на загрузочном диске (`bs device write`). Флешки, вторые диски, USB-приводы
игнорируются. Повторный провижн (новый `instance-id`) со съёмного носителя
(SD, USB) — только при `uci set wrt_cloudinit.main.allow_removable_reprovision=1`.

Если после провижна у root пустой пароль, он получает пароль пользователя
из сида; если паролей в сиде нет — вход root по паролю в SSH выключается,
а LuCI с WAN закрыта (правило `firewall.wrt_luci_wan` выключено), пока у root
нет пароля: задайте его из LAN — правило включится на следующей загрузке.
