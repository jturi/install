# install — run `make` or `make help` to list every target.
#
# Extra setup.sh flags go in ARGS, for example:
#   make install ARGS="--ssh-server"
# Public targets carry a `## description`; `##@ Title` starts a help section.

.DEFAULT_GOAL := help

.PHONY: help
.PHONY: install install-yes dry-run packages configs ssh-key ssh-server zsh-default
.PHONY: lint test test-bash32 test-docker check test-all
.PHONY: sync-dotfiles

SHELL_FILES := setup.sh tests/*.sh
ARGS        ?=
DOTFILES    ?= ../dotfiles

# Flags that turn off every optional step; targets below re-enable one.
ONLY := --no-packages --no-configs --no-ssh-key --no-zsh-default

##@ Help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
	  /^[a-z0-9-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nExtra setup.sh flags: make install ARGS="--ssh-server"\n'

##@ Install

install: ## Full setup: packages, configs, SSH key + zsh prompts
	./setup.sh $(ARGS)

install-yes: ## Full setup without prompts (no SSH key, shell unchanged)
	./setup.sh --yes $(ARGS)

dry-run: ## Show what install would do, change nothing
	./setup.sh --dry-run $(ARGS)

packages: ## Install packages only
	./setup.sh --no-configs --no-ssh-key --no-zsh-default $(ARGS)

configs: ## Install configs only (tmux, nano, zsh, aliases), with backups
	./setup.sh --no-packages --no-ssh-key --no-zsh-default $(ARGS)

ssh-key: ## Create an ed25519 SSH key if none exists
	./setup.sh $(ONLY) --ssh-key $(ARGS)

ssh-server: ## Install the OpenSSH server and enable sshd (macOS: Remote Login)
	./setup.sh --no-configs --no-ssh-key --no-zsh-default --ssh-server $(ARGS)

zsh-default: ## Make zsh the login shell
	./setup.sh $(ONLY) --zsh-default $(ARGS)

##@ Test

lint: ## shellcheck all scripts
	shellcheck -x $(SHELL_FILES)
	shellcheck -s bash configs/bash_aliases

test: ## Unit tests (no root, no containers)
	bash tests/test_setup.sh

test-bash32: ## Unit tests + macOS dry-run under bash 3.2 (the macOS system bash)
	docker run --rm --user 1000 -e HOME=/tmp/h -v "$(CURDIR):/src:ro" bash:3.2 \
	  bash -c 'mkdir -p /tmp/h && bash /src/tests/test_setup.sh && UNAME_S=Darwin /src/setup.sh --dry-run'

test-docker: ## Real setup.sh run in Arch/Ubuntu/Debian/Fedora/Rocky/Alma containers
	bash tests/docker_matrix.sh

check: lint test ## lint + unit tests (fast)

test-all: lint test test-bash32 test-docker ## Every test, including containers

##@ Maintenance

sync-dotfiles: ## Copy tmux.conf + zshrc from DOTFILES=../dotfiles, keep the alias block
	cp "$(DOTFILES)/dot_tmux.conf" configs/tmux.conf
	{ cat "$(DOTFILES)/dot_zshrc"; echo; sed -n '/^# Load custom aliases in Zsh/,$$p' configs/zshrc; } > configs/zshrc.new
	mv configs/zshrc.new configs/zshrc
	git --no-pager diff --stat -- configs/
