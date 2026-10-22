# Makefile - dockerized bats runner for SHIPLOG-Lite
#
# Parallel agents or branches can use their own image/container names without
# touching the defaults, e.g.:
#   make test IMAGE=shiplog-tests-g8a CONTAINER_NAME=shiplog-tests-g8a
#
# Test knobs below are forwarded into the container unchanged. All of them are
# opt-in; the suite runs with no timeout unless TEST_TIMEOUT_SECS is set (#132).

IMAGE           ?= shiplog-tests
CONTEXT         ?= .
DOCKER_BUILD_OPTS ?=
CONTAINER_NAME  ?= shiplog-tests-run
RUN_ID          := $(shell date +%s)
DOCKER_RUN_OPTS ?=

# Test environment forwarded to `docker run` (empty values mean "use the
# container default": no timeout, local sandbox, plain `bats -r`).
TEST_TIMEOUT_SECS         ?=
SHIPLOG_USE_LOCAL_SANDBOX ?=
BATS_FLAGS                ?=
TEST_ENV_FLAGS = \
	-e TEST_TIMEOUT_SECS="$(TEST_TIMEOUT_SECS)" \
	-e SHIPLOG_USE_LOCAL_SANDBOX="$(SHIPLOG_USE_LOCAL_SANDBOX)" \
	-e BATS_FLAGS="$(BATS_FLAGS)"

.PHONY: all build test clean progress

all: test

## Build the test image
build:
	docker build $(DOCKER_BUILD_OPTS) \
		-t $(IMAGE) $(CONTEXT)

test: build
	- docker rm -f $(CONTAINER_NAME) >/dev/null 2>&1 || true
	docker run --rm --name $(CONTAINER_NAME) $(TEST_ENV_FLAGS) $(DOCKER_RUN_OPTS) $(IMAGE)

## Clean local dangling images/containers (non-destructive)
clean:
	@echo "Nothing to clean inside repo. Use docker system prune -f at your own risk."
progress:
	@bash scripts/update-task-progress.sh
	@echo "Progress bars updated."
