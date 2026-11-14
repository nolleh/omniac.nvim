# Change review

## Approve proposed edits

ACP edit permission requests open native Neovim diff reviews when proposed contents are available. Review every file in a multi-file request before approving. Use `<leader>aa` / `<leader>ad` or `:OmniacDiffAccept` / `:OmniacDiffDeny`.

For replacement-style edit inputs, Omniac builds a full-file preview when the old text matches unambiguously or replace-all is explicit. If no usable diff is available, the permission dialog shows request details and the agent's advertised choices.

You can make small adjustments in the proposed diff buffer. Omniac captures the reviewed contents, rejects the original batch, and sends a follow-up after that turn finishes. A matching follow-up edit is approved without reopening the review; changed proposals require review again. Accepting an adjusted proposal does not write the target file directly.

## Browse applied changes

`/changes` reviews the latest turn; `/changes session` reviews the current session. `:OmniacChanges [turn|session]` opens Telescope with a preview when available, otherwise a built-in dialog.

- `Enter` opens a full diff review.
- `Ctrl-e` opens the file at its first changed line.
- Closing a full preview returns to the same list and selection.

When a change summary is visible, `t` opens the latest turn and `s` opens session changes from any Omniac window except input. Change history is read-only; adjusted approvals happen in the permission flow above.

## Tracking scope

History includes ACP edits and client-mediated writes regardless of approval. Changes without a reported diff are also captured from disk around agent edit or terminal execution.

Workspace comparisons cover text files under `agent.cwd`. Existing changes and saves outside execution windows are excluded. Concurrent external writes during an agent command cannot be distinguished from agent writes. Git-ignored files, binary files, and files larger than 2 MiB are excluded. Without Git, text files under `agent.cwd` are scanned directly.

Change history is in memory and starts fresh after load, resume, or reconnect. Use `git diff` as the source of truth for the working tree.
