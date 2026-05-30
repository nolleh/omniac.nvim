# acpclient.nvim

Temporary working title for a Neovim plugin that talks to ACP-compatible agents.

## Scope

This repository starts with the smallest useful slice:

- ask with the current visual selection
- mention files in prompts
- show diffs in Neovim's native diff UI
- keep the transport layer separate so the agent backend can change later
- connect to an ACP-style/stdin-stdout agent process

## Architecture

- `lua/acpclient/selection.lua` collects selection text and range metadata
- `lua/acpclient/mentions.lua` formats file mentions for prompts
- `lua/acpclient/diff.lua` manages diff buffers and accepts user edits
- `lua/acpclient/transport/` isolates ACP process communication

## ACP model

ACP usually runs the agent as a subprocess and communicates over stdio using JSON-RPC.
That means the editor is the UI, not the agent.

For local agents, the flow is typically:

`nvim -> ACP client code -> agent subprocess`

The agent can then stream updates, request permissions, and ask for filesystem or terminal access through the protocol.

## What works now

- `:AcpClientConnect` starts the configured subprocess
- `:AcpClientAsk` sends the built prompt through the transport when connected
- incoming JSONL messages are parsed and shown with `vim.notify`
- request messages from the agent are surfaced to Neovim and currently auto-rejected unless a custom handler is added

## Dev

Start Neovim with `scripts/dev.lua` to load this plugin with the default Codex command already configured.

## Protocol TODO

See [docs/PROTOCOL_TODO.md](docs/PROTOCOL_TODO.md) for the current ACP implementation scope and remaining work.
