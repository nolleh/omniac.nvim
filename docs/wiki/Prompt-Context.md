# Prompt context

## Selected code

Select lines in a source buffer and press `<leader>as`, or run `:'<,'>OmniacReference`. Omniac captures the source path, line range, filetype, modified state, and selected text before opening the input.

Selected text includes unsaved edits. Agents advertising embedded context receive a resource block; other agents receive a text fallback.

## Current file and file-tree paths

Press `<leader>ab` or run `:OmniacReferenceBuffer` from a source buffer. By default this attaches a file link, including for modified buffers: the agent reads the on-disk file. Enable `references.include_modified_buffer = true` to send the full unsaved buffer contents when modified. Buffers without an on-disk file are skipped unless this option is enabled.

The command requires a source buffer. Running it inside `omniac://input` shows an explanatory warning instead of attaching the draft. `:OmniacReference` takes a source-buffer range, not a file-path argument.

In `nvim-tree`, `neo-tree`, `oil.nvim`, or `mini.files`, press `<leader>as` or run `:OmniacTreeAdd` to attach selected paths. Clean file references use resource links and retain requested line ranges.

## Images

Press `Ctrl-V` in the input to attach a PNG or JPEG from the macOS clipboard when the agent advertises image prompts. Otherwise it falls back to text paste.

The input shows attachment markers. File references, selected text, images, and surrounding text retain their order when sent. Restored conversation images appear as `[Image attachment]` instead of raw image data.

## Queue or send during a turn

While a prompt is running, `Tab` queues the draft after slash-command completion has been handled. Queued prompts appear in chat with a `Queued` marker and send in order when the active turn finishes. The same message loses its marker when sent. A failed prompt pauses the queue until resolved.

`Enter` sends immediately during a turn when the agent advertises steering. The message can influence the agent's next processing step. Unsupported agents leave the draft in place and suggest queueing with `Tab`. Rejected steering restores the draft if the input is empty.

Both paths keep the captured attachments with the message.

## Draft history

Up / Down in an empty input starts browsing submitted prompts. History navigation continues until you edit the recalled text. `Ctrl-c` clears the draft and pending references.
