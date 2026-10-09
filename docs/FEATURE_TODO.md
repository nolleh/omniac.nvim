# Feature TODO

This file tracks Omniac-facing product and interaction work that is independent from ACP protocol compatibility.

## Input Experience

- [x] Show ACP context-window usage as a percentage capsule in the input status bar.
- [x] Add a code-block handoff flow from visual mode into `omniac` input so selected code can be forwarded as reference context without manual copy / paste.
- [ ] Let history navigation work with `Ctrl-n` / `Ctrl-p` only, instead of depending on the arrow keys.
- [ ] Add a direct model-selector command / keymap so model selection does not require entering `/model` in chat.

## Session Shortcuts

- [ ] Add a continue-latest-session shortcut that chooses the newest session for the current working directory and uses the agent's advertised load / resume capability.
- [ ] Fall back to the session selector when the latest session cannot be determined safely or cannot be loaded / resumed.

## UX Safety

- [ ] Prevent ambient floating windows opened by normal typing, completion, or file navigation from interrupting the Omniac experience.
- [x] Make `Esc` behavior context-aware so it closes transient UI without accidentally stopping an active chat turn.
- [ ] Audit keymaps and popup handlers that can steal focus while the input is active.

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

### Post-edit Approval

Add an optional approval workflow for changes that the agent has already applied to the working tree. This is distinct from ACP `session/request_permission`: pre-execution permission decides whether a proposed tool call may run, while post-edit approval decides whether an already-applied result should remain on disk.

- [ ] Keep the existing `/changes` and `/changes session` views read-only by default, and add an explicit entry point for post-edit approval (candidate: `/changes approve [session]`).
- [ ] At turn completion, build an approval queue from each path's first full `oldText` snapshot and final full `newText` snapshot, deduplicating repeated edits to the same path.
- [ ] Review multiple changed files sequentially and show a per-file decision state: pending, kept, reverted, skipped, or conflicted.
- [ ] Let the user keep or revert the current file, then move to the next pending file; add keep-all / revert-all actions only after every target passes the same safety checks.
- [ ] Keep “accept” non-destructive: it records that the current result is intentionally kept and must not write the file again.
- [ ] Allow “reject” to restore the recorded baseline only when the current disk content and any loaded buffer still match the recorded final snapshot. If the file changed again, has unsaved buffer edits, or no longer matches the tracked state, mark it conflicted and open a three-way/manual review instead of overwriting it.
- [ ] Handle operation-specific rollback safely: remove an added file only when its contents still match, restore a deleted file only when the path is still absent, and defer move/copy rollback until both source and destination snapshots are available.
- [ ] Never replay completed ACP edit notifications through the write path. They remain metadata used to construct the approval queue; all rollback writes must come from an explicit user decision and pass the conflict guard.
- [ ] Keep approval history connection-local, matching the current change tracker. Clear pending decisions after load, resume, or reconnect, and never infer approval state from replayed session history; `git diff` remains the source of truth across connections.
- [ ] Surface the final turn summary in chat/activity, including kept, reverted, skipped, and conflicted counts, without blocking the next prompt unless an explicit post-edit approval mode requests it.
- [ ] Add regression tests for repeated edits to one file, add/delete operations, loaded modified buffers, disk changes made after the turn, multi-file mixed decisions, reconnect/reset behavior, and the guarantee that accept never rewrites content.
