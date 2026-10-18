.DEFAULT_GOAL := help
.PHONY: help lint test test-bash32 test-docker check

SHELL_FILES := setup.sh tests/*.sh

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

lint: ## shellcheck all scripts
	shellcheck -x $(SHELL_FILES)

test: ## Unit tests (no root, no containers)
	bash tests/test_setup.sh

test-bash32: ## Unit tests + macOS dry-run under bash 3.2 (the macOS system bash)
	docker run --rm --user 1000 -e HOME=/tmp/h -v "$(CURDIR):/src:ro" bash:3.2 \
	  bash -c 'mkdir -p /tmp/h && bash /src/tests/test_setup.sh && UNAME_S=Darwin /src/setup.sh --dry-run'

test-docker: ## Run setup.sh in Arch/Ubuntu/Debian/Fedora/Rocky/Alma containers
	bash tests/docker_matrix.sh

check: lint test ## lint + unit tests
