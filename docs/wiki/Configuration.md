# Configuration

Pass options through lazy.nvim's `opts` or `require("omniac").setup({...})`.

## Common settings

```lua
{
  agent = {
    cmd = { "codex-acp" },
    cwd = vim.fn.getcwd(),
    mode_id = "workspace-write",
  },
  references = {
    include_modified_buffer = false,
  },
  ui = {
    chat_width = "35%",
    welcome_card = "welcome_only",
    diff_separate_tab = true,
  },
}
```

The mode ID must be advertised by your agent. An unsupported initial mode produces a warning and leaves the agent's current mode in place. See [Sessions and models](Sessions-and-Models.md).

## Default keymaps

Existing mappings are preserved. Override individual mappings, set an action to `false` to disable it, or set `keymaps = false` to disable all defaults.

```lua
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
```

## Options

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
| `ui.tool_results`                      | `"compact"`                 | Tool results with a colored task title, a four-row Bash code-block preview, and collapsible output. Shell syntax highlighting uses the Bash Treesitter parser when installed; output retains its ANSI colors. `"compact"` hides opaque calls; `"all"` includes them; `"none"` hides successful results. Failures remain visible. |
| `ui.tool_result_max_lines`             | `4`                         | Maximum wrapped output rows in a collapsed tool result. Ctrl-T expands the full command and output, including long named results in compact mode. |
| `logs.dir`                             | `"logs"`                    | Directory used for protocol logs when `debug` is enabled.                             |

With `debug = true`, `acp-*.jsonl` records client requests and notifications (`client_request`, `client_notification`), agent responses (`agent_response`), and agent requests and notifications with their client responses (`request`, `notification`, `response`). This includes `session/prompt` and `session/cancel` traffic.

For log troubleshooting, see [Troubleshooting](Troubleshooting.md).
