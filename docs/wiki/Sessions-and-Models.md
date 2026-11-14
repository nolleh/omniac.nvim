# Sessions and models

## Select a session

Run `/resume`, `:OmniacSession`, or press `<leader>ar`. When disconnected, Omniac connects and requests available sessions first.

In the selector:

- `n` starts a fresh session.
- `Enter` loads a saved session with conversation history.
- `r` resumes without replaying history when supported by the agent.

`/clear` starts a fresh session using the current connection. If opening a session fails, choose another through `/resume`.

## Models and modes

`/model` or `<leader>am` opens model selection; `/model <model>` changes it directly. Model config options take precedence, with a fallback for agents advertising legacy `models` metadata.

`/mode` or `<leader>aM` opens mode selection; `/mode <id>` changes it directly. Mode IDs and available choices come from the agent.

Configure an initial mode for new sessions:

```lua
agent = {
  mode_id = "workspace-write",
},
```

The ID must be advertised by the configured agent. If unsupported, Omniac warns with available choices and keeps the current mode. Loaded and resumed sessions keep their saved mode.

`Shift-Tab` switches between `default` and `plan` collaboration modes when both are advertised. Mode selection does not force the agent to publish an execution plan.

## Startup selection

Set `agent.session.action` to `new`, `load`, `resume`, or `select`. Supply `agent.session.id` for load/resume. The optional `session_selector` callback can choose startup behavior programmatically. See [Configuration](Configuration.md) for defaults.
