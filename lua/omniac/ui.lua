local M = {}

local ns = vim.api.nvim_create_namespace("omniac.ui")
local augroup = vim.api.nvim_create_augroup("omniac.ui", { clear = false })

local state = {
  chat_buf = nil,
  chat_win = nil,
  activity_buf = nil,
  activity_win = nil,
  input_buf = nil,
  input_win = nil,
  status_buf = nil,
  status_win = nil,
  status = "idle",
  activity_timer = nil,
  activity_frame = 1,
  tool_activity = nil,
  messages = {},
  streaming_message_index = nil,
  config = nil,
  submit = nil,
  rendering_input = false,
  input_chunks = nil,
}

local INPUT_MAX_DISPLAY_LINES = 10
local INPUT_PROMPT = "│ > "
local INPUT_CONTINUATION = "│ "

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function width(config)
  local value = ((config or {}).ui or {}).chat_width or 58
  return math.min(math.max(value, 42), math.max(42, vim.o.columns - 20))
end

local function agent_name(config)
  local cmd = ((config or state.config or {}).agent or {}).cmd or {}
  if type(cmd) == "table" then
    return cmd[1] or "agent"
  end
  return tostring(cmd ~= "" and cmd or "agent")
end

local function center(text, size)
  local display_width = vim.fn.strdisplaywidth(text)
  local pad = math.max(0, math.floor((size - display_width) / 2))
  return string.rep(" ", pad) .. text
end

local function fit(text, size)
  local value = tostring(text or "")
  local current = vim.fn.strdisplaywidth(value)
  if current > size then
    local out = ""
    for char in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if vim.fn.strdisplaywidth(out .. char) > size - 1 then
        return out .. "…"
      end
      out = out .. char
    end
    return out
  end
  return value .. string.rep(" ", size - current)
end

local function chars(text)
  return tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

local function box_line(left, fill, right, size)
  return left .. string.rep(fill, math.max(0, size - 2)) .. right
end

