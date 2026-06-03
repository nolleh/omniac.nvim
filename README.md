# omniac.nvim

Neovim plugin for ACP-compatible agents and agentic coding workflows.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nolleh/omniac.nvim",
}
```

With options:

```lua
{
  "nolleh/omniac.nvim",
  opts = {
    backend = {
      kind = "acp",
    },
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
      diff_separate_tab = true,
      diff_title = "Omniac Review",
    },
  },
}
```

Use a project-local working directory and disable protocol logs:

```lua
{
  "nolleh/omniac.nvim",
  opts = {
    agent = {
      cwd = vim.fn.getcwd(),
    },
    logs = {
      enabled = false,
    },
  },
}
```

### Options

| Option                                 | Default                     | Description                                                                           |
| -------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------- |
| `debug`                                | `false`                     | Enables extra debug notifications and debug-log inspection.                           |
| `protocol_trace`                       | `true`                      | Echoes ACP protocol request/notification trace messages.                              |
| `backend.kind`                         | `"auto"`                    | Backend selection. Use `"acp"` to force ACP mode.                                     |
| `agent.cmd`                            | `{ "codex", "app-server" }` | Agent subprocess command. In ACP mode, the default is rewritten to `{ "codex-acp" }`. |
| `agent.args`                           | `{}`                        | Additional agent arguments.                                                           |
| `agent.env`                            | `{}`                        | Environment variables passed to the agent subprocess.                                 |
| `agent.cwd`                            | `nil`                       | Working directory for the agent subprocess.                                           |
| `agent.mode_id`                        | `"read-only"`               | Initial ACP agent mode.                                                               |
| `agent.auto_initialize`                | `true`                      | Sends the legacy initialize flow automatically. ACP mode disables this internally.    |
| `agent.pty`                            | `false`                     | Runs the subprocess through a PTY when supported.                                     |
| `agent.session.action`                 | `"new"`                     | ACP session startup action: `"new"`, `"load"`, `"resume"`, or `"select"`.            |
| `agent.session.id`                     | `nil`                       | ACP session ID used when `agent.session.action` is `"load"` or `"resume"`.            |
| `client.name`                          | `"omniac.nvim"`             | Client name sent during initialization.                                               |
| `client.title`                         | `"omniac.nvim"`             | Client title sent during initialization.                                              |
| `client.version`                       | `"0.1.0"`                   | Client version sent during initialization.                                            |
| `client.protocol_version`              | `1`                         | Legacy protocol version value.                                                        |
| `client.capabilities.fs.readTextFile`  | `true`                      | Advertises ACP text-file read capability.                                             |
| `client.capabilities.fs.writeTextFile` | `true`                      | Advertises ACP text-file write capability.                                            |
| `client.capabilities.terminal`         | `false`                     | Advertises terminal capability.                                                       |
| `ui.diff_title`                        | `"ACP Diff"`                | Buffer title used for proposed-change reviews.                                        |
| `ui.diff_separate_tab`                 | `false`                     | Opens diff reviews in a separate tab.                                                 |
| `ui.chat_width`                        | `58`                        | Width of the Omniac side UI.                                                          |
| `logs.enabled`                         | `true`                      | Writes ACP protocol logs when enabled.                                                |
| `logs.dir`                             | `"logs"`                    | Directory used for protocol logs.                                                     |

## Features

- `:OmniacConnect` starts the configured subprocess
- type `/resume` or `/sessions` in the Omniac chat to list sessions and open the session-selection dialog
- `:OmniacSession` opens the same session-selection flow as a command
- `:OmniacSessionNew` starts a fresh ACP session
- `:OmniacSessionLoad {sessionId}` loads an ACP session and replays its history when the agent advertises `loadSession`
- `:OmniacSessionResume {sessionId}` resumes an ACP session without replaying history when the agent advertises `sessionCapabilities.resume`
- `:Omniac` opens a Neovim chat/input/status UI
- `:OmniacAsk` sends the built prompt through the active backend when connected
- visual selections can be included in prompts
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

Start Neovim with `scripts/dev.lua` to load this plugin with the default Codex command already configured.

## Protocol TODO

See [docs/PROTOCOL_TODO.md](docs/PROTOCOL_TODO.md) for the current ACP implementation scope and remaining work.
