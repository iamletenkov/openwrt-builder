DOCKER_COMPOSE ?= docker compose
export OPENWRT_RELEASE ?= 25.12.6
export TARGET ?= x86
export SUBTARGET ?= 64
export PROFILE ?= generic
export ROOTFS_SIZE ?= 1024
export JOBS ?= 4
export UID := $(shell id -u)
export GID := $(shell id -g)

.PHONY: build test clean distclean help

help:
	@echo "make build [OPENWRT_RELEASE=25.12.6 TARGET=x86 SUBTARGET=64 PROFILE=generic ROOTFS_SIZE=1024 JOBS=4]"
	@echo "  TARGET/SUBTARGET/PROFILE: x86/64/generic | armsr/armv8/generic | bcm27xx/bcm2711/rpi-4 | bcm27xx/bcm2712/rpi-5"
	@echo "make test       - тесты скриптов образа и пинов сторонних пакетов, shellcheck (в docker)"
	@echo "make clean      - удалить output/"
	@echo "make distclean  - удалить output/ и cache/ (ImageBuilder)"

build:
	mkdir -p output cache files
	$(DOCKER_COMPOSE) build
	$(DOCKER_COMPOSE) run --rm builder

test:
	docker run --rm -v "$(CURDIR):/src:ro" -w /src debian:12-slim sh -c \
	  'apt-get update -qq >/dev/null && apt-get install -y -qq shellcheck dash busybox gawk >/dev/null && \
	   dash tests/cloudinit/run-tests.sh && echo "── busybox ash ──" && busybox sh tests/cloudinit/run-tests.sh && \
	   echo "── сторонние пакеты ──" && dash tests/packages/run-tests.sh'

# Только output/: files/ - пользовательский overlay, make его не трогает.
clean:
	rm -rf output

distclean: clean
	rm -rf cache
