# Protocol TODO

ACP reference: https://agentclientprotocol.com/protocol/v1/overview

This file tracks what is already working and what still needs to be implemented for a broader ACP-compatible client. The sections below follow the ACP v1 documentation sidebar.

Checked items describe the supported scope, not universal compatibility with every agent. Live Codex checks and mocked protocol tests are distinguished below from additional-agent validation. Unchecked expansion items are follow-up work unless selected for the release scope.

## Overview

- [x] Speak JSON-RPC-style request / response / notification messages over the active transport.
- [x] Treat JSON null object fields as absent while preserving null response completion and array positions.
- [x] Keep ACP session flow in `lua/omniac/backend/acp.lua`.
- [x] Keep process framing and subprocess communication in `lua/omniac/transport/`.
- [x] Write protocol logs when debug mode is enabled.
- [x] Review compatibility differences for Claude, Gemini, Copilot, and OpenCode and add common handling for the identified gaps: JSON null fields, replacement-edit inputs, partial usage updates, and legacy model selection. This code-level review does not establish live compatibility with every agent.
- [x] Add explicit resend / restore behavior for failed prompt submission.
- [x] Recover from failed session startup by allowing another session selection through `/resume`, while preventing prompts on the failed session.
- [x] Add integration tests against `codex-acp` and at least one additional ACP agent (Copilot).
- [ ] Run the live Codex integration suite as release validation; interactive checks do not replace this suite.
- [ ] Run the existing live Copilot suite when credentials and usage budget are available, and record its tested version and result separately.

## Initialization

- [x] Send `initialize` with `protocolVersion`, `clientInfo`, and `clientCapabilities`.
- [x] Advertise client-side file-system read/write and plan display support by default; keep client-provided terminal access disabled.
- [x] Keep ACP initialization and session startup in the ACP client layer.
- [x] Persist and use negotiated agent capabilities from the `initialize` response.
- [x] Validate protocol-version compatibility before continuing session startup.

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
- [x] Queue prompts with `Tab` during an active turn and send them in order after completion; manually verified selected-code attachments survive queued delivery.
- [x] Negotiate the `_session/steering` extension for immediate mid-turn messages with `Enter`; manually verified selected-code attachments arrive during an active Codex turn. Unsupported agents retain the draft and can use the queue.

## Content

- [x] Send basic text content items in prompts.
- [x] Send image content items from clipboard paste when the agent advertises `promptCapabilities.image`.
- [x] Send visual selections as embedded resource content when the agent advertises `promptCapabilities.embeddedContext`.
- [x] Send resource links for clean on-disk current-buffer references.
- [x] Extract text from common ACP and agent-specific content shapes.
- [x] Manually verify mixed selected-code, file-reference, image, and text input preserves attachment order and surrounding text.
- [x] Display replayed user images as `[Image attachment]`, including chunked inline image data links, without changing the original image payload.
- [ ] Support remaining non-text content blocks, including audio, intentionally.
- [x] Render user and agent messages separately and show recognized thought titles in the activity bar.
- [ ] Expand thought-content display beyond the recognized activity-title format if needed.
- [ ] Preserve structured content metadata needed for later actions.

## Tool Calls

- [x] Track `tool_call` and `tool_call_update` session updates.
- [x] Show compact tool activity in the UI.
- [x] Track edit tool calls by `toolCallId`.
- [x] Handle completed and failed edit tool-call updates.
- [x] Render known tool-call progress in activity and completed text results in chat, with Bash command blocks, ANSI styling, exit status, and expandable output.
- [ ] Add dedicated displays for additional structured result types beyond the currently recognized text, terminal metadata, and edit content.
- [x] Show permission details, including additional `rawInput` fields, and offer the agent's advertised permission choices when no diff is available.
- [ ] Map every remaining permission / approval request type to an intentional UI choice instead of fallback behavior.

## File System

