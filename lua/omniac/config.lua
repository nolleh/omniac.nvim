local M = {}

M.defaults = {
  debug = false,
  keymaps = {
    open = "<leader>ac",
    focus = "<leader>af",
    session = "<leader>ar",
    buffer = "<leader>ab",
    reference = "<leader>as",
    tree_add = "<leader>as",
    diff_accept = "<leader>aa",
    diff_deny = "<leader>ad",
  },
  agent = {
    cmd = { "codex-acp" },
    args = {},
    env = {},
    cwd = nil,
    model = nil,
    mode_id = "read-only",
    pty = false,
    session = {
      action = "new",
      id = nil,
    },
  },
  session_selector = nil,
  client = {
    name = "omniac.nvim",
    title = "omniac.nvim",
    version = "0.1.0",
    protocol_version = 1,
    capabilities = {
      fs = {
        readTextFile = true,
        writeTextFile = true,
      },
      terminal = false,
    },
  },
  ui = {
    diff_title = "ACP Diff",
    diff_separate_tab = false,
    chat_width = 58,
    tool_results = "compact",
    tool_result_max_lines = 4,
  },
  logs = {
    dir = "logs",
  },
}

function M.merge(user_opts)
  return vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
end

return M
