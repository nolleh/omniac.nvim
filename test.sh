#!/usr/bin/env bash

# Run the Plenary test suite in a minimal Neovim environment.

cd "$(dirname "$0")"

echo "=========================================="
echo " Running omniac.nvim Plenary tests"
echo "=========================================="

if [[ -z "${PLENARY_DIR:-}" ]]; then
	nvim_data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
	installed_plenary="$nvim_data_dir/lazy/plenary.nvim"

	if [[ -d "$installed_plenary" ]]; then
		PLENARY_DIR="$installed_plenary"
	else
		test_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omniac.nvim-test"
		PLENARY_DIR="$test_cache_dir/plenary.nvim"
		if [[ ! -d "$PLENARY_DIR" ]]; then
			mkdir -p "$test_cache_dir"
			git clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$PLENARY_DIR"
		fi
	fi
fi

export PLENARY_DIR

nvim --headless -i NONE -u tests/minimal_init.lua \
	-c "lua require('plenary.test_harness').test_directory('tests/spec', { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 120000 })"
