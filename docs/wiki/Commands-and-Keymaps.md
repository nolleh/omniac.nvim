# Commands and keymaps

## Default editor mappings

| Key | Action |
| --- | --- |
| `<leader>ac` | Toggle Omniac |
| `<leader>af` | Open Omniac or focus its input |
| `<leader>ar` | Select a session |
| `<leader>am` | Select a model |
| `<leader>aM` | Select a session mode |
| `<leader>ab` | Attach the current source buffer |
| `<leader>as` in visual mode | Attach selected source lines |
| `<leader>as` in a supported file tree | Attach selected paths |
| `<leader>aa` / `<leader>ad` | Accept / deny a diff review |

Existing mappings are preserved. See [Configuration](Configuration.md) to customize or disable defaults.

## Inside Omniac

| Key | Action |
| --- | --- |
| `Enter` in input | Send; during a turn, send immediately if steering is supported |
| `Tab` in input | Complete a slash command first, or queue the next prompt while working |
| `Ctrl-n` / `Ctrl-p` in input | Select the next / previous suggestion for `/` commands, `$` skills, or `@` paths; `Tab` or `Enter` accepts the selected candidate |
| `Ctrl-V` in input | Attach a clipboard image when supported; otherwise paste text |
| Up / Down in empty input | Browse prompt history until you edit recalled text |
| `Ctrl-c` in input | Clear the draft and pending attachments |
| `Esc` in normal-mode input | Request cancellation of the active turn |
| `Shift-Tab` | Toggle advertised default/plan collaboration modes |
| `Ctrl-k` / `Ctrl-j` | Move between Omniac windows in normal or insert mode |
| `Ctrl-P` | Expand or collapse the activity plan when input suggestions are inactive |
| `Ctrl-T` | Expand or collapse the tool result under the cursor |
| `Enter` on a Mermaid block in normal-mode chat | Open the diagram viewer |
| `t` / `s` in normal mode, while a change summary is shown | Review the latest turn / entire session from the conversation, activity, status, or pinned welcome card |

Transient UI handles its own closing behavior. Expanded plans add the activity bar to window navigation; otherwise navigation skips activity and status. The welcome card is skipped while hidden.

The diagram viewer opens in a large floating window with filetype `omniac-diagram` and initially fits the whole image. Images are centered with padding on all sides, including while zoomed. Its mappings are local to that buffer; chat image sizing is unaffected. It requires the same Snacks image support as inline Mermaid rendering.

| Viewer key | Action |
| --- | --- |
| `+` / `=` / mouse wheel up | Zoom in around the visible center |
| `-` / mouse wheel down | Zoom out |
| `h j k l` / arrow keys | Move the visible area left, down, up, or right |
| `f` | Fit the entire diagram |
| `w` | Fit the width and read a tall diagram by moving down |
| `1` | Reset to the image's native size |
| `q` / `Esc` | Close and return to chat |

The title shows the current zoom percentage. Zoom is capped at 800%; movement stops at the image edges. Resizing Neovim refits the image in fit modes and preserves the scale in manual mode. Leaving the viewer or closing its chat window also closes the viewer.

## Chat commands

| Command | Action |
| --- | --- |
| `/resume` | Open session selection |
| `/clear` | Start a fresh session on the current connection |
| `/model [model]` | Select or change the model |
| `/mode [id]` | Select or change the session mode |
| `/changes [session]` | Review changes in the latest turn or current session |

Advertised agent slash commands are completed in the input and forwarded while idle. During an active turn, Enter rejects them with an explanation and preserves the draft for retry after finishing or cancelling the turn. They are not sent as steering messages or automatically queued. This also applies while a steering acknowledgment or a steering-created turn is outstanding. Command names are matched against the agent's current advertisement, including punctuation such as `:`. Unadvertised slash-prefixed text, file paths, and `$skill` prompts keep their normal steering behavior.

The current Codex ACP adapter routes every agent slash command through `session/prompt`, which replaces its active request tracking even for read-only commands. Consequently commands such as `/plan`, `/mcp`, `/skills`, `/status`, `/review`, `/review-branch`, `/review-commit`, `/compact`, `/goal`, `/rename`, and `/logout` require an idle session when advertised. Newly advertised commands use the same guard; Omniac does not duplicate the agent's command validation while idle, and agent errors are displayed normally.

Omniac's `/changes`, `/model`, `/mode`, and `/exit` use their dedicated local handlers during a turn. `/clear` and `/resume` require the turn to finish or be cancelled and preserve rejected input. The guard for agent commands is stricter than Codex CLI's command policy because ACP does not expose a separate command execution request.

## Neovim commands

| Command | Action |
| --- | --- |
| `:Omniac` / `:OmniacFocus` | Toggle Omniac / open and focus it |
| `:OmniacConnect` / `:OmniacDisconnect` | Connect / disconnect the configured agent |
| `:OmniacExit` | Close the Omniac UI |
| `:OmniacSession` | Select a session, connecting if necessary |
| `:OmniacModel [model]` / `:OmniacMode [id]` | Select or change the model / mode |
| `:OmniacAsk [text]` | Send a prompt to the connected agent |
| `:OmniacAskFiles [paths]` | Send file mentions; paths are separated by commas or whitespace |
| `:'<,'>OmniacReference` | Attach the selected lines of the source buffer |
| `:OmniacReferenceBuffer` | Attach the current source buffer |
| `:OmniacTreeAdd` | Attach selected paths from a supported file tree |
| `:OmniacChanges [turn\|session]` | Open the change browser |
| `:OmniacDiff {path}` | Open a file diff review |
| `:OmniacDiffAccept` / `:OmniacDiffDeny` | Accept / deny the current diff |
| `:OmniacResize {width}` | Resize the side UI, e.g. `72`, `0.35`, or `35%` |
| `:OmniacDebug` | Inspect the debug log when debugging is enabled |
