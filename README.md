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

У каждого релиза есть общий `SHA256SUMS` по файлам всех таргетов. Проверка
скачанного образа:

```bash
gh release download v0.3.1 -R iamletenkov/openwrt-builder \
  -p '*x86-64-generic-ext4-combined-efi.qcow2' -p SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

## Сторонние пакеты

| Пакеты | Версия | Откуда |
|---|---|---|
| `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` | 3.1.20260906 / 3.1.20260812 / 3.1.0 | [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) `v25.12.6` — SDK 25.12.6 из исходников amnezia-vpn, отдельно под каждый таргет |
| `podkop`, `luci-app-podkop` | 0.7.24 | [itdoginfo/podkop](https://github.com/itdoginfo/podkop) (зависимости, в т. ч. `sing-box`, — из официальных фидов) |
| `luci-theme-argon` | 3.0.0 | [jerrykuku/luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon) (настройки темы встроены) |

`kmod-amneziawg` зависит от `kernel=<версия>~<vermagic>` конкретного релиза и
таргета: при смене `OPENWRT_RELEASE` пины AmneziaWG обновляются вместе с ним,
иначе сборка упадёт на разрешении зависимостей. Тема по умолчанию прежняя,
Argon выбирается в LuCI (System → System → Language and Style).

## Сборка

```bash
make build                                                   # x86-64, 25.12.6
make build TARGET=armsr SUBTARGET=armv8
make build TARGET=bcm27xx SUBTARGET=bcm2711 PROFILE=rpi-4
make build OPENWRT_RELEASE=25.12.6 ROOTFS_SIZE=2048 JOBS=6
make test                                                    # тесты скриптов образа и пинов пакетов
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
- `config/local-packages.txt` (общие) и `config/local-packages-<target>-<subtarget>.txt`
  (под архитектуру и ядро) — сторонние `.apk`: строка `<URL фиксированного
  релиза> <sha256>`, sha256 обязателен. Файлы кладутся в локальный репозиторий
  ImageBuilder'а (индекс подписывается его ключом сборки); подписи
  официальных фидов проверяются как обычно. После сборки
  `builder/check-manifest.sh` сверяет манифест образа со списком пакетов.
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

**Чужие секции переживают провижн.** При провижне (первая загрузка или новый
`instance-id`) `wrt.cloudinit` удаляет и пишет заново только свои секции
`/etc/config/network`, `dhcp` и `firewall` (`lib/owned.sh`): интерфейсы
`loopback`, `wan`, `wan6`, `lan*` и мосты `br-lan*`, секции `dhcp` `wan`/`lan*`,
`defaults`, зоны `lan` и `wan`, forwarding между ними, стоковые правила OpenWrt
и всё с именем `wrt_*`. Интерфейсы и зоны других программ — `awg0` и его пир,
`wg*`, зона VPN и forwarding в неё, include podkop, настройки dnsmasq —
остаются. Зоны `lan` и `wan` — свои целиком: добавленное в них руками сид
перепишет, для VPN заводите отдельную зону. Чужие правила и пробросы портов
тоже остаются — клон ВМ с новым `instance-id` их унаследует. Секция dnsmasq
не пересоздаётся: стоковый `domain`/`local` (`lan`) остаётся, если в сиде нет
`search`.

**Откуда берётся сид.** Только CD-ROM гипервизора в ВМ (Proxmox
`ide2: …:cloudinit,media=cdrom`, ISO с меткой `cidata`) или раздел `cidata`
на загрузочном диске (`bs device write`). Флешки, вторые диски, USB-приводы
игнорируются. Повторный провижн (новый `instance-id`) со съёмного носителя
(SD, USB) — только при `uci set wrt_cloudinit.main.allow_removable_reprovision=1`.

Если после провижна у root пустой пароль, он получает пароль пользователя
из сида; если паролей в сиде нет — вход root по паролю в SSH выключается,
а LuCI с WAN закрыта (правило `firewall.wrt_luci_wan` выключено), пока у root
нет пароля: задайте его из LAN — правило включится на следующей загрузке.
