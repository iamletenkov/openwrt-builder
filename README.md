# Как пользоваться проектом

0. **Заполните `packages.txt`.** По одному пакету в строке, без версий. Комментарии допускаются (# …).
1. `docker compose build` – соберёт слой с SDK и ImageBuilder.
2. `docker compose up` – запустит сборку. Готовые образы появятся в каталоге `output/`.

### Параметры (env)
| Переменная       | Значение по‑умолчанию | Описание |
|------------------|----------------------|----------|
| `OPENWRT_RELEASE`| `23.05.3`            | релиз OpenWrt |
| `TARGET`         | `x86`                | архитектура (см. targets/) |
| `SUBTARGET`      | `64`                 | под‑арх. |
| `PROFILE`        | `generic`            | профиль устройства |
| `ROOTFS_SIZE`    | `1024`               | размер `/dev/sda2` в MiB |

### rc.cloud – облачная инициализация
`rc.cloud` – минимальная реализация cloud‑init для OpenWrt. После старта она:
* читает **metadata service** (EC2, OpenStack, Hetzner и др.) и получает:
  * `instance-id`, `hostname`, `admin_pass`, SSH‑ключи и др.
* пишет hostname в UCI‑конфиг и ядро,
* добавляет SSH‑ключи в `authorized_keys`,
* может устанавливать пароль root через `admin_pass`.

#### Ключевые опции
| Способ           | Что делать |
|------------------|-----------|
| **Config‑Drive** | Создайте ISO/диск с меткой `config-2`. Внутри положите `meta_data.json`, `user_data` и т.д. Скрипт сам найдёт и примонтирует раздел. |
| **NoCloud**      | Передайте ядру `ds=nocloud` или `nocloud` – тогда rc.cloud пропустит поиск метаданных. |
| **Параметр `cloud_tries=N`** | Ограничивает число попыток обращения к метаданным (по‑умолч. 30). |

#### Пример user‑data (cloud‑config)

Скопируйте этот файл в user_data на config‑drive или разместите в metadata‑service.

```yaml
#cloud-config
password: "$6$rounds=4096$Gzkw3D…"  # заранее хэшированный
chpasswd: { expire: False }
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3Nz… user@example
```




### Проверка результата

После загрузки устройства выполните:

```bash
logread -e rc.cloud
dmesg | grep "rc.cloud"
```

Вы должны увидеть, что скрипт получил instance‑id и применил конфигурацию.


### Источники и полезные ссылки

rc.cloud: https://github.com/dtroyer/openwrt-packages (raw.githubusercontent.com)

Патч ROOTFS_PARTSIZE: обсуждение в mailing list (lists.infradead.org)