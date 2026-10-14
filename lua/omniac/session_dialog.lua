local M = {}

local ns = vim.api.nvim_create_namespace("omniac.session_dialog")

local state = {
  buf = nil,
  win = nil,
  footer_buf = nil,
  footer_win = nil,
  selected = 1,
  items = {},
  item_lines = {},
  callback = nil,
}

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "OmniacSessionBorder", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "OmniacSessionTitle", { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "OmniacSessionText", { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "OmniacSessionMuted", { fg = "#7f849c" })
  vim.api.nvim_set_hl(0, "OmniacSessionSelected", { fg = "#11111b", bg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacSessionKey", { fg = "#89b4fa", bold = true })
end

local function normalize_text(text)
  local value = tostring(text or "")
  return value:gsub("[\r\n]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function fit(text, size)
  local value = normalize_text(text)
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

local function short_path(path)
  if not path or path == "" then
    return ""
  end
  return vim.fn.fnamemodify(path, ":~")
end

local function session_id(session)
  return session.sessionId or session.session_id or session.id or ""
end

local function short_session_id(session)
  local id = session_id(session)
  if #id > 12 then
    return id:sub(1, 8)
  end
  return id
end

local function parse_utc_time(value)
  local text = normalize_text(value or "unknown time")
  local year, month, day, hour, minute, second = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not year then
    return nil
  end

  local utc_as_local = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = tonumber(second),
  })
  local now = os.time()
  local offset = os.difftime(os.time(os.date("*t", now)), os.time(os.date("!*t", now)))
  return utc_as_local + offset
end

local function relative_time(epoch)
  if not epoch then
    return nil
  end

  local diff = math.max(0, os.difftime(os.time(), epoch))
  local minute = 60
  local hour = minute * 60
  local day = hour * 24

  if diff < minute then
    return "방금 전"
  elseif diff < hour then
    return string.format("%d분 전", math.floor(diff / minute))
  elseif diff < day then
    return string.format("%d시간 전", math.floor(diff / hour))
  elseif diff < day * 30 then
    return string.format("%d일 전", math.floor(diff / day))
  end
  return string.format("%d개월 전", math.floor(diff / (day * 30)))
end

local function short_time(value)
  local epoch = parse_utc_time(value)
  if epoch then
    return string.format("%s · %s", relative_time(epoch), os.date("%Y-%m-%d %H:%M", epoch))
  end

  local text = normalize_text(value or "unknown time")
  local date, hour, minute = text:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d):(%d%d)")
  if date then
    return date .. " " .. hour .. ":" .. minute
  end
  return text
end

local function session_display(session)
  local title = normalize_text(session.title)
  local current_file
  if title ~= "" then
    local before, after = title:match("^(.-)%s*Current file:%s*(.+)$")
    if before and after then
      title = normalize_text(before)
      current_file = normalize_text(after)
    end
  end

  if title ~= "" then
    return title, current_file
  end

  local id = session_id(session)
  if id ~= "" then
    return "untitled / " .. id, current_file
  end
  return "untitled session", current_file
end

local function has_selectable_items()
  for _, item in ipairs(state.items) do
    if item.kind == "session" then
      return true
    end
  end
  return false
end

local function close(result)
  local callback = state.callback
  state.callback = nil

  if valid_win(state.footer_win) then
    pcall(vim.api.nvim_win_close, state.footer_win, true)
  end
  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if valid_buf(state.footer_buf) then
    pcall(vim.api.nvim_buf_delete, state.footer_buf, { force = true })
  end
  if valid_buf(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  state.buf = nil
  state.win = nil
  state.footer_buf = nil
  state.footer_win = nil
  state.items = {}
  state.item_lines = {}
  state.selected = 1

  if callback then
    callback(result)
  end
end

local function close_with_session_id(action)
  local callback = state.callback
  state.callback = nil

  if valid_win(state.footer_win) then
    pcall(vim.api.nvim_win_close, state.footer_win, true)
  end
  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if valid_buf(state.footer_buf) then
    pcall(vim.api.nvim_buf_delete, state.footer_buf, { force = true })
  end
  if valid_buf(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  state.buf = nil
  state.win = nil
  state.footer_buf = nil
  state.footer_win = nil
  state.items = {}
  state.item_lines = {}
  state.selected = 1

  vim.ui.input({
    prompt = "Session ID: ",
  }, function(session_id_value)
    if not callback then
      return
    end
    if not session_id_value or session_id_value == "" then
      callback(nil)
      return
    end
    callback({
      action = action,
      id = session_id_value,
    })
  end)
end

local function render()
  if not valid_buf(state.buf) then
    return
  end

  local width = valid_win(state.win) and vim.api.nvim_win_get_width(state.win) or 72
  local inner_width = math.max(1, width - 4)
  local lines = {}
  local marks = {}
  state.item_lines = {}

  local function add(line, group)
    table.insert(lines, "  " .. fit(line, inner_width))
    if group then
      table.insert(marks, { #lines - 1, 0, -1, group })
    end
  end

  add("OMNIAC SESSIONS", "OmniacSessionTitle")
  add("choose a saved thread", "OmniacSessionMuted")
  add("", nil)

  for index, item in ipairs(state.items) do
    state.item_lines[index] = #lines + 1
    local prefix = index == state.selected and "▶ " or "  "
    local line
    if item.kind == "message" then
      line = "  " .. item.text
    else
      local session = item.session or {}
      local title = session_display(session)
      line = prefix .. title
    end

    add(line, index == state.selected and "OmniacSessionSelected" or "OmniacSessionText")

    if item.kind == "session" then
      local session = item.session or {}
      local _, current_file = session_display(session)
      local updated = short_time(session.updatedAt or session.updated_at)
      local detail = "     " .. updated .. "  ·  " .. short_path(session.cwd) .. "  ·  " .. short_session_id(session)
      add(detail, "OmniacSessionMuted")
      if current_file and current_file ~= "" then
        add("     current file: " .. current_file, "OmniacSessionMuted")
      end
      add("", nil)
    end
  end

  vim.bo[state.buf].readonly = false
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].readonly = true
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, mark[4], mark[1], mark[2], mark[3])
  end

  if valid_win(state.win) and state.item_lines[state.selected] then
    pcall(vim.api.nvim_win_set_cursor, state.win, { state.item_lines[state.selected], 0 })
  end

  if valid_buf(state.footer_buf) then
    local footer_line = "  " .. fit("[Enter] load   [r] resume   [n] new   [i] session id   [q] close", inner_width)
    vim.bo[state.footer_buf].readonly = false
    vim.bo[state.footer_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.footer_buf, 0, -1, false, { footer_line })
    vim.bo[state.footer_buf].modifiable = false
    vim.bo[state.footer_buf].readonly = true
    vim.api.nvim_buf_clear_namespace(state.footer_buf, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(state.footer_buf, ns, "OmniacSessionKey", 0, 0, -1)
  end
end

local function move(delta)
  if #state.items == 0 or not has_selectable_items() then
    return
  end
  repeat
    state.selected = state.selected + delta
    if state.selected < 1 then
      state.selected = #state.items
    elseif state.selected > #state.items then
      state.selected = 1
    end
  until state.items[state.selected].kind ~= "message"
  render()
end

local function choose(action)
  local item = state.items[state.selected]
  if not item then
    return
  end

  if item.kind == "session" then
    close({
      action = action or "load",
      id = session_id(item.session),
    })
  end
end

function M.open(sessions, opts, callback)
  setup_highlights()
  opts = opts or {}
  state.callback = callback
  state.selected = 1
  state.items = {}

  if opts.list_supported == false then
    table.insert(state.items, {
      kind = "message",
      text = opts.message or "session/list is not advertised by this agent",
    })
  elseif not sessions or #sessions == 0 then
    table.insert(state.items, {
      kind = "message",
      text = "no saved sessions were returned for this workspace",
    })
  else
    for _, session in ipairs(sessions) do
      table.insert(state.items, {
        kind = "session",
        session = session,
      })
    end
  end

  local width = math.min(math.max(72, math.floor(vim.o.columns * 0.58)), math.max(50, vim.o.columns - 8))
  local total_height = math.min(math.max(14, math.floor(vim.o.lines * 0.58)), math.max(12, vim.o.lines - 8))
  local footer_height = 1
  local height = math.max(8, total_height - footer_height - 2)
  local row = math.max(0, math.floor((vim.o.lines - total_height - 4) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "omniac-session"
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].readonly = true
  state.footer_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.footer_buf].buftype = "nofile"
  vim.bo[state.footer_buf].bufhidden = "wipe"
  vim.bo[state.footer_buf].swapfile = false
  vim.bo[state.footer_buf].filetype = "omniac-session-footer"
  vim.bo[state.footer_buf].modifiable = false
  vim.bo[state.footer_buf].readonly = true

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " SESSION SELECT ",
    title_pos = "center",
  })
  state.footer_win = vim.api.nvim_open_win(state.footer_buf, false, {
    relative = "editor",
    width = width,
    height = footer_height,
    row = row + height + 3,
    col = col,
    style = "minimal",
    border = "rounded",
  })

  vim.wo[state.win].cursorline = false
  vim.wo[state.win].wrap = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].winhighlight = "FloatBorder:OmniacSessionBorder,FloatTitle:OmniacSessionTitle"
  vim.wo[state.footer_win].cursorline = false
  vim.wo[state.footer_win].wrap = false
  vim.wo[state.footer_win].signcolumn = "no"
  vim.wo[state.footer_win].winhighlight = "FloatBorder:OmniacSessionBorder"

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true })
    vim.keymap.set("n", lhs, fn, { buffer = state.footer_buf, nowait = true, silent = true })
  end
  local function imap(lhs, fn)
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = state.buf, nowait = true, silent = true })
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = state.footer_buf, nowait = true, silent = true })
  end

  imap("q", function()
    close(nil)
  end)
  imap("<Esc>", function()
    pcall(vim.cmd, "stopinsert")
    close(nil)
  end)
  imap("j", function()
    pcall(vim.cmd, "stopinsert")
    move(1)
  end)
  imap("<Down>", function()
    pcall(vim.cmd, "stopinsert")
    move(1)
  end)
  imap("k", function()
    pcall(vim.cmd, "stopinsert")
    move(-1)
  end)
  imap("<Up>", function()
    pcall(vim.cmd, "stopinsert")
    move(-1)
  end)
  imap("<CR>", function()
    pcall(vim.cmd, "stopinsert")
    choose("load")
  end)
  imap("r", function()
    pcall(vim.cmd, "stopinsert")
    choose("resume")
  end)
  imap("n", function()
    pcall(vim.cmd, "stopinsert")
    close({ action = "new" })
  end)
  imap("i", function()
    pcall(vim.cmd, "stopinsert")
    close_with_session_id("load")
  end)
  map("a", function() end)
  map("o", function() end)
  map("O", function() end)
  map("<Insert>", function() end)

  render()
end

return M
