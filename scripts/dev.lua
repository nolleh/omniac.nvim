local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local agent_cmd = { "codex", "app-server" }

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
