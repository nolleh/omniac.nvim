# omniac.nvim

Neovim plugin for ACP-compatible agents and agentic coding workflows.

## Features

- `:OmniacConnect` starts the configured subprocess
- `:Omniac` opens a Neovim chat/input/status UI
- `:OmniacAsk` sends the built prompt through the active backend when connected
- visual selections can be included in prompts
- file mentions can be formatted into prompts
- incoming JSONL messages are parsed, streamed into the UI, and shown with `vim.notify`
- ACP permission requests and known file-change approval requests open a native diff review UI
- some non-file request types still use conservative placeholder responses until richer UI support exists

## Architecture

- `lua/omniac/selection.lua` collects the active visual range and text
- `lua/omniac/mentions.lua` formats file references for prompts
- `lua/omniac/diff.lua` manages buffers and accepts user edits
- `lua/omniac/transport/` isolates ACP process communication

## Dev

Start Neovim with `scripts/dev.lua` to load this plugin with the default Codex command already configured.

## Protocol TODO

See [docs/PROTOCOL_TODO.md](docs/PROTOCOL_TODO.md) for the current ACP implementation scope and remaining work.




