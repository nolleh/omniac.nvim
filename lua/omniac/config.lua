local M = {}

M.defaults = {
  debug = false,
  keymaps = {
    open = "<leader>ac",
    focus = "<leader>af",
    session = "<leader>ar",
    model = "<leader>am",
    mode = "<leader>aM",
    buffer = "<leader>ab",
    reference = "<leader>as",
    tree_add = "<leader>as",
    diff_accept = "<leader>aa",
    diff_deny = "<leader>ad",
  },
  references = {
    include_modified_buffer = false,
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
    request_timeout_ms = 30000,
    prompt_timeout_ms = 600000,
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
    change_review = "summary",
    -- Screen ratio (0 < width < 1), percentage string ("35%"), or fixed columns (72).
    chat_width = 0.35,
    welcome_card = "pinned",
    mascot_follow_cursor = true,
    mascot_motion = true,
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
