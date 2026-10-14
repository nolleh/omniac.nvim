local M = {}

local ns = vim.api.nvim_create_namespace("omniac.change_dialog")

local state = {
  buf = nil,
  win = nil,
  footer_buf = nil,
  footer_win = nil,
  selected = 1,
  items = {},
  item_lines = {},
  callback = nil,
  scope = "turn",
}

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "OmniacChangeBorder", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "OmniacChangeTitle", { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "OmniacChangeText", { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "OmniacChangeMuted", { fg = "#7f849c" })
  vim.api.nvim_set_hl(0, "OmniacChangeSelected", { fg = "#11111b", bg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacChangeKey", { fg = "#89b4fa", bold = true })
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

local function display_path(path)
  local relative = vim.fn.fnamemodify(path or "", ":.")
  return relative ~= "" and relative or path or "unknown file"
end

local function operation_label(value)
  return ({
    add = "A",
    copy = "C",
    delete = "D",
    modify = "M",
    move = "R",
  })[value] or "M"
end

local function scope_description()
  if state.scope == "session" then
    return "review changes since this connection started"
  end
  return "review files changed in the latest turn"
end

local function item_detail(item)
  local parts = {}
  local source = normalize_text(item.source)
  local title = normalize_text(item.title)
  if title ~= "" then
    table.insert(parts, title)
  elseif source ~= "" then
    table.insert(parts, source:upper() .. " edit")
  else
    table.insert(parts, "agent edit")
  end
  if item.turnId ~= nil then
    table.insert(parts, "turn " .. tostring(item.turnId))
  end
  return table.concat(parts, "  ·  ")
end

local function cleanup()
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
end

local function close(result)
  local callback = state.callback
  local selected = state.selected
  state.callback = nil
  cleanup()
  if callback then
    callback(result, selected)
  end
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

  add("OMNIAC CHANGES", "OmniacChangeTitle")
  add(scope_description(), "OmniacChangeMuted")
  add("", nil)

  for index, item in ipairs(state.items) do
    state.item_lines[index] = #lines + 1
    local prefix = index == state.selected and "▶ " or "  "
    local row = string.format("%s%s  %s", prefix, operation_label(item.operation), display_path(item.path))
    add(row, index == state.selected and "OmniacChangeSelected" or "OmniacChangeText")
    add("     " .. item_detail(item), "OmniacChangeMuted")
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
    local footer_line = "  " .. fit("[Enter] review   [j/k] move   [q] close", inner_width)
    vim.bo[state.footer_buf].readonly = false
    vim.bo[state.footer_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.footer_buf, 0, -1, false, { footer_line })
    vim.bo[state.footer_buf].modifiable = false
    vim.bo[state.footer_buf].readonly = true
    vim.api.nvim_buf_clear_namespace(state.footer_buf, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(state.footer_buf, ns, "OmniacChangeKey", 0, 0, -1)
  end
end

local function move(delta)
  if #state.items == 0 then
    return
  end
  state.selected = state.selected + delta
  if state.selected < 1 then
    state.selected = #state.items
  elseif state.selected > #state.items then
    state.selected = 1
  end
  render()
end

local function choose()
  local item = state.items[state.selected]
  if item then
    close(item)
  end
end

function M.open(items, opts, callback)
  if vim.fn.mode():match("^[iR]") then
    vim.cmd("stopinsert")
  end
  setup_highlights()
  if valid_buf(state.buf) or valid_buf(state.footer_buf) then
    state.callback = nil
    cleanup()
  end

  opts = opts or {}
  state.callback = callback
  state.items = items or {}
  state.selected = math.max(1, math.min(opts.selected or 1, #state.items))
  state.scope = opts.scope == "session" and "session" or "turn"

  local width = math.min(math.max(72, math.floor(vim.o.columns * 0.58)), math.max(50, vim.o.columns - 8))
  local total_height = math.min(math.max(14, math.floor(vim.o.lines * 0.58)), math.max(12, vim.o.lines - 8))
  local footer_height = 1
  local height = math.max(8, total_height - footer_height - 2)
  local row = math.max(0, math.floor((vim.o.lines - total_height - 4) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, "omniac://changes")
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "omniac-changes"
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].readonly = true

  state.footer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.footer_buf, "omniac://changes-footer")
  vim.bo[state.footer_buf].buftype = "nofile"
  vim.bo[state.footer_buf].bufhidden = "wipe"
  vim.bo[state.footer_buf].swapfile = false
  vim.bo[state.footer_buf].filetype = "omniac-changes-footer"
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
    title = " CHANGE REVIEW ",
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
  vim.wo[state.win].winhighlight = "FloatBorder:OmniacChangeBorder,FloatTitle:OmniacChangeTitle"
  vim.wo[state.footer_win].cursorline = false
  vim.wo[state.footer_win].wrap = false
  vim.wo[state.footer_win].signcolumn = "no"
  vim.wo[state.footer_win].winhighlight = "FloatBorder:OmniacChangeBorder"

  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = state.buf,
    callback = function()
      vim.schedule(function()
        if valid_win(state.win) and vim.api.nvim_get_current_win() == state.win then
          vim.cmd("stopinsert")
        end
      end)
    end,
  })

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true })
    vim.keymap.set("n", lhs, fn, { buffer = state.footer_buf, nowait = true, silent = true })
  end

  for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "R", "gI", "gi" }) do
    map(key, function() end)
  end

  map("q", function()
    close(nil)
  end)
  map("<Esc>", function()
    close(nil)
  end)
  map("j", function()
    move(1)
  end)
  map("<Down>", function()
    move(1)
  end)
  map("k", function()
    move(-1)
  end)
  map("<Up>", function()
    move(-1)
  end)
  map("<CR>", choose)

  render()
end

return M
