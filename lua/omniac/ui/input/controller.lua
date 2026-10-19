local attachments = require("omniac.ui.input.attachments")
local text = require("omniac.ui.text")

local M = {}

local function previous_char_start(value, col)
  local last_start = 0
  local byte_col = 0
  for char in text.chars(value) do
    local next_col = byte_col + #char
    if next_col >= col then
      return byte_col
    end
    last_start = byte_col
    byte_col = next_col
  end
  return last_start
end

function M.clamp_cursor(state, opts)
  if state.rendering_input or not opts.valid_win(state.input_win) or not opts.valid_buf(state.input_buf) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local buffer_line_count = vim.api.nvim_buf_line_count(state.input_buf)
  local input_line_count = math.max(1, buffer_line_count - 2)
  local input_line = math.min(math.max(cursor[1] - 1, 1), input_line_count)
  local prefix = input_line == 1 and opts.prompt or opts.continuation
  local row = input_line + 1
  local col = math.max(cursor[2], #prefix)
  if cursor[1] ~= row or cursor[2] ~= col then
    pcall(vim.api.nvim_win_set_cursor, state.input_win, { row, col })
  end
end

function M.focus(state, opts)
  if not opts.valid_win(state.input_win) then
    return
  end

  vim.api.nvim_set_current_win(state.input_win)
  local lines = opts.read()
  local line = math.max(1, #lines)
  opts.render(lines, { line = line, col = #(lines[line] or "") })
  vim.cmd("startinsert!")
end

function M.focus_if_active(state, opts)
  if opts.valid_win(state.input_win) and vim.api.nvim_get_current_win() == state.input_win then
    M.focus(state, opts)
  end
end

function M.enforce(state, args, opts)
  if state.rendering_input or not opts.valid_buf(state.input_buf) then
    return
  end

  if args and args.event ~= "InsertLeave" and not state.input_history_navigating then
    opts.clear_history()
  end
  M.clamp_cursor(state, opts)
  local cursor = opts.valid_win(state.input_win) and vim.api.nvim_win_get_cursor(state.input_win) or { 2, #opts.prompt }
  local lines = opts.read()
  attachments.prune(state, lines)
  local input_cursor = opts.logical_cursor(cursor)
  opts.render(lines, {
    line = math.min(math.max(input_cursor.line, 1), #lines),
    col = input_cursor.col,
  })
end

function M.insert_newline(state, opts)
  if not opts.valid_win(state.input_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local lines = opts.read()
  local input_cursor = opts.logical_cursor(cursor)
  local input_line = math.min(math.max(input_cursor.line, 1), #lines)
  local value = lines[input_line] or ""
  local col = math.min(math.max(input_cursor.col, 0), #value)
  lines[input_line] = value:sub(1, col)
  table.insert(lines, input_line + 1, value:sub(col + 1))
  opts.render(lines, { line = input_line + 1, col = 0 })
  if lines[input_line + 1] == "" then
    vim.cmd("startinsert!")
  else
    vim.cmd("startinsert")
  end
end

function M.delete_backwards(state, opts)
  if not opts.valid_win(state.input_win) then
    return ""
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local lines = opts.read()
  local input_cursor = opts.logical_cursor(cursor)
  local input_line = math.min(math.max(input_cursor.line, 1), #lines)
  local value = lines[input_line] or ""
  local col = math.min(math.max(input_cursor.col, 0), #value)

  for _, range in ipairs(attachments.ranges(state, value)) do
    if col > range.from and col <= range.to then
      lines[input_line] = value:sub(1, range.from) .. value:sub(range.to + 1)
      for index, attachment in ipairs(state.input_attachments) do
        if attachment == range.attachment then
          table.remove(state.input_attachments, index)
          break
        end
      end
      opts.render(lines, { line = input_line, col = range.from })
      opts.render_activity()
      return ""
    end
  end

  if col > 0 then
    local start_col = previous_char_start(value, col)
    lines[input_line] = value:sub(1, start_col) .. value:sub(col + 1)
    opts.render(lines, { line = input_line, col = start_col })
  elseif input_line > 1 then
    local previous = lines[input_line - 1] or ""
    lines[input_line - 1] = previous .. value
    table.remove(lines, input_line)
    opts.render(lines, { line = input_line - 1, col = #previous })
  else
    opts.render(lines, { line = 1, col = 0 })
  end

  return ""
end

return M
