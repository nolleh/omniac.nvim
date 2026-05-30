# Protocol TODO

This file tracks what is already working and what still needs to be implemented for a broader ACP-compatible client.

## Working today

- `stdio` transport for local subprocesses
- `initialize` / `initialized`
- `session/new`
- `session/prompt`
- `session/started`
- `session/update`
- `session/completed`
- `session/error`
- basic `session/request_permission` handling
- prompt construction from visual selection and file mentions
- native Neovim diff UI for reviewing edits
- save-back from diff buffers into the target file

## Remaining ACP work

- confirm the exact ACP schema for each supported agent and keep per-agent adapters isolated
- map all permission / approval request types to a real UI instead of auto-accepting
- support more `session/update` variants beyond the current text-oriented extraction
- support structured tool calls and tool results
- support file editing / patch flows through ACP-native events
- support richer session lifecycle events, including restart / resume / fork if required by agents
- verify remote-agent transports such as HTTP or WebSocket when needed
- add explicit error handling and retry behavior for session startup and prompt submission
- add integration tests against `codex-acp` and at least one additional ACP agent

## Backend split to keep

- `transport/` should remain transport-only
- `backend/acp.lua` should own ACP session flow
- future agent-specific behavior should live in separate backend modules, not in the transport layer

