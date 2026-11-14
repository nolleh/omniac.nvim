# Troubleshooting

## A prompt failed

The activity bar offers `r` to resend, `e` to restore input, and `d` to dismiss in Omniac normal mode. Check whether the agent already handled the request before resending. A failed prompt pauses queued messages until the failure is resolved.

Restoring keeps attachments with the draft and requires an empty input. If the input already contains text, clear it before restoring.

## A session will not open

Use `/resume` or `:OmniacSession` to choose another session. Prompts cannot be sent to a failed session.

For an unexpectedly empty session list in a symlinked workspace, try the real path in `agent.cwd`. On macOS, for example, `/tmp/project` may resolve to `/private/tmp/project`; an agent can filter session history by the canonical path.

## An agent feature is unavailable

Install and authenticate the configured CLI separately. Images, embedded context, modes, model selection, loading/resuming sessions, and immediate mid-turn messages depend on its capabilities. Use `Tab` to queue a message if immediate delivery is unavailable.

## Markdown or command highlighting is missing

Check that `render-markdown.nvim` is loaded and Treesitter parsers for `markdown`, `markdown_inline`, and `bash` are available. Chat and permission buffers use `omniac` and `omniac-permission` filetypes, connected to Markdown rendering without triggering normal Markdown document hooks.

## Debug logging

Enable logs for diagnosis:

```lua
require("omniac").setup({
  debug = true,
  logs = { dir = "logs" },
})
```

`:OmniacDebug` shows transport diagnostics. `acp-*.jsonl` records outgoing requests/notifications, agent responses, incoming requests/notifications, and client replies. This includes prompt contents, attachments, tool output, and cancellation traffic; inspect the contents before sharing logs.
