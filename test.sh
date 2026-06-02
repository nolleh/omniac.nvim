#!/usr/bin/env bash

# Run headless unit tests

cd "$(dirname "$0")"

echo "=========================================="
echo " Running omniac.nvim headless tests"
echo "=========================================="

nvim --headless -u NONE -i NONE -l tests/headless.lua
