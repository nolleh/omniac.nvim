local M = {}

local function snapshot(state)
  local view = vim.api.nvim_win_call(state.chat_win, vim.fn.winsaveview)
  return {
    topline = view.topline,
    skipcol = view.skipcol,
    leftcol = view.leftcol,
    width = vim.api.nvim_win_get_width(state.chat_win),
    height = vim.api.nvim_win_get_height(state.chat_win),
    tick = vim.api.nvim_buf_get_changedtick(state.chat_buf),
  }
end

function M.remember(state)
  state.chat_follow_view = snapshot(state)
end

function M.observe(state)
  if state.chat_view_updating then
    return
  end
  local current = snapshot(state)
  local previous = state.chat_follow_view
  -- Buffer updates and layout changes are not requests to stop following.
  if
    previous
    and current.width == previous.width
    and current.height == previous.height
    and current.tick == previous.tick
  then
    if
      current.topline ~= previous.topline
      or current.skipcol ~= previous.skipcol
      or current.leftcol ~= previous.leftcol
    then
      local last = vim.api.nvim_buf_line_count(state.chat_buf)
      local bottom = vim.api.nvim_win_call(state.chat_win, function()
        if vim.fn.line("w$") < last then
          return false
        end
        -- Count screen rows, including wrapped text and Markdown virtual lines.
        return vim.api.nvim_win_text_height(state.chat_win, {
          start_row = current.topline - 1,
          start_vcol = current.skipcol,
        }).all <= current.height
      end)
      state.chat_following = bottom
    end
  end
  state.chat_follow_view = current
end

function M.reset(state)
  state.chat_following = true
  state.chat_follow_view = nil
end

return M
