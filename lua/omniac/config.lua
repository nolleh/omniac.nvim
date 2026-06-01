local M = {}

M.defaults = {
  debug = false,
  protocol_trace = true,
  backend = {
    kind = "auto",
  },
  agent = {
    cmd = { "codex", "app-server" },
    args = {},
    env = {},
    cwd = nil,
    mode_id = "read-only",
    auto_initialize = true,
    pty = false,
  },
  client = {
    name = "omniac.nvim",
    title = "omniac.nvim",
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
    diff_separate_tab = false,
    chat_width = 58,
  },
  logs = {
    enabled = true,
    dir = "logs",
  },
}

function M.merge(user_opts)
  return vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
end

return M
