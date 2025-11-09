DOCKER_COMPOSE ?= docker compose
OUTPUT_DIR ?= output

.PHONY: build clean

build: $(OUTPUT_DIR)
	$(DOCKER_COMPOSE) build
	$(DOCKER_COMPOSE) run --rm builder

clean:
	rm -rf "$(OUTPUT_DIR)"

$(OUTPUT_DIR):
	mkdir -p "$(OUTPUT_DIR)"
