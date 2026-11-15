# Main demo recording script

Target: a silent, captioned 60–90 second README video. The full take can be longer; trim waiting time while keeping the real interaction order. Agent timing, plan updates, and permission behavior require a live rehearsal.

## Prepare a take

From the repository root, in kitty:

```sh
python3 scripts/demo/prepare.py --launch
```

Omit `--launch` to create the project and print a launch command without opening Neovim. Each invocation creates a fresh temporary take and runs its existing tests. Keep the printed path for verification; preparation never resets or overwrites an earlier take. Temporary takes remain available until manually removed or cleaned by the OS.

The project contains an 11-line Python function/example and three small baseline tests. No packages, network access, or Git commit are needed to prepare it. A live take needs an installed, authenticated `codex-acp` and uses agent quota. Optional Markdown/Treesitter plugins are reused from the usual lazy.nvim paths, or from `OMNIAC_RENDER_MARKDOWN_PATH` and `OMNIAC_TREESITTER_PATH`; nothing is installed automatically.

The launcher uses this checkout with an isolated Neovim configuration and Space as leader. The editor opens in `taskboard/`, while the agent's `workspace-write` root is its empty sibling `agent-workspace/`. This follows the existing live adjusted-approval test's outside-workspace layout: proposed edits to the attached source should request permission. Do not move the source into the writable agent workspace or select an unrestricted mode for this take. The actual agent must still advertise edit diffs and mid-turn delivery; verify both in rehearsal.

## Before capture

1. Use a dedicated kitty window, approximately 160 columns × 42 rows, with legible text at the intended output size. Hide unrelated tabs, notifications, and private paths where possible.
2. Run `:OmniacConnect`, wait for the session to become ready, and confirm the mode is `workspace-write`. Leave authentication and connection waits out of the take.
3. Return focus to `task_summary.py`. Keep the source and conversation visible together; resize the window if review panes are too narrow.
4. In rehearsal, confirm that the edit opens an **Omniac permission** diff, not just an applied-change preview. Also confirm Enter delivers the second message during the active turn. If either fails, resolve the agent's capabilities or permissions before recording that feature.
5. Start the already-verified windowcapture setup against this kitty window. Hold a clean opening frame for two seconds. This document is the performance/caption script; it does not start a recorder or send keystrokes automatically.

## Exact prompt copy

Initial request, with the function attached as a selection:

> Improve this task summary. First outline a short plan and inspect the existing tests, then edit only task_summary.py. Show at most the first two titles and append "+N more" for the rest. Use "1 task" for a single task and "All clear." for an empty list. Keep the public function name. Use apply_patch for the edit so I can review the proposed diff; do not write through shell commands. Run the existing unittest suite afterward. Keep replies brief and in English. If an edit is rejected, stop without retrying.

Mid-turn message, sent with Enter while the agent is planning or reading tests:

> Keep the original task order and do not modify the input list.

Send this promptly after the first request. Do not wait until the permission dialog has taken focus. If the agent finishes too quickly or the message becomes a separate turn, rehearse a fresh take; do not caption it as mid-turn delivery.

## Shot-by-shot performance

Times describe the edited video, not fixed delays for driving a live agent.

| Target time | Action and evidence to keep visible | Caption |
| --- | --- | --- |
| 0–5 s | Show the small function and its four-title example. In Normal mode, use `4GV2j` to select lines 4–6, then Space `as` to attach them. Pause on the selection attachment. | Start with the code you're editing. |
| 5–15 s | Paste the initial request into Omniac input, pause long enough to read it, then press Enter. | Share context. Ask for a change. |
| 15–25 s | While work is active, use Space `af` if needed, type the mid-turn message, and press Enter. Keep the message and active status visible. Expand the plan with Ctrl-P if the agent publishes one and it fits. | Guide the agent while it works. |
| 25–45 s | Wait for the native permission diff. Show the proposed truncation and singular handling. In the editable proposed pane, find `All clear.` and replace only that string with `Nothing pending.`. Pause on the changed line. | Shape the proposal in Neovim. |
| 45–60 s | Run `:OmniacDiffAccept` (or Space `aa`). Keep the adjusted-approval follow-up visible, then let the agent finish. Review any materially different follow-up proposal if requested. | Approve the version you reviewed. |
| 60–80 s | In input, send `/changes session`. Select `task_summary.py` and press Enter. Show the final diff including `Nothing pending.`, preserved order, and the shortened summary. | Review what changed. |
| 80–90 s | Close the preview with its normal close action, then hold the conversation and completion summary for two seconds. | Your agent. Your editor. One workflow. |

Use `:OmniacReference` on the visual range if your terminal does not deliver the leader mapping. The launcher does not change user configuration. If source focus is lost, select the source window before entering `4G`.

**Review behavior:** `:w` in the permission buffer also accepts the proposal. Use `:OmniacDiffAccept` once the wording is ready; do not save early merely to stage the adjustment. An adjusted approval rejects the original edit and sends a follow-up after the turn ends. The acceptance action itself does not directly write the source file. Keep enough of the real follow-up visible to explain the transition.

## Verify and finish

After completion, run the `verify.py` command printed by the launcher in another terminal, using that take's `taskboard/` path:

```sh
python3 -B scripts/demo/verify.py /absolute/path/to/take/taskboard
```

It runs the existing tests and checks the reviewed empty message, singular/plural wording, truncation, original order, and unchanged input list. Expected output includes:

```text
PASS: Nothing pending.
PASS: 1 task: Write docs
PASS: 2 tasks: Write docs, Fix tests
PASS: 4 tasks: Write docs, Fix tests, +2 more
Reviewed content is on disk; order and input are preserved.
```

The baseline project intentionally fails the new-behavior checks until the real reviewed edit lands. Never patch the final source manually to make the recording pass. If a take fails, keep it for diagnosis and prepare a fresh one.

Stop capture after the closing hold. Retain the raw recording and export a cropped, readable MP4 for review. Only replace the main README placeholder after the resulting video has been inspected. The other four media placeholders have their own shot ideas in [README.md](README.md).
