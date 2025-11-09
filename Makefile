DOCKER_COMPOSE ?= docker compose
OUTPUT_DIR ?= output
FILES_DIR ?= files

.PHONY: build clean

build: $(OUTPUT_DIR) $(FILES_DIR)
	$(DOCKER_COMPOSE) build
	$(DOCKER_COMPOSE) run --rm builder

clean:
	rm -rf "$(OUTPUT_DIR)" files

$(OUTPUT_DIR):
	mkdir -p "$(OUTPUT_DIR)"

$(FILES_DIR):
	mkdir -p "$(FILES_DIR)"
