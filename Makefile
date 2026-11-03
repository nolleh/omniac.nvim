agent ?= codex
model ?=

PLENARY_DIR ?= $(if $(XDG_DATA_HOME),$(XDG_DATA_HOME),$(HOME)/.local/share)/nvim/lazy/plenary.nvim
copilot_model_arg := $(if $(strip $(model)),--model $(model) )
COPILOT_CMD ?= $(if $(shell command -v copilot 2>/dev/null),copilot $(copilot_model_arg)--acp --stdio,npx --yes @github/copilot $(copilot_model_arg)--acp --stdio)

agent_cmd.codex := codex-acp
agent_cmd.copilot := $(COPILOT_CMD)

e2e_dir.codex := tests/e2e/codex
e2e_dir.copilot := tests/e2e/copilot

.PHONY: help dev test e2e

help:
	@echo "make dev [agent=codex|copilot] [model=<copilot-model>]"
	@echo "                                 Open Omniac with a live ACP agent"
	@echo "make test                        Run mocked Plenary specs"
	@echo "make e2e [agent=codex|copilot]  Run live E2E (uses agent quota)"

dev:
	@test -n "$(agent_cmd.$(agent))" || { echo "Unsupported agent: $(agent)" >&2; exit 2; }
	@if [ -n "$(strip $(model))" ] && [ "$(agent)" != "copilot" ]; then echo "model= is only supported for agent=copilot" >&2; exit 2; fi
	ACPCLIENT_AGENT_CMD='$(agent_cmd.$(agent))' nvim -c "luafile dev-load.lua"

test:
	./test.sh

e2e:
	@test -n "$(e2e_dir.$(agent))" || { echo "Unsupported agent: $(agent)" >&2; exit 2; }
	@test -d "$(PLENARY_DIR)" || { echo "Set PLENARY_DIR to an installed plenary.nvim checkout" >&2; exit 1; }
	PLENARY_DIR='$(PLENARY_DIR)' nvim --headless -i NONE -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('$(e2e_dir.$(agent))', { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 240000 })"
