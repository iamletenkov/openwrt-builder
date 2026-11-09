# bisquite-device-write-connect

Сид, снятый **настоящим** `CloudInitGenerator` bisquite (`origin/main` на `6b24fca`, выпуск 3.2.1 — до правки
«`user-data` без сворачивания строк»). Генератор пишет `user-data` через `yaml.dump` с шириной по умолчанию 80, и
длинные элементы `runcmd:` приезжают свёрнутыми:

- строка подключения Stvor (`… | stvor-agent connect URL=… WAIT=0`) — `URL=… WAIT=0` уходит на вторую строку;
- строка стирания сида (`seed-cleanup: wipe-after-first-boot`) — вторая строка начинается с `-d);`, то есть похожа
  на новый элемент списка.

Код подключения фиктивный: `stc_` и 43 знака `A`; домен — `stvor.example.test`; пароли — `fixture-password` и
`fixture-root-password`. Хеши паролей с солью, при пересъёмке меняются вместе с `instance-id` — тесты на них не
завязаны.

## Как воспроизвести

```sh
BSQ=../bisquite   # рабочая копия bisquite с .venv
git -C "$BSQ" fetch origin
mkdir -p /tmp/bsq/src /tmp/bsq/out
git -C "$BSQ" archive origin/main src | tar -x -C /tmp/bsq/src
cat > /tmp/bsq/gen.py <<'EOF'
import asyncio, sys
from bisquite.domains.device.models.config import CloudInitConfig
from bisquite.infrastructure.device.cloud_init import CloudInitGenerator

CODE = "stc_" + "A" * 43
cfg = CloudInitConfig.model_validate({
    "user": "ops",
    "password": "fixture-password",
    "root-password": "fixture-root-password",
    "hostname": "wrt-1",
    "network": [
        {"name": "eth0", "mode": "dhcp"},
        {"name": "eth1", "mode": "static", "ip": "192.168.51.1/24", "gw": "192.168.51.254"},
    ],
    "firstboot-commands": [
        f"printf '%s' '{CODE}' | stvor-agent connect URL=https://stvor.example.test WAIT=0",
    ],
    "seed-cleanup": "wipe-after-first-boot",
})
g = CloudInitGenerator()
async def main():
    for name, fn in (("user-data", g.generate_user_data),
                     ("network-config", g.generate_network_config),
                     ("meta-data", g.generate_meta_data)):
        with open(f"{sys.argv[1]}/{name}", "w") as f:
            f.write(await fn(cfg))
asyncio.run(main())
EOF
PYTHONPATH=/tmp/bsq/src/src "$BSQ/.venv/bin/python" /tmp/bsq/gen.py /tmp/bsq/out
```

Окружение — `.venv` bisquite (PyYAML 6.0.3, pydantic 2.13); код генератора — из архива `origin/main`, а не из
рабочей копии.