local function boxed_text(text, size)
  return "│" .. fit(center(text, size - 2), size - 2) .. "│"
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "OmniacTitle", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacBorder", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "OmniacMuted", { fg = "#7f849c" })
  vim.api.nvim_set_hl(0, "OmniacAccent", { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "OmniacGraphic", { fg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacGraphicShade", { fg = "#89dceb" })
  vim.api.nvim_set_hl(0, "OmniacUser", { fg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "OmniacUserBubble", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacAssistant", { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacAssistantText", { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "OmniacError", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking1", { fg = "#585b70", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking2", { fg = "#7f849c", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking3", { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking4", { fg = "#f5c2e7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacInput", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacInputPrompt", { fg = "#89b4fa", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusMode", { fg = "#11111b", bg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatus", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsule", { fg = "#11111b", bg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsuleEdge", { fg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusModeEdge", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsuleAlt", { fg = "#cdd6f4", bg = "#45475a", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsuleAltEdge", { fg = "#45475a", bold = true })
end

local function add_hl(buf, line, start_col, end_col, group)
  if valid_buf(buf) then
    vim.api.nvim_buf_add_highlight(buf, ns, group, line - 1, start_col, end_col)
  end
end

local function add_line(lines, marks, text, group)
  table.insert(lines, text)
  if group then
    table.insert(marks, { line = #lines, from = 0, to = -1, group = group })
  end
end

local function add_mark(marks, line, from, to, group)
  table.insert(marks, { line = line, from = from, to = to, group = group })
end

local function add_boxed_line(lines, marks, text, size, group)
  local line = boxed_text(text, size)
  table.insert(lines, line)
  local lnum = #lines
  local border_width = #"│"
  add_mark(marks, lnum, 0, border_width, "OmniacBorder")
  add_mark(marks, lnum, #line - border_width, -1, "OmniacBorder")
  if group then
    add_mark(marks, lnum, border_width, #line - border_width, group)
  end
end

local function start_chat_treesitter()
  if not valid_buf(state.chat_buf) or not (vim.treesitter and vim.treesitter.start) then
    return
  end

  pcall(vim.treesitter.start, state.chat_buf, "markdown")
end

local function wrapped(text, max_width)
  local result = {}
  for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      table.insert(result, "")
    else
      local current = ""
      for char in chars(raw) do
        if vim.fn.strdisplaywidth(current .. char) > max_width and current ~= "" then
          table.insert(result, current)
          current = char
        else
          current = current .. char
        end
      end
      if current ~= "" then
        table.insert(result, current)
      end
    end
  end
  if result[#result] == "" then
    table.remove(result)
  end
  return result
end

local function wrapped_blocks(text, max_width, keep_trailing_empty)
  local blocks = {}
  local in_code = false
  for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local is_fence = raw:match("^%s*```") or raw:match("^%s*~~~")
    local code = in_code or is_fence
    local block = wrapped(raw, max_width)
    if #block == 0 then
      block = { "" }
    end
    table.insert(blocks, {
      lines = block,
      code = code,
      empty = #block == 1 and block[1] == "",
    })
    if is_fence then
      in_code = not in_code
    end
  end
  if not keep_trailing_empty and #blocks > 0 and blocks[#blocks].empty then
    table.remove(blocks)
  end
  return blocks
end

local function header(lines, marks, size)
  local box_width = math.max(40, size)
  local inner = box_width - 2
  local user = vim.env.USER or "there"
  local title = "Omniac Code"
  local top = "╭─ "
    .. title
    .. " "
    .. string.rep("─", math.max(0, box_width - vim.fn.strdisplaywidth(title) - 5))
    .. "╮"
  local bottom = box_line("╰", "─", "╯", box_width)

  add_line(lines, marks, top, "OmniacBorder")
  add_boxed_line(lines, marks, "", box_width, nil)
  add_boxed_line(lines, marks, "Welcome back " .. user .. "!", box_width, "OmniacAccent")
  add_boxed_line(lines, marks, "", box_width, nil)

  local graphic = {
    "        ▄▄▄▄▄▄▄        ",
    "     ▄███████████▄     ",
    "   ▄██▀  ▀███▀  ▀██▄   ",
    "   ██    ▄███▄    ██   ",
    "   ▀██▄  ▀▀▀▀▀  ▄██▀   ",
    "      ▀█████████▀      ",
    "       ▀▀  ▀  ▀▀       ",
  }
  for _, line in ipairs(graphic) do
    add_boxed_line(lines, marks, line, box_width, "OmniacGraphic")
  end

  add_boxed_line(lines, marks, "", box_width, nil)
  add_boxed_line(
    lines,
    marks,
    agent_name(state.config) .. " / " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"),
    box_width,
    "OmniacMuted"
  )
  add_line(lines, marks, bottom, "OmniacBorder")
end

local function render_chat(config)
  state.config = config or state.config
  if not valid_buf(state.chat_buf) then
    return
  end

  local win_width = valid_win(state.chat_win) and vim.api.nvim_win_get_width(state.chat_win) or width(state.config)
  local text_width = math.max(28, win_width - 6)
  local lines = {}
  local marks = {}

  header(lines, marks, win_width)
  add_line(lines, marks, "", nil)

  if #state.messages == 0 then
    add_line(lines, marks, box_line("╭", "─", "╮", win_width), "OmniacBorder")
    add_boxed_line(
      lines,
      marks,
      "Agent: " .. agent_name(state.config) .. "  •  Status: " .. state.status,
      win_width,
      "OmniacAccent"
    )
    add_boxed_line(lines, marks, "cwd: " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"), win_width, "OmniacMuted")
    add_line(lines, marks, box_line("╰", "─", "╯", win_width), "OmniacBorder")
  else
    for _, message in ipairs(state.messages) do
      local group = message.role == "You" and "OmniacUserBubble" or nil
      if message.role == "Error" then
        group = "OmniacError"
      end

      if message.role == "You" then
        for _, line in ipairs(wrapped(message.text, text_width)) do
          add_line(lines, marks, "  " .. fit(line, win_width - 4) .. "  ", group)
        end
      else
        local blocks = wrapped_blocks(message.text, text_width, message.complete)
        for block_index, block in ipairs(blocks) do
          local block_group = block.code and nil or group
          for _, line in ipairs(block.lines) do
            add_line(lines, marks, "  " .. fit(line, win_width - 4) .. "  ", block_group)
          end
        end
        if message.complete then
          add_line(
            lines,
            marks,
            "  " .. fit(string.rep("─", math.max(0, win_width - 4)), win_width - 4) .. "  ",
            "OmniacMuted"
          )
        end
      end
      add_line(lines, marks, "", nil)
    end
  end

  vim.bo[state.chat_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.chat_buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, lines)
  vim.bo[state.chat_buf].modifiable = false
  vim.bo[state.chat_buf].modified = false
  start_chat_treesitter()

  for _, mark in ipairs(marks) do
    add_hl(state.chat_buf, mark.line, mark.from, mark.to, mark.group)
  end

  if valid_win(state.chat_win) and #lines > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { #lines, 0 })
  end
end

local function render_status()
  if not valid_buf(state.status_buf) then
    return
  end

  local win_width = valid_win(state.status_win) and vim.api.nvim_win_get_width(state.status_win) or width(state.config)
  local left = " Omniac "
  local middle = "  " .. state.status .. " "
  local right = "  " .. agent_name(state.config) .. " "
  local spacer = string.rep(" ", math.max(1, win_width - vim.fn.strdisplaywidth(left .. middle .. right)))
  local line = left .. middle .. spacer .. right

  vim.bo[state.status_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.status_buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.status_buf, 0, -1, false, { fit(line, win_width) })
  vim.bo[state.status_buf].modifiable = false
  vim.bo[state.status_buf].modified = false

  local col = 0
  local function add_capsule(text, fill_group, edge_group)
    add_hl(state.status_buf, 1, col, col + #"", edge_group)
    col = col + #""
    add_hl(state.status_buf, 1, col, col + #text, fill_group)
    col = col + #text
    add_hl(state.status_buf, 1, col, col + #"", edge_group)
    col = col + #""
  end

  add_capsule(" Omniac ", "OmniacStatusCapsule", "OmniacStatusCapsuleEdge")
  col = col + #" "
  add_capsule(" " .. state.status .. " ", "OmniacStatusMode", "OmniacStatusModeEdge")
  col = col + #spacer + #" "
  add_capsule(" " .. agent_name(state.config) .. " ", "OmniacStatusCapsuleAlt", "OmniacStatusCapsuleAltEdge")
end

local function render_activity()
  if not valid_buf(state.activity_buf) then
    return
  end

  local win_width = valid_win(state.activity_win) and vim.api.nvim_win_get_width(state.activity_win)
    or width(state.config)
  local frames = {
    "Working",
    "Working.",
    "Working..",
    "Working...",
  }
  local groups = {
    "OmniacWorking1",
    "OmniacWorking2",
    "OmniacWorking3",
    "OmniacWorking4",
  }
  local text = ""
  if state.status == "working" and state.tool_activity then
    text = state.tool_activity
  elseif state.status == "working" then
    text = frames[state.activity_frame]
  elseif state.status == "connecting" then
    text = "Connecting..."
  end
  local line = ""
  if text ~= "" then
    local inner_width = math.max(1, win_width - 4)
    local display = fit(text, inner_width)
    local padded = vim.fn.strdisplaywidth(text) > inner_width and display or center(display, inner_width)
    line = "  " .. padded .. "  "
  end

  vim.bo[state.activity_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.activity_buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.activity_buf, 0, -1, false, { line })
  vim.bo[state.activity_buf].modifiable = false
  vim.bo[state.activity_buf].modified = false

  if text ~= "" then
    add_hl(state.activity_buf, 1, 0, -1, groups[state.activity_frame])
  end
end

local function stop_activity_timer()
  if state.activity_timer then
    state.activity_timer:stop()
    state.activity_timer:close()
    state.activity_timer = nil
  end
end

local function sync_activity_timer()
  if state.status ~= "working" then
    stop_activity_timer()
    state.activity_frame = 1
    render_activity()
    return
  end

  if state.activity_timer then
    return
  end

  local uv = vim.uv or vim.loop
  state.activity_timer = uv.new_timer()
  state.activity_timer:start(
    0,
    180,
    vim.schedule_wrap(function()
      state.activity_frame = (state.activity_frame % 4) + 1
      render_activity()
    end)
  )
end

local function reset_input()
  if not valid_buf(state.input_buf) then
    return
  end

  local win_width = valid_win(state.input_win) and vim.api.nvim_win_get_width(state.input_win) or width(state.config)
  state.rendering_input = true
  vim.bo[state.input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {
    box_line("╭", "─", "╮", win_width),
    INPUT_PROMPT,
    box_line("╰", "─", "╯", win_width),
  })
  vim.api.nvim_buf_clear_namespace(state.input_buf, ns, 0, -1)
  add_hl(state.input_buf, 1, 0, -1, "OmniacBorder")
  vim.api.nvim_buf_set_extmark(state.input_buf, ns, 1, 0, {
    line_hl_group = "OmniacInput",
  })
  vim.api.nvim_buf_set_extmark(state.input_buf, ns, 1, 0, {
    virt_text = { { "│", "OmniacBorder" } },
    virt_text_pos = "overlay",
    virt_text_win_col = win_width - 1,
  })
  add_hl(state.input_buf, 2, 0, #"│", "OmniacBorder")
  add_hl(state.input_buf, 2, #"│", #INPUT_PROMPT, "OmniacInputPrompt")
  add_hl(state.input_buf, 3, 0, -1, "OmniacBorder")
  vim.bo[state.input_buf].modified = false
  state.rendering_input = false
  state.input_chunks = { { source_line = 1, start_col = 0, end_col = 0 } }
  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_height, state.input_win, 3)
  end
end

local function strip_input_prefix(line, index)
  local prefix = index == 1 and INPUT_PROMPT or INPUT_CONTINUATION
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

local function previous_char_start(text, col)
  local last_start = 0
  local byte_col = 0

  for char in chars(text) do
    local next_col = byte_col + #char
    if next_col >= col then
      return byte_col
    end
    last_start = byte_col
    byte_col = next_col
  end

  return last_start
end

local function raw_input_lines()
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
      local source_line = state.input_chunks[index].source_line
      result[source_line] = (result[source_line] or "") .. strip_input_prefix(line, index)
    end
    return result
  end

  local result = {}
  for index, line in ipairs(buffer_lines) do
    table.insert(result, strip_input_prefix(line, index))
  end
  return result
end

local function raw_input_text()
  return table.concat(raw_input_lines(), "\n")
end

local function input_text()
  return (raw_input_text():gsub("^%s+", ""):gsub("%s+$", ""))
end

local function input_content_width(win_width, prefix)
  return math.max(1, win_width - vim.fn.strdisplaywidth(prefix or INPUT_PROMPT) - 3)
end

local function input_display_height(lines, win_width)
  return math.min(INPUT_MAX_DISPLAY_LINES, math.max(1, #lines)) + 2
end

local function wrap_input_lines(lines, cursor, win_width)
  local wrapped_lines = {}
  local chunks = {}

  for line_index, line in ipairs(lines) do
    if line == "" then
      table.insert(wrapped_lines, "")
      table.insert(chunks, { source_line = line_index, start_col = 0, end_col = 0 })
    else
      local current = ""
      local current_width = 0
      local current_start = 0
      local byte_col = 0

      for char in chars(line) do
        local prefix = #wrapped_lines == 0 and INPUT_PROMPT or INPUT_CONTINUATION
        local max_width = input_content_width(win_width, prefix)
        local char_width = vim.fn.strdisplaywidth(char)
        if current ~= "" and current_width + char_width > max_width then
          table.insert(wrapped_lines, current)
          table.insert(chunks, { source_line = line_index, start_col = current_start, end_col = byte_col })
          current = char
          current_width = char_width
          current_start = byte_col
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
        wrapped_cursor = {
          line = index,
          col = cursor.col - chunk.start_col,
        }
        break
      end
    end
  end

  return wrapped_lines, wrapped_cursor or cursor, chunks
end

local reset_leftcol

local function render_input(lines, cursor)
  if not valid_buf(state.input_buf) then
    return
  end

  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if not lines or #lines == 0 then
    lines = { "" }
  end

  local win_width = valid_win(state.input_win) and vim.api.nvim_win_get_width(state.input_win) or width(state.config)
  local chunks
  lines, cursor, chunks = wrap_input_lines(lines, cursor, win_width)
  local buffer_lines = { box_line("╭", "─", "╮", win_width) }
  for index, line in ipairs(lines) do
    table.insert(buffer_lines, (index == 1 and INPUT_PROMPT or INPUT_CONTINUATION) .. line)
  end
  table.insert(buffer_lines, box_line("╰", "─", "╯", win_width))

  state.rendering_input = true
  vim.bo[state.input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, buffer_lines)
  vim.api.nvim_buf_clear_namespace(state.input_buf, ns, 0, -1)
  add_hl(state.input_buf, 1, 0, -1, "OmniacBorder")
  for index = 1, #lines do
    local line_number = index + 1
    local prefix = index == 1 and INPUT_PROMPT or INPUT_CONTINUATION
    vim.api.nvim_buf_set_extmark(state.input_buf, ns, line_number - 1, 0, {
      line_hl_group = "OmniacInput",
    })
    vim.api.nvim_buf_set_extmark(state.input_buf, ns, line_number - 1, 0, {
      virt_text = { { "│", "OmniacBorder" } },
      virt_text_pos = "overlay",
      virt_text_win_col = win_width - 1,
    })
    add_hl(state.input_buf, line_number, 0, #"│", "OmniacBorder")
    if index == 1 then
      add_hl(state.input_buf, line_number, #"│", #prefix, "OmniacInputPrompt")
    end
  end
  add_hl(state.input_buf, #buffer_lines, 0, -1, "OmniacBorder")
  vim.bo[state.input_buf].modified = false
  state.rendering_input = false
  state.input_chunks = chunks

  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_height, state.input_win, input_display_height(lines, win_width))
    if cursor and vim.api.nvim_get_current_buf() == state.input_buf then
      local cursor_line = math.min(math.max(cursor.line or 1, 1), #lines)
      local prefix = cursor_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
      local cursor_col = math.min(math.max(cursor.col or 0, 0), #(lines[cursor_line] or ""))
      pcall(vim.api.nvim_win_set_cursor, state.input_win, { cursor_line + 1, #prefix + cursor_col })
    end
    reset_leftcol(state.input_win)
  end
end

local function logical_cursor_from_display(cursor)
  local input_line = math.max(cursor[1] - 1, 1)
  local chunks = state.input_chunks
  if chunks and chunks[input_line] then
    local chunk = chunks[input_line]
    local prefix = input_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
    return {
      line = chunk.source_line,
      col = math.max(0, cursor[2] - #prefix) + chunk.start_col,
    }
  end

  local prefix = input_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
  return {
    line = input_line,
    col = math.max(0, cursor[2] - #prefix),
  }
end

local function clamp_input_cursor()
  if state.rendering_input or not valid_win(state.input_win) or not valid_buf(state.input_buf) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local buffer_line_count = vim.api.nvim_buf_line_count(state.input_buf)
  local input_line_count = math.max(1, buffer_line_count - 2)
  local input_line = math.min(math.max(cursor[1] - 1, 1), input_line_count)
  local prefix = input_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
  local row = input_line + 1
  local col = math.max(cursor[2], #prefix)

  if cursor[1] ~= row or cursor[2] ~= col then
    pcall(vim.api.nvim_win_set_cursor, state.input_win, { row, col })
  end
end

local function focus_input()
  if not valid_win(state.input_win) then
    return
  end

  vim.api.nvim_set_current_win(state.input_win)
  local lines = raw_input_lines()
  local line = math.max(1, #lines)
  render_input(lines, {
    line = line,
    col = #(lines[line] or ""),
  })
  vim.cmd("startinsert!")
end

local function enforce_input()
  if state.rendering_input or not valid_buf(state.input_buf) then
    return
  end

  clamp_input_cursor()
  local cursor = valid_win(state.input_win) and vim.api.nvim_win_get_cursor(state.input_win) or { 2, #INPUT_PROMPT }
  local lines = raw_input_lines()
  local input_cursor = logical_cursor_from_display(cursor)
  render_input(lines, {
    line = math.min(math.max(input_cursor.line, 1), #lines),
    col = input_cursor.col,
  })
end

local function insert_input_newline()
  if not valid_win(state.input_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local lines = raw_input_lines()
  local input_cursor = logical_cursor_from_display(cursor)
  local input_line = math.min(math.max(input_cursor.line, 1), #lines)
  local text = lines[input_line] or ""
  local col = math.min(math.max(input_cursor.col, 0), #text)
  lines[input_line] = text:sub(1, col)
  table.insert(lines, input_line + 1, text:sub(col + 1))
  render_input(lines, { line = input_line + 1, col = 0 })
  if lines[input_line + 1] == "" then
    vim.cmd("startinsert!")
  else
    vim.cmd("startinsert")
  end
end

local function delete_input_backwards()
  if not valid_win(state.input_win) then
    return ""
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local lines = raw_input_lines()
  local input_cursor = logical_cursor_from_display(cursor)
  local input_line = math.min(math.max(input_cursor.line, 1), #lines)
  local text = lines[input_line] or ""
  local col = math.min(math.max(input_cursor.col, 0), #text)

  if col > 0 then
    local start_col = previous_char_start(text, col)
    lines[input_line] = text:sub(1, start_col) .. text:sub(col + 1)
    render_input(lines, { line = input_line, col = start_col })
  elseif input_line > 1 then
    local previous = lines[input_line - 1] or ""
    lines[input_line - 1] = previous .. text
    table.remove(lines, input_line)
    render_input(lines, { line = input_line - 1, col = #previous })
  else
    render_input(lines, { line = 1, col = 0 })
  end

  return ""
end

local function configure_window(win)
  vim.w[win].omniac_ui = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  vim.wo[win].list = false
end

reset_leftcol = function(win)
  if not valid_win(win) then
    return
  end

  pcall(vim.api.nvim_win_call, win, function()
    vim.fn.winrestview({ leftcol = 0 })
  end)
end

local function open_split_with_buffer(command, buf)
  vim.cmd(command .. " sbuffer " .. buf)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buflisted = false
  return win
end

local function resize_aux_windows()
  local target_width = width(state.config)
  if valid_win(state.chat_win) then
    pcall(vim.api.nvim_win_set_width, state.chat_win, target_width)
  end
  if valid_win(state.status_win) then
    pcall(vim.api.nvim_win_set_width, state.status_win, target_width)
    pcall(vim.api.nvim_win_set_height, state.status_win, 1)
  end
  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_width, state.input_win, target_width)
    pcall(vim.api.nvim_win_set_height, state.input_win, input_display_height(raw_input_lines(), target_width))
    reset_leftcol(state.input_win)
  end
  if valid_win(state.activity_win) then
    pcall(vim.api.nvim_win_set_width, state.activity_win, target_width)
    pcall(vim.api.nvim_win_set_height, state.activity_win, 1)
  end
end

function M.open(config, submit)
  setup_highlights()
  state.config = config or state.config
  state.submit = submit or state.submit

  if
    valid_win(state.chat_win)
    and valid_win(state.activity_win)
    and valid_win(state.input_win)
    and valid_win(state.status_win)
  then
    resize_aux_windows()
    focus_input()
    return state
  end

  if not valid_buf(state.chat_buf) then
    state.chat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.chat_buf].buftype = "nofile"
    vim.bo[state.chat_buf].bufhidden = "hide"
    vim.bo[state.chat_buf].swapfile = false
    vim.bo[state.chat_buf].buflisted = false
    vim.bo[state.chat_buf].filetype = "omniac"
    vim.bo[state.chat_buf].syntax = "markdown"
    vim.api.nvim_buf_set_name(state.chat_buf, "omniac")
  end

  if not valid_buf(state.input_buf) then
    state.input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.input_buf].buftype = "nofile"
    vim.bo[state.input_buf].bufhidden = "hide"
    vim.bo[state.input_buf].swapfile = false
    vim.bo[state.input_buf].buflisted = false
    vim.bo[state.input_buf].filetype = "omniac-input"
    vim.api.nvim_buf_set_name(state.input_buf, "omniac://input")
  end

  if not valid_buf(state.activity_buf) then
    state.activity_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.activity_buf].buftype = "nofile"
    vim.bo[state.activity_buf].bufhidden = "hide"
    vim.bo[state.activity_buf].swapfile = false
    vim.bo[state.activity_buf].buflisted = false
    vim.bo[state.activity_buf].filetype = "omniac-activity"
    vim.api.nvim_buf_set_name(state.activity_buf, "omniac://activity")
  end

  if not valid_buf(state.status_buf) then
    state.status_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.status_buf].buftype = "nofile"
    vim.bo[state.status_buf].bufhidden = "hide"
    vim.bo[state.status_buf].swapfile = false
    vim.bo[state.status_buf].buflisted = false
    vim.bo[state.status_buf].filetype = "omniac-status"
    vim.api.nvim_buf_set_name(state.status_buf, "omniac://status")
  end

  state.chat_win = open_split_with_buffer("botright vertical", state.chat_buf)
  configure_window(state.chat_win)
  pcall(vim.api.nvim_win_set_width, state.chat_win, width(state.config))
  vim.wo[state.chat_win].winfixwidth = true
  vim.wo[state.chat_win].statusline = "%!v:lua.require'omniac.ui'.statusline()"

  state.activity_win = open_split_with_buffer("belowright", state.activity_buf)
  configure_window(state.activity_win)
  vim.wo[state.activity_win].winfixwidth = true
  vim.wo[state.activity_win].winfixheight = true
  pcall(vim.api.nvim_win_set_height, state.activity_win, 1)
  vim.wo[state.activity_win].statusline = "%#OmniacStatus#%="

  state.input_win = open_split_with_buffer("belowright", state.input_buf)
  configure_window(state.input_win)
  vim.wo[state.input_win].winfixwidth = true
  vim.wo[state.input_win].winfixheight = true
  vim.wo[state.input_win].wrap = true
  pcall(vim.api.nvim_win_set_height, state.input_win, 3)
  vim.wo[state.input_win].statusline = "%#OmniacStatus#%="

  state.status_win = open_split_with_buffer("belowright", state.status_buf)
  configure_window(state.status_win)
  vim.wo[state.status_win].winfixwidth = true
  vim.wo[state.status_win].winfixheight = true
  pcall(vim.api.nvim_win_set_height, state.status_win, 1)
  vim.wo[state.status_win].statusline = "%#OmniacStatus#%="
  resize_aux_windows()

  vim.keymap.set({ "n", "i" }, "<CR>", function()
    local text = input_text()
    if text == "" then
      reset_input()
      focus_input()
      return
    end
    reset_input()
    if state.submit then
      state.submit(text)
    end
  end, { buffer = state.input_buf, nowait = true, desc = "Send Omniac prompt" })

  vim.keymap.set({ "n", "i" }, "<S-CR>", insert_input_newline, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Insert newline in Omniac prompt",
  })
  vim.keymap.set({ "n", "i" }, "<S-Enter>", insert_input_newline, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Insert newline in Omniac prompt",
  })
  vim.keymap.set("i", "<BS>", delete_input_backwards, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Delete Omniac input character",
  })

  for _, buf in ipairs({ state.chat_buf, state.activity_buf, state.status_buf }) do
    vim.keymap.set("n", "i", focus_input, { buffer = buf, nowait = true, desc = "Focus Omniac input" })
  end

  vim.keymap.set("n", "q", function()
    stop_activity_timer()
    if valid_win(state.input_win) then
      vim.api.nvim_win_close(state.input_win, true)
    end
    if valid_win(state.activity_win) then
      vim.api.nvim_win_close(state.activity_win, true)
    end
    if valid_win(state.status_win) then
      vim.api.nvim_win_close(state.status_win, true)
    end
    if valid_win(state.chat_win) then
      vim.api.nvim_win_close(state.chat_win, true)
    end
  end, { buffer = state.input_buf, nowait = true, desc = "Close Omniac chat" })

  vim.api.nvim_clear_autocmds({ group = augroup, buffer = state.input_buf })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = augroup,
    buffer = state.input_buf,
    callback = enforce_input,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "InsertCharPre" }, {
    group = augroup,
    buffer = state.input_buf,
    callback = clamp_input_cursor,
  })

  render_chat(state.config)
  render_activity()
  reset_input()
  render_status()
  sync_activity_timer()
  focus_input()
  return state
end

function M.set_status(status, config)
  state.status = status or "idle"
  if state.status ~= "working" then
    state.tool_activity = nil
  end
  render_chat(config)
  render_activity()
  render_status()
  sync_activity_timer()
end

function M.set_tool_activity(params, config)
  params = params or {}
  local status = params.status or "running"
  local kind = params.kind or "tool"
  local title = params.title or kind
  local prefix = "Running"

  if status == "completed" then
    prefix = "Completed"
  elseif status == "failed" then
    prefix = "Failed"
  elseif status == "pending" then
    prefix = "Pending"
  elseif status == "in_progress" then
    prefix = "Running"
  end

  local exit = params.exitCode ~= nil and (" exit " .. tostring(params.exitCode)) or ""
  state.tool_activity = string.format("%s %s: %s%s", prefix, kind, title, exit)
  render_activity()
end

function M.add_message(role, text, config)
  table.insert(state.messages, {
    role = role,
    text = text or "",
  })
  if role ~= "Omniac" then
    state.streaming_message_index = nil
  end
  render_chat(config)
  focus_input()
end

function M.append_response_chunk(text, config)
  if not text or text == "" then
    return
  end

  local index = state.streaming_message_index
  if not index or not state.messages[index] or state.messages[index].role ~= "Omniac" then
    table.insert(state.messages, {
      role = "Omniac",
      text = "",
      complete = false,
    })
    index = #state.messages
    state.streaming_message_index = index
  end

  state.messages[index].complete = false
  state.messages[index].text = (state.messages[index].text or "") .. text
  render_chat(config)
end

function M.complete_response(config)
  local index = state.streaming_message_index
  if index and state.messages[index] and state.messages[index].role == "Omniac" then
    state.messages[index].complete = true
    render_chat(config)
  end
  state.streaming_message_index = nil
end

function M.submit(text, config)
  M.add_message("You", text, config)
  M.set_status("working", config)
end

function M.handle_notification(message, config)
  local method = message and message.method
  local params = message and message.params or {}

  if method == "_transport/thread_started" or method == "omniac/session_started" then
    M.set_status("ready", config)
    return
  end

  if method == "thread/started" or method == "turn/started" or method == "omniac/prompt_started" then
    state.streaming_message_index = nil
    state.tool_activity = nil
    M.set_status("working", config)
    return
  end

  if method == "turn/completed" then
    M.set_status("ready", config)
    return
  end

  if method == "omniac/response" then
    M.add_message("Omniac", params.text or "", config)
    state.streaming_message_index = nil
    M.set_status("ready", config)
    return
  end

  if method == "omniac/response_chunk" then
    M.append_response_chunk(params.text or "", config)
    return
  end

  if method == "omniac/tool_activity" then
    M.set_tool_activity(params, config)
    return
  end

  if method == "omniac/response_completed" then
    M.complete_response(config)
    M.set_status("ready", config)
    return
  end

  if method == "omniac/error" or method == "turn/error" or method == "_transport/error" then
    M.add_message("Error", vim.inspect(params), config)
    M.set_status("error", config)
  end
end

function M.is_open()
  return valid_win(state.chat_win)
    and valid_win(state.activity_win)
    and valid_win(state.input_win)
    and valid_win(state.status_win)
end

function M.statusline()
  local text = string.format(" %s | %s | %s ", "Omniac", state.status, agent_name(state.config))
  return "%#OmniacStatusMode#" .. text .. "%#OmniacStatus#%="
end

return M
