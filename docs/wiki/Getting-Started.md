# Getting started

## Install an agent

Omniac connects to an ACP-compatible agent running as a local subprocess. If your agent's CLI does not support ACP directly, install its ACP adapter. Install and authenticate the ACP executable before connecting.

For the default Codex agent:

```sh
npm install -g @agentclientprotocol/codex-acp
codex-acp login
```

Omniac uses `codex-acp` as its default agent command, so you don't need to configure `agent.cmd` separately.

To use another agent, set its executable and arguments:

```lua
require("omniac").setup({
  agent = {
    cmd = { "copilot", "--acp", "--stdio" },
  },
})
```

Install and authenticate that CLI separately. Available images, modes, models, session operations, and mid-turn messaging depend on the agent's advertised capabilities.

## Install the plugin

With lazy.nvim:

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

Make the `markdown`, `markdown_inline`, and `bash` Treesitter parsers available for Markdown and shell highlighting. If your Treesitter installation provides `:TSInstall`, use `:TSInstall markdown markdown_inline bash`.

## Start a conversation

1. Open a project file and press `<leader>ac` or run `:Omniac`.
2. Type a request in the input and press `Enter`.
3. Use `<leader>af` to return focus to the input while keeping the conversation open.

The default Codex mode is `read-only`. Use `/mode` to choose an advertised editing mode, or configure `agent.mode_id` for new sessions.

Select lines in a source buffer and press `<leader>as` to include their current contents. `<leader>ab` adds the current file. See [Prompt context](Prompt-Context.md) for file and unsaved-buffer behavior.
