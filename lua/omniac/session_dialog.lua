local M = {}

local ns = vim.api.nvim_create_namespace("omniac.session_dialog")

local state = {
  buf = nil,
  win = nil,
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

local function short_path(path)
  if not path or path == "" then
    return ""
  end
  return vim.fn.fnamemodify(path, ":~")
end

local function session_id(session)
  return session.sessionId or session.session_id or session.id or ""
end

local function session_title(session)
  local title = session.title
  if title and title ~= "" then
    return title
  end
  local id = session_id(session)
  if id ~= "" then
    return "untitled / " .. id
  end
  return "untitled session"
end

local function close(result)
  local callback = state.callback
  state.callback = nil

  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if valid_buf(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  state.buf = nil
  state.win = nil
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

  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if valid_buf(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  state.buf = nil
  state.win = nil
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
  local lines = {}
  local marks = {}
  state.item_lines = {}

  local function add(line, group)
    table.insert(lines, line)
    if group then
      table.insert(marks, { #lines - 1, 0, -1, group })
    end
  end

  add("OMNIAC LINK TERMINAL", "OmniacSessionTitle")
  add("choose a thread to enter, or boot a clean instance", "OmniacSessionMuted")
  add(string.rep("─", math.max(0, width)), "OmniacSessionBorder")
  add("", nil)

  for index, item in ipairs(state.items) do
    state.item_lines[index] = #lines + 1
    local prefix = index == state.selected and "▶ " or "  "
    local line
    if item.kind == "new" then
      line = prefix .. "[NEW] start a fresh agentic coding session"
    elseif item.kind == "manual" then
      line = prefix .. "[ID ] enter a session id manually"
    elseif item.kind == "message" then
      line = "  " .. item.text
    else
      local session = item.session or {}
      local title = session_title(session)
      local updated = session.updatedAt or session.updated_at or "unknown time"
      line = prefix .. "[LOAD] " .. title .. "  ·  " .. updated
    end

    add(fit(line, width), index == state.selected and "OmniacSessionSelected" or "OmniacSessionText")

    if item.kind == "session" then
      local session = item.session or {}
      local detail = "     " .. short_path(session.cwd) .. "  /  " .. session_id(session)
      add(fit(detail, width), "OmniacSessionMuted")
    end
  end

  add("", nil)
  add(string.rep("─", math.max(0, width)), "OmniacSessionBorder")
  add("↑/k ↓/j move   Enter load/new   r resume selected   n new   q quit", "OmniacSessionKey")

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, mark[4], mark[1], mark[2], mark[3])
  end

  if valid_win(state.win) and state.item_lines[state.selected] then
    pcall(vim.api.nvim_win_set_cursor, state.win, { state.item_lines[state.selected], 0 })
  end
end

local function move(delta)
  if #state.items == 0 then
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

  if item.kind == "new" then
    close({ action = "new" })
    return
  end

  if item.kind == "manual" then
    close_with_session_id(action or "load")
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
  state.items = {
    { kind = "new" },
    { kind = "manual" },
  }

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

  local width = math.min(math.max(72, math.floor(vim.o.columns * 0.7)), math.max(50, vim.o.columns - 4))
  local height = math.min(math.max(10, 6 + (#state.items * 2)), math.max(10, vim.o.lines - 4))
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "omniac-session"
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].readonly = true

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " SESSION SELECT ",
    title_pos = "center",
  })

  vim.wo[state.win].cursorline = false
  vim.wo[state.win].wrap = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].winhighlight = "FloatBorder:OmniacSessionBorder,FloatTitle:OmniacSessionTitle"

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true })
  end
  local function imap(lhs, fn)
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = state.buf, nowait = true, silent = true })
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
  map("i", function() end)
  map("a", function() end)
  map("o", function() end)
  map("O", function() end)
  map("<Insert>", function() end)

  render()
end

return M
