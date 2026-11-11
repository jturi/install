# install — run `make` or `make help` to list every target.
#
# Extra setup.sh flags go in ARGS, for example:
#   make install ARGS="--ssh-server"
# Public targets carry a `## description`; `##@ Title` starts a help section.

.DEFAULT_GOAL := help

.PHONY: help
.PHONY: install install-yes dry-run select packages configs terminals ssh-key ssh-server zsh-default windows
.PHONY: lint test test-bash32 test-docker test-windows check test-all
.PHONY: sync-dotfiles

SHELL_FILES := setup.sh lib/*.sh tests/*.sh
PS1_FILES := setup.ps1 windows/lib.ps1 windows/menu.ps1 windows/steps/*.ps1 tests/test_windows.ps1 tests/check_ps1.ps1
ARGS        ?=
DOTFILES    ?= ../dotfiles

# Flags that turn off every optional step; targets below re-enable one.
ONLY := --no-packages --no-configs --no-terminal --no-ssh-key --no-zsh-default

##@ Help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
	  /^[a-z0-9-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nExtra setup.sh flags: make install ARGS="--ssh-server"\n'

##@ Install

install: ## Choose what to install in a menu, then install it
	./setup.sh $(ARGS)

install-yes: ## Full setup without prompts: saved selection, else defaults
	./setup.sh --yes $(ARGS)

dry-run: ## Show what install would do, change nothing
	./setup.sh --dry-run $(ARGS)

select: ## Choose and save a selection, install nothing
	./setup.sh --select $(ARGS)

packages: ## Install packages only
	./setup.sh --no-configs --no-terminal --no-ssh-key --no-zsh-default $(ARGS)

configs: ## Install configs only (tmux, nano, zsh, aliases), with backups
	./setup.sh --no-packages --no-terminal --no-ssh-key --no-zsh-default $(ARGS)

ssh-key: ## Create an ed25519 SSH key if none exists
	./setup.sh $(ONLY) --ssh-key $(ARGS)

ssh-server: ## Install the OpenSSH server and enable sshd (macOS: Remote Login)
	./setup.sh --no-configs --no-terminal --no-ssh-key --no-zsh-default --ssh-server $(ARGS)

terminals: ## Install kitty + Ghostty (WSL: also WezTerm via Scoop) and configs
	./setup.sh $(ONLY) --terminal $(ARGS)

zsh-default: ## Make zsh the login shell
	./setup.sh $(ONLY) --zsh-default $(ARGS)

##@ Test

lint: ## shellcheck all scripts
	shellcheck -x $(SHELL_FILES) configs/bin/*.sh
	@if command -v powershell.exe >/dev/null 2>&1; then \
	  check=$$(wslpath -w tests/check_ps1.ps1); \
	  for f in $(PS1_FILES); do w=$$(wslpath -w "$$f"); powershell.exe -NoProfile -File "$$check" "$$w" || exit 1; done; \
	else echo 'SKIP ps1 parse: no powershell.exe'; fi
	shellcheck -s bash configs/bash_aliases configs/bash_extras

test: ## Unit tests (no root, no containers)
	bash tests/test_setup.sh
	bash tests/test_repo.sh --self-test
	bash tests/test_repo.sh

test-bash32: ## Unit tests + macOS dry-run under bash 3.2 (the macOS system bash)
	docker run --rm --user 1000 -e HOME=/tmp/h -v "$(CURDIR):/src:ro" bash:3.2 \
	  bash -c 'mkdir -p /tmp/h && bash /src/tests/test_setup.sh && UNAME_S=Darwin /src/setup.sh --dry-run'

test-docker: ## Real setup.sh run in Arch/Ubuntu/Debian/Fedora/Rocky/Alma containers
	bash tests/docker_matrix.sh

test-windows: ## Run the PowerShell tests on Windows (needs powershell.exe), else a container
	@if command -v powershell.exe >/dev/null 2>&1; then \
	  w=$$(wslpath -w tests/test_windows.ps1 2>/dev/null || echo tests/test_windows.ps1); \
	  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$$w"; \
	else \
	  docker run --rm -v "$$(pwd)":/w -w /w -e USERPROFILE=/tmp/u -e HOME=/tmp/h -e TEMP=/tmp mcr.microsoft.com/powershell:7.4-alpine-3.20 pwsh -NoProfile -File tests/test_windows.ps1; \
	fi

windows: ## Run setup.ps1 from WSL (needs powershell.exe)
	@w=$$(wslpath -w setup.ps1); powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$$w" $(ARGS)

check: lint test ## lint + unit tests (fast)

test-all: lint test test-bash32 test-docker ## Every test, including containers

##@ Maintenance

sync-dotfiles: ## Copy tmux.conf + zshrc from DOTFILES=../dotfiles, keep the alias block
	cp "$(DOTFILES)/dot_tmux.conf" configs/tmux.conf
	{ cat "$(DOTFILES)/dot_zshrc"; echo; sed -n '/^# Load custom aliases in Zsh/,$$p' configs/zshrc; } > configs/zshrc.new
	mv configs/zshrc.new configs/zshrc
	git --no-pager diff --stat -- configs/
