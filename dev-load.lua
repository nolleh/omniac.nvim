-- Development loader for omniac.nvim
-- This appends omniac.nvim to your existing config without replacing it
-- Usage: nvim -c "luafile dev-load.lua"

local plugin_path = vim.fn.expand("<sfile>:p:h")

vim.opt.runtimepath:append(plugin_path)

local function append_optional_plugin(path)
  local expanded = vim.fn.expand(path)
  if vim.fn.isdirectory(expanded) == 1 then
    vim.opt.runtimepath:append(expanded)
  end
end

append_optional_plugin(vim.env.OMNIAC_RENDER_MARKDOWN_PATH or "~/.local/share/nvim/lazy/render-markdown.nvim")
append_optional_plugin(vim.env.OMNIAC_TREESITTER_PATH or "~/.local/share/nvim/lazy/nvim-treesitter")
pcall(vim.cmd, "runtime plugin/render-markdown.lua")

require("omniac").setup({
  debug = true,
  agent = {
    cmd = vim.env.ACPCLIENT_AGENT_CMD
        and vim.env.ACPCLIENT_AGENT_CMD ~= ""
        and vim.split(vim.env.ACPCLIENT_AGENT_CMD, "%s+", { trimempty = true })
      or { "codex-acp" },
  },
})

print("✓ omniac.nvim dev mode loaded!")
print("  Try :OmniacConnect")
