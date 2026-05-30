local M = {}

M.defaults = {
  debug = false,
  backend = {
    kind = "auto",
  },
  agent = {
    cmd = { "codex", "app-server" },
    args = {},
    env = {},
    cwd = nil,
    auto_initialize = true,
    pty = false,
  },
  client = {
    name = "acpclient.nvim",
    title = "acpclient.nvim",
    version = "0.1.0",
    protocol_version = 1,
    capabilities = {
      fs = {
        readTextFile = false,
        writeTextFile = false,
      },
      terminal = false,
    },
  },
  ui = {
    diff_title = "ACP Diff",
  },
}

function M.merge(user_opts)
  return vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
end

return M
