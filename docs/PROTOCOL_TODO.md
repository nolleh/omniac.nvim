# Protocol TODO

ACP reference: https://agentclientprotocol.com/protocol/v1/overview

This file tracks what is already working and what still needs to be implemented for a broader ACP-compatible client. The sections below follow the ACP v1 documentation sidebar.

## Overview

- [x] Speak JSON-RPC-style request / response / notification messages over the active transport.
- [x] Keep ACP session flow in `lua/omniac/backend/acp.lua`.
- [x] Keep process framing and subprocess communication in `lua/omniac/transport/`.
- [x] Write protocol logs when debug mode is enabled.
- [ ] Confirm exact ACP schema details against each supported agent and isolate per-agent adapters.
- [ ] Add explicit retry / recovery behavior for failed session startup and prompt submission.
- [ ] Add integration tests against `codex-acp` and at least one additional ACP agent.

## Initialization

- [x] Send `initialize` with `protocolVersion`, `clientInfo`, and `clientCapabilities`.
- [x] Default ACP client capabilities to no client-side file-system or terminal access.
- [x] Keep ACP initialization and session startup in the ACP client layer.
- [ ] Persist and use negotiated agent capabilities from the `initialize` response.
- [ ] Validate protocol-version compatibility before continuing session startup.

## Authentication

- [ ] Support `authenticate` when required by an agent.
- [ ] Surface authentication failures in the UI with an actionable state.
- [ ] Support `logout` when advertised by agent capabilities.

## Session Setup

- [x] Create new sessions with `session/new`.
- [x] Pass `cwd` and configured MCP servers to `session/new`.
- [x] Store the returned `sessionId` for later requests.
- [x] Queue a prompt while startup is still creating the session, then flush it after the session is ready.
- [x] Support `session/load` for loading an existing session when advertised.
- [x] Support `session/resume` for reconnecting without history replay when advertised.
- [x] Support `session/list` for discovering existing sessions when advertised.
- [ ] Support richer lifecycle operations such as restart or fork if agents require them.

## Session List

- [x] Support listing available sessions if the protocol / agent exposes it.
- [x] Add a custom selector for choosing new, load, or resume startup behavior.

## Prompt Turn

- [x] Send user input through `session/prompt`.
- [x] Build text prompts from chat input, visual selection, current file context, and file mentions.
- [x] Show `omniac/prompt_started` as a working UI state.
- [x] Stream `agent_message_chunk` / `agentMessageChunk` updates into the chat UI.
- [x] Handle final agent message updates and non-streamed prompt responses.
- [x] Mark streamed responses complete after the prompt response / completion event.
- [x] Surface `session/error` and transport errors in the UI.
- [x] Support `session/cancel` from the UI for active turns.
- [x] Track ACP stop reasons from the `session/prompt` response.

## Content

- [x] Send basic text content items in prompts.
- [x] Send image content items from clipboard paste when the agent advertises `promptCapabilities.image`.
- [x] Send visual selections as embedded resource content when the agent advertises `promptCapabilities.embeddedContext`.
- [x] Send resource links for clean on-disk current-buffer references.
- [x] Extract text from common ACP and agent-specific content shapes.
- [ ] Support remaining non-text content blocks, including audio, intentionally.
- [ ] Render user, agent, and thought content distinctly when the update shape exposes them.
- [ ] Preserve structured content metadata needed for later actions.

## Tool Calls

- [x] Track `tool_call` and `tool_call_update` session updates.
- [x] Show compact tool activity in the UI.
- [x] Track edit tool calls by `toolCallId`.
- [x] Handle completed and failed edit tool-call updates.
- [ ] Render structured tool calls and tool results in the chat / activity UI.
- [ ] Map every remaining permission / approval request type to an intentional UI choice instead of fallback behavior.

## File System

- [x] Detect ACP edit updates containing `path`, `oldText`, and `newText`.
- [x] Open native Neovim diff review UI for edit permission diffs.
- [x] Apply completed file updates back to disk and loaded buffers.
- [x] Support save-back from `:OmniacDiff` buffers into the target file.
- [x] Complete async approval through `:OmniacDiffAccept` and `:OmniacDiffDeny`.
- [x] Support ACP-native `fs/read_text_file`.
- [x] Support ACP-native `fs/write_text_file`.
- [ ] Support multi-file approval reviews instead of showing only the first recognized change.
- [ ] Replace the lightweight unified-diff preview parser with a real patch parser or ACP-native edit representation.

## Terminals

- [x] Surface known command / terminal-like tool activity summaries when included in session updates.
- [ ] Advertise terminal capability only when real terminal methods are implemented.
- [ ] Support `terminal/create`.
- [ ] Support `terminal/output`.
- [ ] Support `terminal/release`.
- [ ] Support `terminal/wait_for_exit`.
- [ ] Support `terminal/kill`.

## Agent Plan

- [ ] Handle plan updates from `session/update`.
- [ ] Render active plan items in the activity UI.
- [ ] Reflect completed / failed plan steps without losing chat context.

## Session Modes

- [x] Configure an initial `agent.mode_id`.
- [x] Send `session/set_mode` after session creation when a mode id is configured.
- [ ] Render available modes from agent capabilities.
- [ ] Let users switch modes during an active session.
- [ ] Handle mode-change notifications from `session/update`.

## Session Config Options

- [ ] Read advertised session config options from initialization / session metadata.
- [ ] Render configurable options in the UI.
- [ ] Send selected config options with session creation or prompt requests.

## Slash Commands

- [x] Handle available slash-command updates.
- [x] Render slash-command completion in the input UI.
- [x] Send slash-command text through the normal ACP `session/prompt` request shape.

## Extensibility

- [x] Keep internal client events under `omniac/*` and transport diagnostics under `_transport/*`.
- [x] Preserve debug logging for unknown request / notification shapes.
- [ ] Support `_meta` fields deliberately where ACP defines them.
- [ ] Define a clear policy for custom agent methods prefixed with `_`.

## Transports

- [x] Support local subprocess stdio transport.
- [x] Parse newline-delimited JSON frames.
- [x] Dispatch requests, responses, and notifications to separate handlers.
- [x] Reply to agent-initiated requests.
- [x] Handle process stderr and exit notifications.
- [ ] Verify remote-agent transports such as HTTP or WebSocket when needed.
- [ ] Add transport-level timeout handling for pending requests.

## Schema

- [x] Use camelCase for ACP request fields currently sent by the backend.
- [x] Keep compatibility extraction for snake_case agent response fields.
- [ ] Generate or validate Lua-side protocol shapes from the official ACP schema.
- [ ] Add focused tests for each supported request, response, and notification shape.
