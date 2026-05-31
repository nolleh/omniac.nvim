# Protocol TODO

This file tracks what is already working and what still needs to be implemented for a broader ACP-compatible client.

## Working today

- `stdio` transport for local subprocesses
- backend auto-selection between `codex app-server` and `codex-acp`
- `initialize` / `initialized`
- `session/new`
- `session/prompt`
- `session/started`
- `session/update`
- `session/completed`
- `session/error`
- ACP `session/request_permission` handling through a Neovim review UI
- Codex app-server `thread/start` / `turn/start` startup and prompt flow
- Codex app-server response streaming for agent message events
- Codex app-server file-change, patch, and command approval review for known request shapes
- basic handling for Codex permission, command, tool-input, and tool-call requests
- prompt construction from visual selection and file mentions
- `:Omniac` chat, activity, input, and status UI buffers
- native Neovim diff UI for reviewing edits
- save-back from `:OmniacDiff` buffers into the target file
- async approval completion through `:OmniacDiffAccept` and `:OmniacDiffDeny`

## Remaining ACP work

- confirm the exact ACP schema for each supported agent and keep per-agent adapters isolated
- map every remaining permission / approval request type to an intentional UI choice instead of fallback auto-accept / first-option behavior
- support more `session/update` variants beyond the current text-oriented extraction, including non-message updates
- support structured tool calls and tool results
- support ACP-native file editing / patch flows rather than relying on generic permission review shapes
- support richer session lifecycle events, including restart / resume / fork if required by agents
- support cancelling active turns from the UI
- support multi-file approval reviews instead of showing only the first recognized change
- replace the lightweight unified-diff preview parser with a real patch parser or ACP-native edit representation
- verify remote-agent transports such as HTTP or WebSocket when needed
- add explicit retry / recovery behavior for failed session startup and prompt submission
- add integration tests against `codex-acp` and at least one additional ACP agent

## Backend split to keep

- `lua/omniac/transport/` should remain transport-only
- `lua/omniac/backend/acp.lua` should own ACP session flow
- future agent-specific behavior should live in separate backend modules, not in the transport layer
