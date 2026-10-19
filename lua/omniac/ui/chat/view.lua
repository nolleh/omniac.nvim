local M = {}
local chat_render = require("omniac.ui.chat.render")

local MARKDOWN_RENDER_CONFIG = {
  pipe_table = {
    border_virtual = true,
    style = "normal",
  },
}

local function start_treesitter(state, valid_buf)
  if not valid_buf(state.chat_buf) or not (vim.treesitter and vim.treesitter.start) then
    return
  end

  pcall(vim.treesitter.start, state.chat_buf, "markdown")
end

local function clear_markdown_marks(state, valid_buf)
  if not valid_buf(state.chat_buf) then
    return
  end

  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if type(name) == "string" and name:match("render.markdown") then
      pcall(vim.api.nvim_buf_clear_namespace, state.chat_buf, id, 0, -1)
    end
  end
end

local function render_markdown(state, valid_buf)
  if not valid_buf(state.chat_buf) then
    return
  end

  local ok, renderer = pcall(require, "render-markdown")
  if not ok or type(renderer) ~= "table" then
    return
  end

  if renderer.initialized == false and type(renderer.setup) == "function" then
    pcall(
      renderer.setup,
      vim.tbl_deep_extend("force", {
        file_types = { "markdown" },
      }, MARKDOWN_RENDER_CONFIG)
    )
  end

  if type(renderer.render) == "function" then
    local ok_state, renderer_state = pcall(require, "render-markdown.state")
    if ok_state and type(renderer_state) == "table" and type(renderer_state.cache) == "table" then
      renderer_state.cache[state.chat_buf] = nil
    end
    pcall(renderer.render, {
      buf = state.chat_buf,
      win = state.chat_win,
      event = "OmniacRender",
      config = MARKDOWN_RENDER_CONFIG,
    })
  elseif type(renderer.buf_enable) == "function" then
    pcall(renderer.buf_enable)
  end
end

local function capture_view(state, opts, valid_win)
  if not valid_win(state.chat_win) then
    return nil, false
  end

  local cursor = vim.api.nvim_win_get_cursor(state.chat_win)
  local is_active = vim.api.nvim_get_current_win() == state.chat_win
  local mode = is_active and vim.fn.mode(1) or ""
  local previous_view = vim.api.nvim_win_call(state.chat_win, vim.fn.winsaveview)
  local should_follow = opts.follow == true
    and (is_active or vim.api.nvim_get_current_win() == state.input_win)
    and mode:match("^[vV\22]") == nil
    and cursor[1] >= vim.api.nvim_buf_line_count(state.chat_buf)
  return previous_view, should_follow
end

local function restore_view(state, opts, lines, previous_view, should_follow, valid_win)
  if opts.reset_view and valid_win(state.chat_win) then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { 1, 0 })
    pcall(vim.api.nvim_win_call, state.chat_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
  elseif should_follow and valid_win(state.chat_win) and #lines > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { #lines, 0 })
  elseif previous_view and valid_win(state.chat_win) then
    local line_count = math.max(#lines, 1)
    previous_view.lnum = math.min(previous_view.lnum, line_count)
    previous_view.topline = math.min(previous_view.topline, line_count)
    pcall(vim.api.nvim_win_call, state.chat_win, function()
      vim.fn.winrestview(previous_view)
    end)
  end
end

function M.render(state, config, opts, handlers)
  opts = opts or {}
  state.config = config or state.config
  if not handlers.valid_buf(state.chat_buf) then
    return
  end

  local previous_view, should_follow = capture_view(state, opts, handlers.valid_win)
  local win_width = handlers.valid_win(state.chat_win) and vim.api.nvim_win_get_width(state.chat_win)
    or handlers.width()
  local content = chat_render.build({
    state = state,
    width = win_width,
    header = handlers.header,
    agent_name = handlers.agent_name,
  })
  local lines = content.lines

  vim.bo[state.chat_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.chat_buf, handlers.namespace, 0, -1)
  if not opts.skip_markdown then
    clear_markdown_marks(state, handlers.valid_buf)
  end
  vim.api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, lines)
  vim.bo[state.chat_buf].modifiable = false
  vim.bo[state.chat_buf].modified = false
  if not opts.skip_markdown then
    start_treesitter(state, handlers.valid_buf)
  end

  for _, mark in ipairs(content.marks) do
    handlers.add_hl(state.chat_buf, mark.line, mark.from, mark.to, mark.group)
  end
  for _, mark in ipairs(content.permission_marks) do
    vim.api.nvim_buf_set_extmark(state.chat_buf, handlers.namespace, mark.line - 1, 0, {
      virt_text = { { mark.label, mark.group }, { "  ", "Normal" } },
      virt_text_pos = "right_align",
    })
  end

  if not opts.skip_markdown then
    render_markdown(state, handlers.valid_buf)
  end

  restore_view(state, opts, lines, previous_view, should_follow, handlers.valid_win)
end

return M
