vim.opt.compatible = false

vim.opt.termguicolors = true
vim.opt.hidden = true
vim.opt.splitbelow = true
vim.opt.splitright = true

local plugin_path = vim.fn.expand("<sfile>:p:h")

vim.opt.runtimepath:append(plugin_path)

require("acpclient").setup({
  debug = false,
  agent = {
    cmd = vim.env.ACPCLIENT_AGENT_CMD and vim.env.ACPCLIENT_AGENT_CMD ~= "" and vim.split(vim.env.ACPCLIENT_AGENT_CMD, "%s+", { trimempty = true })
      or { "codex", "app-server" },
  },
})

print("")
print("============================================")
print("  acpclient.nvim Test Mode (Clean Environment)")
print("============================================")
print("")
print("  This is a minimal environment without your config")
print("  Try :AcpClientConnect")
print("")
