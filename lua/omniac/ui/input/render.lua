local text = require("omniac.ui.text")

local M = {}

local PROMPT = "│ > "
local CONTINUATION = "│ "
local MIN_LINES = 3
local MAX_LINES = 10

function M.display_height(lines)
  return math.min(MAX_LINES, math.max(MIN_LINES, #lines)) + 2
end

local function content_width(win_width, prefix)
  return math.max(1, win_width - vim.fn.strdisplaywidth(prefix or PROMPT) - 3)
end

local function strip_prefix(line, index)
  local prefix = index == 1 and PROMPT or CONTINUATION
  if line:sub(1, #prefix) == prefix then
    return line:sub(#prefix + 1)
  end
  if prefix:sub(1, #line) == line then
    return ""
  end
  if line:sub(1, #"│") == "│" then
    return (line:gsub("^│%s*", "", 1))
  end
  return line
end

function M.read(state, valid_buf)
  if not valid_buf(state.input_buf) then
    return { "" }
  end
  local buffer_lines = vim.api.nvim_buf_get_lines(state.input_buf, 1, -1, false)
  if #buffer_lines > 0 then
    table.remove(buffer_lines)
  end
  if #buffer_lines == 0 then
    return { "" }
  end

  if state.input_chunks and #state.input_chunks == #buffer_lines then
    local result = {}
    for index, line in ipairs(buffer_lines) do
      local chunk = state.input_chunks[index]
      if not chunk.padding then
        result[chunk.source_line] = (result[chunk.source_line] or "") .. strip_prefix(line, index)
      end
    end
    return #result > 0 and result or { "" }
  end

  local result = {}
  for index, line in ipairs(buffer_lines) do
    table.insert(result, strip_prefix(line, index))
  end
  return result
end

local function wrap(lines, cursor, win_width, attachment_ranges)
  local wrapped_lines = {}
  local chunks = {}
  for line_index, line in ipairs(lines) do
    if line == "" then
      table.insert(wrapped_lines, "")
      table.insert(chunks, { source_line = line_index, start_col = 0, end_col = 0 })
    else
      local current, current_width, current_start, byte_col = "", 0, 0, 0
      local ranges = attachment_ranges(line)
      local range_index = 1
      while byte_col < #line do
        local range = ranges[range_index]
        local char
        if range and range.from == byte_col then
          char = line:sub(range.from + 1, range.to)
          range_index = range_index + 1
        else
          char = line:sub(byte_col + 1):match("^[%z\1-\127\194-\244][\128-\191]*")
        end
        local prefix = #wrapped_lines == 0 and PROMPT or CONTINUATION
        local char_width = vim.fn.strdisplaywidth(char)
        if current ~= "" and current_width + char_width > content_width(win_width, prefix) then
          table.insert(wrapped_lines, current)
          table.insert(chunks, { source_line = line_index, start_col = current_start, end_col = byte_col })
          current, current_width, current_start = char, char_width, byte_col
        else
          current = current .. char
          current_width = current_width + char_width
        end
        byte_col = byte_col + #char
      end
      table.insert(wrapped_lines, current)
      table.insert(chunks, { source_line = line_index, start_col = current_start, end_col = #line })
    end
  end

  local wrapped_cursor
  if cursor then
    for index, chunk in ipairs(chunks) do
      if cursor.line == chunk.source_line and cursor.col >= chunk.start_col and cursor.col <= chunk.end_col then
        wrapped_cursor = { line = index, col = cursor.col - chunk.start_col }
        break
      end
    end
  end
  return wrapped_lines, wrapped_cursor or cursor, chunks
end

function M.reset(state, opts)
  if not opts.valid_buf(state.input_buf) then
    return
  end
  opts.clear_history()
  M.render(state, { "" }, nil, vim.tbl_extend("force", {}, opts, { skip_command_window = true }))
end

function M.render(state, lines, cursor, opts)
  opts = opts or {}
  if not opts.valid_buf(state.input_buf) then
    return
  end
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if not lines or #lines == 0 then
    lines = { "" }
  end
  local source_lines = vim.deepcopy(lines)
  local win_width = opts.valid_win(state.input_win) and vim.api.nvim_win_get_width(state.input_win) or opts.width()
  local chunks
  lines, cursor, chunks = wrap(lines, cursor, win_width, opts.attachment_ranges)
  local display_line_count = math.max(MIN_LINES, #lines)
  local buffer_lines = { text.box_line("╭", "─", "╮", win_width) }
  for index = 1, display_line_count do
    local line = lines[index] or ""
    table.insert(buffer_lines, (index == 1 and PROMPT or CONTINUATION) .. line)
    if not chunks[index] then
      chunks[index] = { padding = true }
    end
  end
  table.insert(buffer_lines, text.box_line("╰", "─", "╯", win_width))

  state.rendering_input = true
  vim.bo[state.input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, buffer_lines)
  vim.api.nvim_buf_clear_namespace(state.input_buf, opts.namespace, 0, -1)
  opts.add_hl(state.input_buf, 1, 0, -1, "OmniacBorder")
  for index = 1, display_line_count do
    local line_number = index + 1
    local prefix = index == 1 and PROMPT or CONTINUATION
    vim.api.nvim_buf_set_extmark(state.input_buf, opts.namespace, line_number - 1, 0, {
      line_hl_group = "OmniacInput",
    })
    vim.api.nvim_buf_set_extmark(state.input_buf, opts.namespace, line_number - 1, 0, {
      virt_text = { { "│", "OmniacBorder" } },
      virt_text_pos = "overlay",
      virt_text_win_col = win_width - 1,
    })
    opts.add_hl(state.input_buf, line_number, 0, #"│", "OmniacBorder")
    if index == 1 then
      opts.add_hl(state.input_buf, line_number, #"│", #prefix, "OmniacInputPrompt")
    end
    opts.add_hl(state.input_buf, line_number, #prefix, -1, "OmniacInputText")
    local chunk = chunks[index]
    if chunk and not chunk.padding then
      for _, range in ipairs(opts.attachment_ranges(source_lines[chunk.source_line] or "")) do
        local from = math.max(range.from, chunk.start_col or 0)
        local to = math.min(range.to, chunk.end_col or 0)
        if from < to then
          opts.add_hl(
            state.input_buf,
            line_number,
            #prefix + from - (chunk.start_col or 0),
            #prefix + to - (chunk.start_col or 0),
            "OmniacAttachment"
          )
        end
      end
    end
  end
  opts.add_hl(state.input_buf, #buffer_lines, 0, -1, "OmniacBorder")
  vim.bo[state.input_buf].modified = false
  state.rendering_input = false
  state.input_chunks = chunks

  if opts.valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_height, state.input_win, math.min(MAX_LINES, display_line_count) + 2)
    if cursor and vim.api.nvim_get_current_buf() == state.input_buf then
      local cursor_line = math.min(math.max(cursor.line or 1, 1), #lines)
      local prefix = cursor_line == 1 and PROMPT or CONTINUATION
      local cursor_col = math.min(math.max(cursor.col or 0, 0), #(lines[cursor_line] or ""))
      pcall(vim.api.nvim_win_set_cursor, state.input_win, { cursor_line + 1, #prefix + cursor_col })
    end
    opts.reset_leftcol(state.input_win)
  end
  if opts.update_completion and not opts.skip_command_window then
    opts.update_completion()
  end
end

function M.logical_cursor(state, cursor, read)
  local input_line = math.max(cursor[1] - 1, 1)
  local chunks = state.input_chunks
  if chunks and chunks[input_line] then
    local chunk = chunks[input_line]
    if chunk.padding then
      local lines = read()
      local last_line = math.max(1, #lines)
      return { line = last_line, col = #(lines[last_line] or "") }
    end
    local prefix = input_line == 1 and PROMPT or CONTINUATION
    return { line = chunk.source_line, col = math.max(0, cursor[2] - #prefix) + (chunk.start_col or 0) }
  end
  local prefix = input_line == 1 and PROMPT or CONTINUATION
  return { line = input_line, col = math.max(0, cursor[2] - #prefix) }
end

return M
