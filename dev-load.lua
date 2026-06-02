-- Development loader for omniac.nvim
-- This appends omniac.nvim to your existing config without replacing it
-- Usage: nvim -c "luafile dev-load.lua"

local plugin_path = vim.fn.expand("<sfile>:p:h")

vim.opt.runtimepath:append(plugin_path)

require("omniac").setup({
  debug = false,
  agent = {
    cmd = vim.env.ACPCLIENT_AGENT_CMD
        and vim.env.ACPCLIENT_AGENT_CMD ~= ""
        and vim.split(vim.env.ACPCLIENT_AGENT_CMD, "%s+", { trimempty = true })
      or { "codex", "app-server" },
  },
})

print("✓ omniac.nvim dev mode loaded!")
print("  Try :OmniacConnect")
