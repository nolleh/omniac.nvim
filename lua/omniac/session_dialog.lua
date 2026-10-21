local M = {}
local dialog = require("omniac.ui.dialog")
local highlights = require("omniac.ui.highlights")

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

local valid_buf = dialog.valid_buf
local valid_win = dialog.valid_win
local normalize_text = dialog.normalize_inline
local fit = dialog.fit_inline

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

local function cleanup()
  dialog.release(state, { "footer_win", "win" }, { "footer_buf", "buf" })
  state.items = {}
  state.item_lines = {}
  state.selected = 1
end

local function close(result)
  local callback = state.callback
  state.callback = nil
  cleanup()

  if callback then
    callback(result)
  end
end

local function close_with_session_id(action)
  local callback = state.callback
  state.callback = nil
  cleanup()

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

  dialog.set_lines(state.buf, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, mark[4], mark[1], mark[2], mark[3])
  end

  if valid_win(state.win) and state.item_lines[state.selected] then
    pcall(vim.api.nvim_win_set_cursor, state.win, { state.item_lines[state.selected], 0 })
  end

  if valid_buf(state.footer_buf) then
    local footer_line = "  " .. fit("[Enter] load   [r] resume   [n] new   [i] session id   [q] close", inner_width)
    dialog.set_lines(state.footer_buf, { footer_line })
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
  dialog.stop_insert()
  highlights.setup("OmniacSession")
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

  state.buf = dialog.create_buffer({ filetype = "omniac-session" })
  state.footer_buf = dialog.create_buffer({ filetype = "omniac-session-footer" })
  state.win, state.footer_win = dialog.open_list_frame(state.buf, state.footer_buf, {
    title = " SESSION SELECT ",
    border_group = "OmniacSessionBorder",
    title_group = "OmniacSessionTitle",
  })

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
