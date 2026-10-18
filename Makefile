.DEFAULT_GOAL := help
.PHONY: help lint test test-docker check

SHELL_FILES := setup.sh tests/*.sh

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

lint: ## shellcheck all scripts
	shellcheck -x $(SHELL_FILES)

test: ## Unit tests (no root, no containers)
	bash tests/test_setup.sh

test-docker: ## Run setup.sh in Arch/Ubuntu/Debian/Fedora/Rocky/Alma containers
	bash tests/docker_matrix.sh

check: lint test ## lint + unit tests
