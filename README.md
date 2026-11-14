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
      model = "<leader>am",
      mode = "<leader>aM",
      buffer = "<leader>ab",
      reference = "<leader>as",
      tree_add = "<leader>as",
      diff_accept = "<leader>aa",
      diff_deny = "<leader>ad",
    },
  },
}
```

Omniac registers these defaults when `setup()` runs. Where applicable, they follow the corresponding `claudecode.nvim` keys, skip keys that are already mapped, and can be changed by setting a different value or disabled per action with `false`. Set `keymaps = false` to disable all Omniac mappings. `<leader>ac` toggles the Omniac windows, while `<leader>af` opens them when hidden and focuses the input when they are already visible. `<leader>as` sends a visual selection, and in supported file-tree buffers it adds the file under the cursor (`nvim-tree`, `neo-tree`, `oil.nvim`, or `mini.files`). Session selection is available through `<leader>ar`, model selection through `<leader>am`, and session mode selection through `<leader>aM` in normal mode. The selectors are also available through `:OmniacModel` and `:OmniacMode`, or `/model` and `/mode` in the chat.

Chat and permission bodies use the dedicated `omniac` and `omniac-permission` filetypes. Omniac connects them to the Markdown parser and `render-markdown.nvim` explicitly, without running `FileType markdown` document hooks such as browser previews.

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
      chat_width = "35%", -- or 0.35; use 72 for a fixed width in columns
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

Relative widths use the full Neovim screen width and update automatically when the screen is resized,
including after closing and reopening Omniac. Widths are rounded down and clamped to at least 42 columns,
leaving 20 columns for the editor when space permits. `:OmniacResize` overrides the configured width for
the current UI instance; passing a column count switches back to a fixed width.

| Option                                 | Default           | Description                                                                           |
| -------------------------------------- | ----------------- | ------------------------------------------------------------------------------------- |
| `debug`                                | `false`           | Enables extra debug notifications and debug-log inspection.                           |
| `agent.cmd`                            | `{ "codex-acp" }` | ACP agent subprocess command.                                                         |
| `agent.args`                           | `{}`                        | Additional agent arguments.                                                           |
| `agent.env`                            | `{}`                        | Environment variables passed to the agent subprocess.                                 |
| `agent.cwd`                            | `nil`                       | Working directory for the agent subprocess.                                           |
| `agent.mode_id`                        | `"read-only"`               | Initial ACP agent mode ID; choose one advertised by the agent. Unsupported IDs produce a warning and keep the agent's current mode. |
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
| `client.request_timeout_ms`            | `30000`                     | Timeout for ACP requests other than prompts, in milliseconds. Set to `0` to disable. |
| `client.prompt_timeout_ms`             | `600000`                    | Timeout for a prompt response, in milliseconds. Set to `0` to disable.               |
| `client.capabilities.fs.readTextFile`  | `true`                      | Advertises ACP text-file read capability.                                             |
| `client.capabilities.fs.writeTextFile` | `true`                      | Advertises ACP text-file write capability.                                            |
| `client.capabilities.terminal`         | `false`                     | Advertises terminal capability.                                                       |
| `client.capabilities.plan`             | `{}`                        | Advertises plan updates; renders plan documents and checklists by plan ID, alongside legacy ACP `plan` updates. |
| `references.include_modified_buffer` | `false`                     | Include full unsaved buffer contents for `:OmniacReferenceBuffer` when enabled.       |
| `ui.diff_title`                        | `"ACP Diff"`                | Buffer title used for proposed-change reviews.                                        |
| `ui.diff_separate_tab`                 | `false`                     | Opens diff reviews in a separate tab.                                                 |
| `ui.change_review`                     | `"summary"`                | Post-turn change review: `"summary"`, `"open"`, or `"off"`.                     |
| `ui.chat_width`                        | `0.35`                      | Side UI width: columns (e.g. `72`), a ratio between 0 and 1 (e.g. `0.35`), or a percentage string (e.g. `"35%"`). |
| `ui.welcome_card`                     | `"pinned"`                | Keep the mascot card above the chat; `"welcome_only"` shows it only before the first message. In short windows (under 32 lines), Omniac uses welcome-only mode to preserve chat space. |
| `ui.mascot_follow_cursor`              | `true`                      | Let the mascot react to Omniac focus and slowly follow the cursor inside chat or input while its card is visible. |
| `ui.mascot_motion`                     | `true`                      | Animate idle walks, antenna twitches, working gestures, and jumps inside the pinned card. Set to `false` to disable these motions; `mascot_follow_cursor` controls gaze separately. |
| `ui.tool_results`                      | `"compact"`                 | Tool results with a colored task title, a four-row command preview, and collapsible output. `"compact"` hides opaque calls; `"all"` includes them; `"none"` hides successful results. Failures remain visible. |
| `ui.tool_result_max_lines`             | `4`                         | Maximum wrapped output rows in a collapsed tool result. Ctrl-T expands the full command and output, including long named results in compact mode. |
| `logs.dir`                             | `"logs"`                    | Directory used for protocol logs when `debug` is enabled.                             |

With `debug = true`, `acp-*.jsonl` records client requests and notifications (`client_request`, `client_notification`), agent responses (`agent_response`), and agent requests and notifications with their client responses (`request`, `notification`, `response`). This includes `session/prompt` and `session/cancel` traffic.

## Features

- `:OmniacConnect` starts the configured subprocess
- If a prompt fails, the activity bar offers `[r]` Resend, `[e]` Restore input, and `[d]` Dismiss in Omniac normal mode. Check whether the agent already handled it before resending.
- type `/resume` in the Omniac chat to list sessions and open the session-selection dialog
- `:OmniacSession` opens the session selector; when disconnected, it opens Omniac and asks the agent for its available sessions
- type `/clear` to start a fresh ACP session while keeping the current connection
- in the session-selection dialog, `[n]` starts a fresh ACP session; `[Enter]` loads a session and `[r]` resumes one when supported
- `:Omniac` opens a Neovim chat/input/status UI
- In pinned-card mode, focus the welcome card and move the cursor normally: nearby vertical movement draws a small hop, moving sideways across the mascot pets it, and repeated pets make it briefly flee. These reactions do not remap `h/j/k/l`.
- `/model` opens a model selector for the active session; `/model <model>` changes it directly
- `/mode` opens the agent's mode selector; `/mode <id>` changes the active session mode directly
  The initial mode is configured with `agent.mode_id`, for example `agent = { mode_id = "workspace-write" }`.
  The ID must be advertised by the configured agent. If it is unsupported, Omniac warns with the available modes and keeps the session's current mode.
  A change made with `/mode` applies to the current session. Omniac applies `agent.mode_id` when creating a new
  session, while loaded or resumed sessions keep their saved mode.
- Agent execution plans show completed / total steps and the current step in the activity bar, alongside tool activity. A single plan entry in chat updates as the plan changes and remains in the transcript after completion, cancellation, or failure.
- Omniac advertises plan support during initialization. Agents can send `plan_update` documents (Markdown, item checklists, or file references) and remove them with `plan_removed`. The latest document appears in the activity bar and each plan ID has its own updating chat entry. This advertises client display support; it does not enable Codex's `update_plan` tool or force the agent to create a plan.
- ANSI colors and text styles in command output, tool summaries, activity, and agent replies render as Neovim highlights. Terminal control sequences are hidden; stored output and debug logs retain the original bytes.
- `Shift-Tab` toggles the agent's `collaboration_mode` between `default` and `plan` when both values are advertised.
- While a prompt is running, `Tab` queues the input after slash-command completion has been handled. Queued prompts appear as user messages marked `Queued`, then send in order after the active prompt completes. The same message loses its queue marker when sent; a failed prompt pauses the queue until you resolve the failure.
- During a turn, `Enter` sends an additional message immediately when the agent advertises the `_session/steering` extension (including current `codex-acp`). It joins the running turn and can affect the agent's next processing step. `Tab` keeps its separate next-turn queue behavior. If steering is unsupported, Omniac keeps the draft and suggests `Tab`; rejected steering restores the draft when the input is empty.
- `Ctrl-k` and `Ctrl-j` move between the welcome card, chat, and input in normal or insert mode, skipping the activity and status bars. When the welcome card is hidden, they move between chat and input.
- `/changes` reviews files changed in the latest turn; `/changes session` reviews changes accumulated since the current connection started
- When the activity window shows a change summary, press `t` for the latest turn or `s` for the current session from any Omniac window except the input
- `:OmniacChanges [turn|session]` opens the change browser in Telescope when available, with a diff preview; otherwise it uses the built-in dialog
- In the change browser, press `Enter` to review the diff or `Ctrl-e` to edit the file at its first changed line
- Closing a selected file's full preview returns to the same list and selection
- change history includes ACP edits and client-mediated writes regardless of whether approval was requested. Edits and terminal commands without a reported diff are also captured from disk.
- change tracking compares text files in `agent.cwd` around agent edit/terminal tool execution; existing changes and saves outside that execution window are excluded. Concurrent external writes during an agent command cannot be distinguished from command writes. Git-ignored files, binary files, and files larger than 2 MiB are excluded from workspace comparisons. Without Git, text files under `agent.cwd` are scanned directly.
- change review history is kept in memory and starts fresh after `load`, `resume`, or reconnect; use `git diff` as the source of truth for the current working tree
- `:OmniacResize {width}` resizes the Omniac side UI as one body, e.g. `:OmniacResize 72`, `:OmniacResize 0.35`, or `:OmniacResize 35%`
- `:OmniacAsk` sends the built prompt to the active ACP agent when connected
- `:OmniacReferenceBuffer` attaches the current buffer to the Omniac input; `<leader>ab` is the default mapping
- `:'<,'>OmniacReference` captures selected lines from the source buffer and attaches them to the Omniac input
- `Ctrl-V` in the Omniac input attaches a PNG or JPEG image from the macOS clipboard when the ACP agent advertises image prompts; otherwise it falls back to normal text paste
- Up / Down in an empty Omniac input starts browsing submitted prompts; keep using the arrows to browse until you edit the recalled text. `Ctrl-c` clears the current input and pending references
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

Start Neovim with a live ACP agent:

```sh
make dev                 # Codex (default)
make dev agent=copilot  # Copilot
make dev agent=copilot model=gpt-5.4
```

The Copilot command uses an installed `copilot` executable when available and otherwise runs
`@github/copilot` through `npx`. Copilot supports selecting its initial model with `model=...`;
Codex exposes model selection through the active ACP session instead.

Run the mocked Plenary test suite with:

```sh
make test
```

The tests use Plenary's Busted-compatible test harness in a minimal Neovim environment. The runner uses
`PLENARY_DIR` when it is set, reuses a lazy.nvim installation when available, and otherwise downloads a
test-only copy into the user cache directory.

Run a live ACP integration test with `make e2e` for Codex or `make e2e agent=copilot` for Copilot.
These tests use the authenticated agent and consume its usage quota.

## TODO

- [Feature TODO](docs/FEATURE_TODO.md): Omniac input, history, safety, and UX work.
- [Protocol TODO](docs/PROTOCOL_TODO.md): ACP implementation scope and remaining work.
