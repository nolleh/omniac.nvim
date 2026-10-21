local M = {}
local dialog = require("omniac.ui.dialog")
local highlights = require("omniac.ui.highlights")

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

local valid_buf = dialog.valid_buf
local valid_win = dialog.valid_win
local normalize_text = dialog.normalize_inline
local fit = dialog.fit_inline

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
  dialog.release(state, { "footer_win", "win" }, { "footer_buf", "buf" })
  state.items = {}
  state.item_lines = {}
  state.selected = 1
end

local function close(result, action)
  local callback = state.callback
  local selected = state.selected
  state.callback = nil
  cleanup()
  if callback then
    callback(result, selected, action)
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
    add("", nil)
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
    local footer_line = "  " .. fit("[Enter] review   [Ctrl-e] edit file   [j/k] move   [q] close", inner_width)
    dialog.set_lines(state.footer_buf, { footer_line })
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

local function choose(action)
  local item = state.items[state.selected]
  if item then
    close(item, action)
  end
end

function M.open(items, opts, callback)
  dialog.stop_insert()
  highlights.setup("OmniacChange")
  if valid_buf(state.buf) or valid_buf(state.footer_buf) then
    state.callback = nil
    cleanup()
  end

  opts = opts or {}
  state.callback = callback
  state.items = items or {}
  state.selected = math.max(1, math.min(opts.selected or 1, #state.items))
  state.scope = opts.scope == "session" and "session" or "turn"

  state.buf = dialog.create_buffer({ name = "omniac://changes", filetype = "omniac-changes" })
  state.footer_buf = dialog.create_buffer({
    name = "omniac://changes-footer",
    filetype = "omniac-changes-footer",
  })
  state.win, state.footer_win = dialog.open_list_frame(state.buf, state.footer_buf, {
    title = " CHANGE REVIEW ",
    border_group = "OmniacChangeBorder",
    title_group = "OmniacChangeTitle",
  })

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
  map("<CR>", function()
    choose("review")
  end)
  map("<C-e>", function()
    choose("edit")
  end)

  render()
end

return M