- [x] Detect ACP edit updates containing `path`, `oldText`, and `newText`.
- [x] Open native Neovim diff review UI for edit permission diffs.
- [x] Treat completed agent-owned edit updates as review metadata without reapplying them to disk.
- [x] Support save-back from `:OmniacDiff` buffers into the target file.
- [x] Complete async approval through `:OmniacDiffAccept` and `:OmniacDiffDeny`.
- [x] Support ACP-native `fs/read_text_file`.
- [x] Support ACP-native `fs/write_text_file`.
- [x] Review each file in a multi-file edit permission before responding to the agent.
- [x] Build edit reviews from ACP-native `path` / `oldText` / `newText` content. For replacement-style `rawInput`, construct a full-file preview only when the target text matches unambiguously or explicit replace-all is requested; otherwise retain the permission-choice fallback. The current review path does not use a unified-patch parser.

## Terminals

- [x] Surface known command / terminal-like tool activity summaries when included in session updates.
- [x] Close v1 client-provided `terminal/*` support as not implemented.
  Agents can run commands in their own environment, and ACP v2 removes these methods.
  Keep the client terminal capability disabled.

## Agent Plan

- [x] Handle plan updates from `session/update`, replacing the full plan on each update.
- [x] Advertise plan support and handle `plan_update` documents and `plan_removed` alongside legacy `plan` updates.
- [x] Render plan progress and the current step alongside tool activity in the activity UI.
- [x] Expand or collapse the activity plan with `Ctrl-P`, with wrapped items and scrolling for longer lists.
- [x] Preserve the latest plan in one chat notice per turn, marking completed steps and reporting cancellation / turn failure without inventing failed step statuses.
- [x] Manually verify plan progress against live Codex with a temporary three-step task, including completion and cleanup.
- [ ] Verify plan rendering against additional live agents when available; Codex verification does not imply all-agent coverage.

## Session Modes

- [x] Configure an initial `agent.mode_id`.
- [x] Send `session/set_mode` after session creation when a mode id is configured.
- [x] Render available modes from session metadata and config options.
- [x] Let users switch modes during an active session with `/mode`.
- [x] Handle mode-change notifications from `session/update`.

## Session Config Options

- [x] Read advertised session config options from session metadata and update notifications.
- [x] Fall back to advertised legacy `models` metadata and `session/set_model` when model config options are unavailable.
- [x] Render model and mode selectors, collaboration mode, and recognized reasoning-effort values in the UI.
- [x] Send model, mode, and collaboration selections with `session/set_config_option` when advertised.
- [ ] Support selecting other advertised config options.

## Slash Commands

- [x] Handle available slash-command updates.
- [x] Render slash-command completion in the input UI.
- [x] Send slash-command text through the normal ACP `session/prompt` request shape.

## Extensibility

- [x] Keep internal client events under `omniac/*` and transport diagnostics under `_transport/*`.
- [x] Preserve debug logging for unknown request / notification shapes.
- [x] Handle the known metadata used for terminal output/exit, edit operation kinds, and negotiated Codex steering lifecycle.
- [ ] Define preservation and behavior for additional `_meta` fields as their supported use cases are added.
- [ ] Define a clear policy for custom agent methods prefixed with `_`.

## Transports

- [x] Support local subprocess stdio transport.
- [x] Parse newline-delimited JSON frames.
- [x] Dispatch requests, responses, and notifications to separate handlers.
- [x] Reply to agent-initiated requests.
- [x] Handle process stderr and exit notifications.
- [ ] Verify remote-agent transports such as HTTP or WebSocket when needed.
- [x] Add transport-level timeout handling for pending requests.

## Schema

- [x] Use camelCase for ACP request fields currently sent by the backend.
- [x] Keep compatibility extraction for snake_case agent response fields.
- [ ] Generate or validate Lua-side protocol shapes from the official ACP schema.
- [x] Add focused regression coverage for session lifecycle, prompt queue/steering, plans, known tool output, file operations, approvals, and the identified compatibility cases.
- [ ] Extend protocol-shape coverage as new methods and content variants are supported; the existing tests do not establish exhaustive schema conformance.
