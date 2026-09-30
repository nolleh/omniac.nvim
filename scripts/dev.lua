local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function append_optional_plugin(path)
  local expanded = vim.fn.expand(path)
  if vim.fn.isdirectory(expanded) == 1 then
    vim.opt.runtimepath:append(expanded)
  end
end

append_optional_plugin(vim.env.OMNIAC_RENDER_MARKDOWN_PATH or "~/.local/share/nvim/lazy/render-markdown.nvim")
append_optional_plugin(vim.env.OMNIAC_TREESITTER_PATH or "~/.local/share/nvim/lazy/nvim-treesitter")
pcall(vim.cmd, "runtime plugin/render-markdown.lua")

local agent_cmd = { "codex-acp" }

if vim.env.ACPCLIENT_AGENT_CMD and vim.env.ACPCLIENT_AGENT_CMD ~= "" then
  agent_cmd = vim.split(vim.env.ACPCLIENT_AGENT_CMD, "%s+", { trimempty = true })
end

require("omniac").setup({
  agent = {
    cmd = agent_cmd,
    cwd = root,
  },
})

vim.schedule(function()
  vim.cmd("OmniacConnect")
end)
