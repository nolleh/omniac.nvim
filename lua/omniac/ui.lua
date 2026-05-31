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
  messages = {},
  config = nil,
  submit = nil,
}

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
  vim.api.nvim_set_hl(0, "OmniacThinking1", { fg = "#585b70", bold = true })
  vim.api.nvim_set_hl(0, "OmniacThinking2", { fg = "#7f849c", bold = true })
  vim.api.nvim_set_hl(0, "OmniacThinking3", { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacThinking4", { fg = "#f5c2e7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacInput", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacInputPrompt", { fg = "#89b4fa", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusMode", { fg = "#11111b", bg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatus", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsule", { fg = "#11111b", bg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsuleAlt", { fg = "#cdd6f4", bg = "#45475a", bold = true })
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

local function header(lines, marks, size)
  local box_width = math.max(40, size)
  local inner = box_width - 2
  local user = vim.env.USER or "there"
  local title = "Omniac Code"
  local top = "╭─ " .. title .. " " .. string.rep("─", math.max(0, box_width - vim.fn.strdisplaywidth(title) - 5)) .. "╮"
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
  add_boxed_line(lines, marks, agent_name(state.config) .. " / " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"), box_width, "OmniacMuted")
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
    add_boxed_line(lines, marks, "Agent: " .. agent_name(state.config) .. "  •  Status: " .. state.status, win_width, "OmniacAccent")
    add_boxed_line(lines, marks, "cwd: " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"), win_width, "OmniacMuted")
    add_line(lines, marks, box_line("╰", "─", "╯", win_width), "OmniacBorder")
  else
    for _, message in ipairs(state.messages) do
      local group = message.role == "You" and "OmniacUserBubble" or "OmniacAssistantText"
      if message.role == "Error" then
        group = "OmniacError"
      end

      if message.role == "You" then
        for _, line in ipairs(wrapped(message.text, text_width)) do
          add_line(lines, marks, "  " .. fit(line, win_width - 4) .. "  ", group)
        end
      else
        for line in (tostring(message.text or "") .. "\n"):gmatch("(.-)\n") do
          add_line(lines, marks, "  " .. line, group)
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

  for _, mark in ipairs(marks) do
    add_hl(state.chat_buf, mark.line, mark.from, mark.to, mark.group)
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
  add_hl(state.status_buf, 1, 0, #left, "OmniacStatusCapsule")
  add_hl(state.status_buf, 1, #left, #left + #middle, "OmniacStatusMode")
  add_hl(state.status_buf, 1, #left + #middle + #spacer, -1, "OmniacStatusCapsuleAlt")
end

local function render_activity()
  if not valid_buf(state.activity_buf) then
    return
  end

  local win_width = valid_win(state.activity_win) and vim.api.nvim_win_get_width(state.activity_win) or width(state.config)
  local frames = {
    "Thinking",
    "Thinking.",
    "Thinking..",
    "Thinking...",
  }
  local groups = {
    "OmniacThinking1",
    "OmniacThinking2",
    "OmniacThinking3",
    "OmniacThinking4",
  }
  local text = ""
  if state.status == "thinking" then
    text = frames[state.activity_frame]
  elseif state.status == "connecting" then
    text = "Connecting..."
  end
  local line = text == "" and "" or center(text, win_width)

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
  if state.status ~= "thinking" then
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
  state.activity_timer:start(0, 180, vim.schedule_wrap(function()
    state.activity_frame = (state.activity_frame % 4) + 1
    render_activity()
  end))
end

local function reset_input()
  if not valid_buf(state.input_buf) then
    return
  end

  vim.bo[state.input_buf].modifiable = true
  local win_width = valid_win(state.input_win) and vim.api.nvim_win_get_width(state.input_win) or width(state.config)
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {
    box_line("╭", "─", "╮", win_width),
    "│ > ",
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
  add_hl(state.input_buf, 2, #"│", #"│ > ", "OmniacInputPrompt")
  add_hl(state.input_buf, 3, 0, -1, "OmniacBorder")
  vim.bo[state.input_buf].modified = false
end

local function raw_input_text()
  if not valid_buf(state.input_buf) then
    return ""
  end

  local line = vim.api.nvim_buf_get_lines(state.input_buf, 1, 2, false)[1] or ""
  return (line:gsub("^│%s*>%s*", ""))
end

local function input_text()
  return (raw_input_text():gsub("^%s+", ""):gsub("%s+$", ""))
end

local function focus_input()
  if not valid_win(state.input_win) then
    return
  end

  vim.api.nvim_set_current_win(state.input_win)
  vim.api.nvim_win_set_cursor(state.input_win, { 2, #"│ > " })
  vim.cmd("startinsert")
end

local function enforce_input()
  if not valid_buf(state.input_buf) then
    return
  end

  local text = raw_input_text()
  local win_width = valid_win(state.input_win) and vim.api.nvim_win_get_width(state.input_win) or width(state.config)
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {
    box_line("╭", "─", "╮", win_width),
    "│ > " .. text,
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
  add_hl(state.input_buf, 2, #"│", #"│ > ", "OmniacInputPrompt")
  add_hl(state.input_buf, 3, 0, -1, "OmniacBorder")
  if valid_win(state.input_win) and vim.api.nvim_get_current_buf() == state.input_buf then
    vim.api.nvim_win_set_cursor(state.input_win, { 2, #("│ > " .. text) })
  end
end

local function configure_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  vim.wo[win].list = false
end

local function resize_aux_windows()
  if valid_win(state.status_win) then
    pcall(vim.api.nvim_win_set_height, state.status_win, 1)
  end
  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_height, state.input_win, 3)
  end
  if valid_win(state.activity_win) then
    pcall(vim.api.nvim_win_set_height, state.activity_win, 1)
  end
end

function M.open(config, submit)
  setup_highlights()
  state.config = config or state.config
  state.submit = submit or state.submit

  if valid_win(state.chat_win) and valid_win(state.activity_win) and valid_win(state.input_win) and valid_win(state.status_win) then
    resize_aux_windows()
    focus_input()
    return state
  end

  if not valid_buf(state.chat_buf) then
    state.chat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.chat_buf].buftype = "nofile"
    vim.bo[state.chat_buf].bufhidden = "hide"
    vim.bo[state.chat_buf].swapfile = false
    vim.bo[state.chat_buf].filetype = "omniac"
    vim.api.nvim_buf_set_name(state.chat_buf, "Omniac Chat")
  end

  if not valid_buf(state.input_buf) then
    state.input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.input_buf].buftype = "nofile"
    vim.bo[state.input_buf].bufhidden = "hide"
    vim.bo[state.input_buf].swapfile = false
    vim.bo[state.input_buf].filetype = "omniac-input"
    vim.api.nvim_buf_set_name(state.input_buf, "Omniac Input")
  end

  if not valid_buf(state.activity_buf) then
    state.activity_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.activity_buf].buftype = "nofile"
    vim.bo[state.activity_buf].bufhidden = "hide"
    vim.bo[state.activity_buf].swapfile = false
    vim.bo[state.activity_buf].filetype = "omniac-activity"
    vim.api.nvim_buf_set_name(state.activity_buf, "Omniac Activity")
  end

  if not valid_buf(state.status_buf) then
    state.status_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.status_buf].buftype = "nofile"
    vim.bo[state.status_buf].bufhidden = "hide"
    vim.bo[state.status_buf].swapfile = false
    vim.bo[state.status_buf].filetype = "omniac-status"
    vim.api.nvim_buf_set_name(state.status_buf, "Omniac Status")
  end

  vim.cmd("botright vertical " .. width(state.config) .. "new")
  state.chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.chat_win, state.chat_buf)
  configure_window(state.chat_win)
  vim.wo[state.chat_win].statusline = "%!v:lua.require'omniac.ui'.statusline()"

  vim.cmd("belowright 1new")
  state.activity_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.activity_win, state.activity_buf)
  configure_window(state.activity_win)
  vim.wo[state.activity_win].winfixheight = true
  vim.wo[state.activity_win].statusline = "%#OmniacStatus#%="

  vim.cmd("belowright 3new")
  state.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
  configure_window(state.input_win)
  vim.wo[state.input_win].winfixheight = true
  vim.wo[state.input_win].wrap = false
  vim.wo[state.input_win].statusline = "%#OmniacStatus#%="

  vim.cmd("belowright 1new")
  state.status_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.status_win, state.status_buf)
  configure_window(state.status_win)
  vim.wo[state.status_win].winfixheight = true
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
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = state.input_buf,
    callback = enforce_input,
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
  render_chat(config)
  render_activity()
  render_status()
  sync_activity_timer()
end

function M.add_message(role, text, config)
  table.insert(state.messages, {
    role = role,
    text = text or "",
  })
  render_chat(config)
  focus_input()
end

function M.submit(text, config)
  M.add_message("You", text, config)
  M.set_status("thinking", config)
end

function M.handle_notification(message, config)
  local method = message and message.method
  local params = message and message.params or {}

  if method == "_transport/thread_started" or method == "omniac/session_started" then
    M.set_status("ready", config)
    return
  end

  if method == "thread/started" or method == "turn/started" or method == "omniac/prompt_started" then
    M.set_status("thinking", config)
    return
  end

  if method == "turn/completed" then
    M.set_status("ready", config)
    return
  end

  if method == "omniac/response" then
    M.add_message("Omniac", params.text or "", config)
    M.set_status("ready", config)
    return
  end

  if method == "omniac/error" or method == "turn/error" or method == "_transport/error" then
    M.add_message("Error", vim.inspect(params), config)
    M.set_status("error", config)
  end
end

function M.is_open()
  return valid_win(state.chat_win) and valid_win(state.activity_win) and valid_win(state.input_win) and valid_win(state.status_win)
end

function M.statusline()
  local text = string.format(" %s | %s | %s ", "Omniac", state.status, agent_name(state.config))
  return "%#OmniacStatusMode#" .. text .. "%#OmniacStatus#%="
end

return M
