#!/usr/bin/env bash

# Run the live ACP integration test separately from the ordinary Plenary suite.
cd "$(dirname "$0")" || exit 1

if [[ -z "${PLENARY_DIR:-}" ]]; then
	PLENARY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/plenary.nvim"
fi

if [[ ! -d "$PLENARY_DIR" ]]; then
	echo "Set PLENARY_DIR to an installed plenary.nvim checkout" >&2
	exit 1
fi

export PLENARY_DIR

nvim --headless -i NONE -u tests/minimal_init.lua \
	-c "lua require('plenary.test_harness').test_directory('tests/e2e', { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 240000 })"
