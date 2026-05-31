# omniac.nvim

Neovim plugin for ACP-compatible agents and agentic coding workflows.

## Scope

This repository starts with the smallest useful slice:

- ask with the current visual selection
- mention files in prompts
- show diffs in Neovim's native diff UI
- keep the transport layer separate so the agent backend can change later
- connect to an ACP-style/stdin-stdout agent process

## Architecture

- `lua/omniac/selection.lua` collects the active visual range and text
- `lua/omniac/mentions.lua` formats file references for prompts
- `lua/omniac/diff.lua` manages buffers and accepts user edits
- `lua/omniac/transport/` isolates ACP process communication

## ACP model

ACP usually runs the agent as a subprocess and communicates over stdio using JSON-RPC.
That means the editor is the UI, not the agent.

For local agents, the flow is typically:

`nvim -> omniac code -> agent subprocess`

The agent can then stream updates, request permissions, and ask for filesystem or terminal access through the protocol.

## What works now

- `:OmniacConnect` starts the configured subprocess
- `:OmniacAsk` sends the built prompt through the transport when connected
- incoming JSONL messages are parsed and shown with `vim.notify`
- request messages from the agent are surfaced to Neovim and currently auto-rejected unless a custom handler is added

## Dev

Start Neovim with `scripts/dev.lua` to load this plugin with the default Codex command already configured.

## Protocol TODO

See [docs/PROTOCOL_TODO.md](docs/PROTOCOL_TODO.md) for the current ACP implementation scope and remaining work.
