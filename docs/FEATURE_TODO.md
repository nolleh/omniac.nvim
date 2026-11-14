# Feature TODO

This file tracks Omniac-facing product and interaction work that is independent from ACP protocol compatibility.

## Next Release Priorities

Work through these in order; completed protocol features alone do not establish release readiness.

1. **Release validation:** run live Codex and Copilot integration tests, then verify install, connect, prompt, cancel, approval, session selection, and reconnect manually. Include live verification of the implemented agent plan display, which preserves completed and interrupted plans in chat.

Input popup and focus interference has been resolved; the completed interaction-stability work is tracked under UX Safety below.

## Input Experience

- [x] Show ACP context-window usage as a percentage capsule in the input status bar.
- [x] Add a code-block handoff flow from visual mode into `omniac` input so selected code can be forwarded as reference context without manual copy / paste.
- [x] Start input history with Up / Down when empty, keep traversing until the user edits the recalled text.
- [x] Clear the current input and pending references with `Ctrl-c`.
- [x] Add a direct model-selector command / keymap so model selection does not require entering `/model` in chat.

## Session Workflow

- [x] Open the session selector with `:OmniacSession` while disconnected, using the agent's advertised session list and load / resume support.
- [x] Add `/clear` to start a fresh ACP session while keeping the current connection.
- [x] Recover from failed session startup through session selection: block prompts on the failed session and allow opening another session through `/resume`. Verified manually; prompt resend / restore is also available.

Agent-specific authentication guidance and protocol authentication support remain follow-up work in Protocol TODO rather than a next-release blocker.

## UX Safety

- [x] Prevent ambient floating windows opened by normal typing, completion, or file navigation from interrupting the Omniac experience.
- [x] Make `Esc` behavior context-aware so it closes transient UI without accidentally stopping an active chat turn.
- [x] Audit keymaps and popup handlers that can steal focus while the input is active.

## Prompt Context

- [x] Preserve the source path, line range, filetype, modified state, and captured text when forwarding visual selections.
- [x] Send selected code as ACP embedded context when advertised, with a text fallback for other agents.
- [x] Add the current buffer as a pending prompt reference, linking clean on-disk files and preserving modified buffer contents.
- [x] Add file-tree integrations that can attach selected paths as prompt references.
- [ ] Define the exact prompt shape for file references and other mixed text-plus-context input.
- [ ] Verify the input pipeline still behaves predictably when the user is already in `omniac://input`.

## Change Review

- [x] Track ACP edits and client-mediated file writes by turn and session, with a read-only review browser.
- [x] Render multiline activity messages safely without disrupting the input layout.

### Modified Approval Follow-up

Let the user make small, quick adjustments directly in the Neovim diff and approve that adjusted version in the same review flow. ACP permission responses select an option; they do not carry the user's replacement file contents. Treat the follow-up as an internal continuation of that approval, without a separate `/changes` command. The existing `/changes` views remain read-only history.

- [x] Track text edits in the proposed diff buffer through Neovim's `on_lines` callback. An untouched approval uses the normal ACP permission response; any edited approval uses the follow-up flow, including an edit later undone.
- [x] For an edited approval, capture the final text and path, reject the original ACP permission request, and explain in chat/activity that the user's small adjustments will be applied after the current turn completes. Do not present this as a failed user action.
- [x] Wait for the corresponding turn to finish before sending a new prompt with the proposal, the user's adjusted content, and the target path. Do not start another ACP prompt while the permission request or original turn is still active.
- [x] During that follow-up turn, approve an edit without reopening the diff only when its path and proposed text exactly match the saved user adjustment and the current file content matches the edit's old text. Require normal review when comparison is unavailable or differs; consume each match once.
- [x] Capture the adjusted content before closing the review buffer; do not write it to the target file as a side effect of accepting the diff. Let the follow-up turn apply the patch through the agent's normal edit flow.
- [x] Handle multiple edited approvals in one turn without dropping or duplicating content, and clear queued follow-ups on disconnect, load, resume, or session replacement.
- [x] Report when the follow-up prompt starts and when it finishes, including any failure, so the user knows when the modified approval process is complete.
- [x] Add regression tests for unchanged approval, edited approval, rejection response, deferred follow-up, multi-file edits, and connection reset.
