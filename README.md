# omniac.nvim

**Your agent. Your editor. One workflow.**

Work with your favorite coding agent inside Neovim. Share the code you're editing, guide the agent as it works, and shape its proposed changes before approving them.

<!-- Demo video: selection -> request -> mid-turn message -> adjusted diff -> changes. -->
*Demo video coming soon.*

## Why omniac.nvim?

Your code, conversation, and decisions belong together.

Omniac brings your coding agent into your editing workspace. Send the context you already have open, keep an eye on the work, and step in when something needs your attention.

Choose the agent you prefer. Keep the Neovim workflow you enjoy.

## Features

### Guide work in progress

A new thought doesn't have to wait until the task is over.

Press `Enter` to send a message into the running task when your agent supports it, or `Tab` to queue the next request. Code and image attachments stay with your message.

<!-- Feature video: immediate delivery and queued prompts. -->

### Shape proposed changes

Review proposed edits in native Neovim diffs. Accept, reject, or make a small adjustment directly in the review buffer.

Omniac carries your adjusted proposal into a follow-up so the agent can apply the version you reviewed.

<!-- Feature video: adjust a proposal -> approve -> apply reviewed content. -->

### Follow the work

See the current step at a glance. Expand the full plan with `Ctrl-P` when you want the details, and unfold command output with `Ctrl-T`.

When the task finishes, browse what changed in the latest turn or across the session.

<!-- Feature screenshot: expanded plan and changed-file list. -->

### Bring your context

Select code and send it straight to the conversation. Add a file from your editor or file tree, or paste a screenshot into the input.

Selected code includes your unsaved edits, so you can discuss what you're working on right now.

### Pick up where you left off

Browse saved sessions and restore the conversation. Switch between your agent's available models and modes as the task changes.

### Choose your coding agent

Omniac starts and manages your configured agent from Neovim.

Connect a coding agent that supports the Agent Client Protocol (ACP). Available models, modes, and capabilities come from the agent you choose.

### A little company while you code

The welcome-card mascot follows your cursor, hops around, and reacts when you pet it. Give it too much attention and it might run away.

<!-- Feature video: mascot movement and petting reactions. -->

## Installation

Install and authenticate a coding agent first. For the default Codex agent:

```sh
npm install -g @agentclientprotocol/codex-acp
codex-acp login
```

Install Omniac with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nolleh/omniac.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "MeanderingProgrammer/render-markdown.nvim",
  },
  opts = {},
}
```

See [Getting started](docs/wiki/Getting-Started.md) for parser setup and agent configuration.

## Quick start

| Action | Key or command |
| --- | --- |
| Open Omniac | `<leader>ac` |
| Focus the input | `<leader>af` |
| Attach selected code | `<leader>as` in visual mode |
| Attach the current file | `<leader>ab` |
| Attach a clipboard image | `Ctrl-V` in input |
| Choose a session | `/resume` |
| Choose a model or mode | `/model` · `/mode` |
| Review changes | `/changes` |

Default keymaps are registered automatically and preserve existing mappings. To disable all defaults, set `opts = { keymaps = false }` in your lazy.nvim spec. Customize or disable individual mappings with:

```lua
opts = {
  keymaps = {
    open = "<leader>ao", -- Change the toggle key
    reference = false, -- Disable the visual-selection mapping
  },
}
```

The default Codex mode is read-only. Use `/mode` to choose an editing mode.

## Documentation

[Getting started](docs/wiki/Getting-Started.md) · [Configuration](docs/wiki/Configuration.md) · [Commands and keymaps](docs/wiki/Commands-and-Keymaps.md)

[All guides](docs/wiki/Home.md) · [Changelog](CHANGELOG.md)
