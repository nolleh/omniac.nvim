# Plans and tool output

## Execution plans

The activity area shows completed/total steps and the current step alongside tool activity. Press `Ctrl-P` in chat, input, activity, or status to expand or collapse the full plan without moving focus.

Expanded plans wrap long items and use at most a third of the screen. Use `Ctrl-k` / `Ctrl-j` to focus the expanded activity area and scroll longer lists. A plan entry updates in chat and remains after completion, cancellation, or failure.

Omniac displays legacy ACP plans and `plan_update` documents, including Markdown, checklists, and file references. Removed plans are handled through `plan_removed`; each document plan ID has an updating chat entry.

Plan visibility depends on the agent sending plan updates. Advertising client display support does not enable Codex's `update_plan` tool or require an agent to create a plan.

## Tool output

Commands render as Bash blocks. Output preserves ANSI colors and styles while hiding terminal control sequences. The original bytes remain in stored output and debug logs.

Results have a task title and a compact preview. Press `Ctrl-T` over a result to expand or collapse its command and output. Set `ui.tool_results` to `compact`, `all`, or `none`; failures remain visible. `ui.tool_result_max_lines` controls the preview length.

## Layout and welcome card

`Ctrl-k` / `Ctrl-j` moves between the welcome card, chat, and input in normal or insert mode. Hidden cards are skipped. The expanded plan activity area participates in navigation; collapsed activity and status bars are skipped.

The pinned welcome card reacts to cursor movement: nearby vertical movement makes the mascot hop, sideways movement pets it, and repeated pets make it briefly flee. These reactions leave normal movement keys intact. Configure `ui.mascot_follow_cursor`, `ui.mascot_motion`, or use `ui.welcome_card = "welcome_only"`.

`:OmniacResize` resizes the side UI as a body. Width accepts columns, a ratio, or a percentage; see [Configuration](Configuration.md).
