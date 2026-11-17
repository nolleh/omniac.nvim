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
| `Ctrl-V` in input | Attach a clipboard image when supported; otherwise paste text |
| Up / Down in empty input | Browse prompt history until you edit recalled text |
| `Ctrl-c` in input | Clear the draft and pending attachments |
| `Esc` in normal-mode input | Request cancellation of the active turn |
| `Shift-Tab` | Toggle advertised default/plan collaboration modes |
| `Ctrl-k` / `Ctrl-j` | Move between Omniac windows in normal or insert mode |
| `Ctrl-P` | Expand or collapse the activity plan |
| `Ctrl-T` | Expand or collapse the tool result under the cursor |
| `t` / `s` in normal mode, while a change summary is shown | Review the latest turn / entire session from the conversation, activity, status, or pinned welcome card |

Transient UI handles its own closing behavior. Expanded plans add the activity bar to window navigation; otherwise navigation skips activity and status. The welcome card is skipped while hidden.

## Chat commands

| Command | Action |
| --- | --- |
| `/resume` | Open session selection |
| `/clear` | Start a fresh session on the current connection |
| `/model [model]` | Select or change the model |
| `/mode [id]` | Select or change the session mode |
| `/changes [session]` | Review changes in the latest turn or current session |

Agent-provided slash commands are completed in the input and sent as prompts.

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
