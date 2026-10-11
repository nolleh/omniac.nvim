# omniac.nvim

Neovim plugin for ACP-compatible agents and agentic coding workflows.

## Installation

Install an ACP agent first. The default command is `codex-acp`:

```sh
npm install -g @agentclientprotocol/codex-acp
codex-acp login
```

You can use another ACP-compatible agent by setting `agent.cmd` to its executable and arguments.

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nolleh/omniac.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "MeanderingProgrammer/render-markdown.nvim",
  },
  opts = {
    keymaps = {
      open = "<leader>ac",
      focus = "<leader>af",
      session = "<leader>ar",
      buffer = "<leader>ab",
      reference = "<leader>as",
      tree_add = "<leader>as",
      diff_accept = "<leader>aa",
      diff_deny = "<leader>ad",
    },
  },
}
```

Omniac registers these defaults when `setup()` runs. They follow the corresponding `claudecode.nvim` keys, skip keys that are already mapped, and can be changed by setting a different value or disabled per action with `false`. Set `keymaps = false` to disable all Omniac mappings. `<leader>as` sends a visual selection, and in supported file-tree buffers it adds the file under the cursor (`nvim-tree`, `neo-tree`, `oil.nvim`, or `mini.files`). Session selection is available through `<leader>ar`, and model selection is available with `/model` in the chat.

With options:

```lua
{
  "nolleh/omniac.nvim",
  opts = {
    agent = {
      cmd = { "codex-acp" },
      mode_id = "read-only",
    },
  },
}
```

Customize the UI width and diff review behavior:

```lua
{
  "nolleh/omniac.nvim",
  opts = {
    ui = {
      chat_width = 72,
      welcome_card = "welcome_only", -- reclaim chat space after the first message
      diff_separate_tab = true,
      diff_title = "Omniac Review",
    },
  },
}
```

Use a project-local working directory and enable debug logging:

```lua
{
  "nolleh/omniac.nvim",
  opts = {
    debug = true,
    agent = {
      cwd = vim.fn.getcwd(),
    },
  },
}
```

### Options

| Option                                 | Default           | Description                                                                           |
| -------------------------------------- | ----------------- | ------------------------------------------------------------------------------------- |
| `debug`                                | `false`           | Enables extra debug notifications and debug-log inspection.                           |
| `agent.cmd`                            | `{ "codex-acp" }` | ACP agent subprocess command.                                                         |
| `agent.args`                           | `{}`                        | Additional agent arguments.                                                           |
| `agent.env`                            | `{}`                        | Environment variables passed to the agent subprocess.                                 |
| `agent.cwd`                            | `nil`                       | Working directory for the agent subprocess.                                           |
| `agent.mode_id`                        | `"read-only"`               | Initial ACP agent mode ID; choose one advertised by the agent.                        |
| `agent.pty`                            | `false`                     | Runs the subprocess through a PTY when supported.                                     |
| `agent.session.action`                 | `"new"`                     | ACP session startup action: `"new"`, `"load"`, `"resume"`, or `"select"`.            |
| `agent.session.id`                     | `nil`                       | ACP session ID used when `agent.session.action` is `"load"` or `"resume"`.            |
| `agent.session_action`                 | `nil`                       | Backward-compatible alias for `agent.session.action`.                                 |
| `agent.session_id`                     | `nil`                       | Backward-compatible alias for `agent.session.id`.                                     |
| `session_selector`                     | `nil`                       | Callback used to select a session when `agent.session.action` is `"select"`.          |
| `mcpServers`                           | `{}`                        | MCP server configuration passed to ACP session creation, load, and resume requests.   |
| `additionalDirectories`                | `nil`                       | Extra directories passed to ACP sessions when the agent advertises support.            |
| `client.name`                          | `"omniac.nvim"`             | Client name sent during initialization.                                               |
| `client.title`                         | `"omniac.nvim"`             | Client title sent during initialization.                                              |
| `client.version`                       | `"0.1.0"`                   | Client version sent during initialization.                                            |
| `client.protocol_version`              | `1`                         | Protocol version sent during initialization.                                          |
| `client.capabilities.fs.readTextFile`  | `true`                      | Advertises ACP text-file read capability.                                             |
| `client.capabilities.fs.writeTextFile` | `true`                      | Advertises ACP text-file write capability.                                            |
| `client.capabilities.terminal`         | `false`                     | Advertises terminal capability.                                                       |
| `references.include_modified_buffer` | `false`                     | Include full unsaved buffer contents for `:OmniacReferenceBuffer` when enabled.       |
| `ui.diff_title`                        | `"ACP Diff"`                | Buffer title used for proposed-change reviews.                                        |
| `ui.diff_separate_tab`                 | `false`                     | Opens diff reviews in a separate tab.                                                 |
| `ui.change_review`                     | `"summary"`                | Post-turn change review: `"summary"`, `"open"`, or `"off"`.                     |
| `ui.chat_width`                        | `58`                        | Width of the Omniac side UI.                                                          |
| `ui.welcome_card`                     | `"pinned"`                | Keep the mascot card above the chat; `"welcome_only"` shows it only before the first message. In short windows (under 32 lines), Omniac uses welcome-only mode to preserve chat space. |
| `ui.mascot_follow_cursor`              | `true`                      | Let the mascot react to Omniac focus and slowly follow the cursor inside chat or input while its card is visible. |
| `ui.mascot_motion`                     | `true`                      | Animate idle walks, antenna twitches, working gestures, and jumps inside the pinned card. Set to `false` to disable these motions; `mascot_follow_cursor` controls gaze separately. |
| `ui.tool_results`                      | `"compact"`                 | Chat visibility for completed tool output: `"compact"`, `"all"`, or `"none"`.        |
| `ui.tool_result_max_lines`             | `4`                         | Maximum output lines shown in compact tool-result mode.                               |
| `logs.dir`                             | `"logs"`                    | Directory used for protocol logs when `debug` is enabled.                             |

## Features

- `:OmniacConnect` starts the configured subprocess
- type `/resume` in the Omniac chat to list sessions and open the session-selection dialog
- `:OmniacSession` opens the same session-selection flow as a command
- `:OmniacSessionNew` starts a fresh ACP session
- `:OmniacSessionLoad {sessionId}` loads an ACP session and replays its history when the agent advertises `loadSession`
- `:OmniacSessionResume {sessionId}` resumes an ACP session without replaying history when the agent advertises `sessionCapabilities.resume`
- `:Omniac` opens a Neovim chat/input/status UI
- In pinned-card mode, focus the welcome card and move the cursor normally: nearby vertical movement draws a small hop, moving sideways across the mascot pets it, and repeated pets make it briefly flee. These reactions do not remap `h/j/k/l`.
- `/model` opens a model selector for the active session; `/model <model>` changes it directly
- `/mode` opens the agent's mode selector; `/mode <id>` changes the active session mode directly
  The initial mode is configured with `agent.mode_id`, for example `agent = { mode_id = "workspace-write" }`.
  A change made with `/mode` applies to the current session; on a new connection Omniac applies `agent.mode_id` again.
- `Shift-Tab` toggles the agent's `collaboration_mode` between `default` and `plan` when both values are advertised. Omniac leaves `Tab` unmapped.
- `/changes` reviews files changed in the latest turn; `/changes session` reviews changes accumulated since the current connection started
- When the activity window shows a change summary, focus it and press `t` for the latest turn or `s` for the current session
- `:OmniacChanges [turn|session]` opens the same read-only change browser
- The change browser stays in normal mode; closing a file preview returns to the same list and selection
- change history includes structured ACP edit updates and client-mediated `fs/write_text_file` writes; commands that modify files without reporting a diff are not attributed to Omniac
- change review history is kept in memory and starts fresh after `load`, `resume`, or reconnect; use `git diff` as the source of truth for the current working tree
- `:OmniacResize {width}` resizes the Omniac side UI as one body
- `:OmniacAsk` sends the built prompt to the active ACP agent when connected
- `:OmniacReferenceBuffer` attaches the current buffer to the Omniac input; `<leader>ab` is the default mapping
- `:'<,'>OmniacReference` captures selected lines from the source buffer and attaches them to the Omniac input
- `Ctrl-V` in the Omniac input attaches a PNG or JPEG image from the macOS clipboard when the ACP agent advertises image prompts; otherwise it falls back to normal text paste
- visual references preserve their source path, line range, and selected unsaved text
- current-buffer references use a file link by default, even when modified; the agent reads the on-disk version, not unsaved edits
- set `references.include_modified_buffer = true` to attach full unsaved contents; a buffer without an on-disk file is skipped unless enabled
- file mentions can be formatted into prompts
- incoming JSONL messages are parsed, streamed into the UI, and shown with `vim.notify`
- ACP permission requests and known file-change approval requests open a native diff review UI
- some non-file request types still use conservative placeholder responses until richer UI support exists

## Architecture

- `lua/omniac/selection.lua` collects the active visual range and text
- `lua/omniac/mentions.lua` formats file references for prompts
- `lua/omniac/diff.lua` manages buffers and accepts user edits
- `lua/omniac/transport/` isolates ACP process communication

## Dev

Start Neovim with `scripts/dev.lua` to load this plugin with the default `codex-acp` command already configured.

Run the test suite with:

```sh
./test.sh
```

The tests use Plenary's Busted-compatible test harness in a minimal Neovim environment. The runner uses
`PLENARY_DIR` when it is set, reuses a lazy.nvim installation when available, and otherwise downloads a
test-only copy into the user cache directory.

## TODO

- [Feature TODO](docs/FEATURE_TODO.md): Omniac input, history, safety, and UX work.
- [Protocol TODO](docs/PROTOCOL_TODO.md): ACP implementation scope and remaining work.
