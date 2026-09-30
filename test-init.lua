vim.opt.compatible = false

vim.opt.termguicolors = true
vim.opt.hidden = true
vim.opt.splitbelow = true
vim.opt.splitright = true

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

require("omniac").setup({
  debug = false,
  agent = {
    cmd = vim.env.ACPCLIENT_AGENT_CMD
        and vim.env.ACPCLIENT_AGENT_CMD ~= ""
        and vim.split(vim.env.ACPCLIENT_AGENT_CMD, "%s+", { trimempty = true })
      or { "codex-acp" },
  },
})

print("")
print("============================================")
print("  omniac.nvim Test Mode (Clean Environment)")
print("============================================")
print("")
print("  This is a minimal environment without your config")
print("  Try :OmniacConnect")
print("")
