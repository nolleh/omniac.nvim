local M = {}
local dialog = require("omniac.ui.dialog")
local highlights = require("omniac.ui.highlights")
local markdown = require("omniac.ui.markdown")

local ns = vim.api.nvim_create_namespace("omniac.permission_dialog")

local state = {
  body_buf = nil,
  body_win = nil,
  selector_buf = nil,
  selector_win = nil,
  selected = 1,
  options = {},
  callback = nil,
  prompt = "",
  body = "",
  cancel_label = "deny",
  title = "Permission",
}

local valid_buf = dialog.valid_buf
local valid_win = dialog.valid_win
local stop_insert = dialog.stop_insert
local normalize_text = dialog.normalize_inline

local function normalize_body(text)
  if type(text) == "table" then
    return table.concat(text, "\n")
  end

  return tostring(text or "")
end

local function option_label(option)
  if type(option) ~= "table" then
    return tostring(option)
  end
  return option.name or option.label or option.kind or option.optionId or option.id or "Select"
end

local function cleanup()
  dialog.release(state, { "selector_win", "body_win" }, { "selector_buf", "body_buf" })
  state.selected = 1
  state.options = {}
  state.prompt = ""
  state.body = ""
  state.cancel_label = "deny"
  state.title = "Permission"
end

local function close(choice)
  local callback = state.callback
  state.callback = nil
  cleanup()

  if callback then
    callback(choice)
  end
end

function M.dismiss()
  state.callback = nil
  cleanup()
end

local function cleanup_existing()
  state.callback = nil
  cleanup()

  local existing = vim.fn.bufnr("omniac://permission")
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
end

local function render_selector()
  if not valid_buf(state.selector_buf) then
    return
  end

  local lines = {}
  local marks = {}

  for index, option in ipairs(state.options) do
    local prefix = index == state.selected and "› " or "  "
    table.insert(lines, prefix .. tostring(index) .. "  " .. option_label(option))
    table.insert(
      marks,
      { line = #lines, group = index == state.selected and "OmniacPermissionSelected" or "OmniacPermissionText" }
    )
  end

  table.insert(lines, "")
  table.insert(marks, { line = #lines, group = nil })
  table.insert(lines, "enter select  ·  1-9 select  ·  j/k move  ·  ctrl-d/u details  ·  q " .. state.cancel_label)
  table.insert(marks, { line = #lines, group = "OmniacPermissionMuted" })

  dialog.set_lines(state.selector_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.selector_buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    if mark.group then
      vim.api.nvim_buf_add_highlight(state.selector_buf, ns, mark.group, mark.line - 1, 0, -1)
    end
  end
end

local function render_selector_selection()
  if not valid_buf(state.selector_buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(state.selector_buf, ns, 0, -1)
  for index = 1, #state.options do
    local group = index == state.selected and "OmniacPermissionSelected" or "OmniacPermissionText"
    vim.api.nvim_buf_add_highlight(state.selector_buf, ns, group, index - 1, 0, -1)
  end
  if #state.options > 0 then
    vim.api.nvim_buf_add_highlight(state.selector_buf, ns, "OmniacPermissionMuted", #state.options + 1, 0, -1)
  end
end

local function render_body()
  if not valid_buf(state.body_buf) then
    return
  end

  local lines = { state.prompt }
  if state.body ~= "" then
    table.insert(lines, "")
    for _, line in ipairs(vim.split(state.body, "\n", { plain = true, trimempty = false })) do
      table.insert(lines, line)
    end
  end

  dialog.set_lines(state.body_buf, lines)
  markdown.render(state.body_buf, state.body_win, "OmniacPermissionRender")
end

local function move(delta)
  if #state.options == 0 then
    return
  end
  state.selected = state.selected + delta
  if state.selected < 1 then
    state.selected = #state.options
  elseif state.selected > #state.options then
    state.selected = 1
  end
  render_selector_selection()
end

local function choose(index)
  close(state.options[index or state.selected])
end

local function reject()
  for _, option in ipairs(state.options) do
    local id = tostring(option.optionId or option.id or option.kind or option.name or ""):lower()
    if id:match("reject") then
      close(option)
      return
    end
  end
  close(nil)
end

function M.open(options, opts, callback)
  highlights.setup("OmniacPermission")
  cleanup_existing()
  opts = opts or {}
  state.options = type(options) == "table" and options or {}
  state.callback = callback
  state.prompt = normalize_text(opts.prompt or "Permission requested")
  state.body = normalize_body(opts.body or opts.details or "")
  state.cancel_label = normalize_text(opts.cancel_label or "deny")
  state.title = normalize_text(opts.title or "Permission")
  state.selected = #state.options > 0 and math.min(math.max(tonumber(opts.selected) or 1, 1), #state.options) or 0

  local width = math.min(math.max(72, math.floor(vim.o.columns * 0.58)), math.max(50, vim.o.columns - 8))
  local content_width = math.max(1, width - 4)
  local body_text_lines = math.max(1, math.ceil(vim.fn.strdisplaywidth(state.prompt) / content_width))
  if state.body ~= "" then
    body_text_lines = body_text_lines + 1
    for _, line in ipairs(vim.split(state.body, "\n", { plain = true, trimempty = false })) do
      body_text_lines = body_text_lines + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / content_width))
    end
  end
  local selector_lines = math.max(3, #state.options + 2)
  local max_total = math.max(8, vim.o.lines - 8)
  local selector_height = math.min(selector_lines, max_total)
  local body_height = math.min(math.max(3, body_text_lines), math.max(3, max_total - selector_height - 4))
  local total_height = body_height + selector_height + 4
  if total_height > max_total then
    selector_height = math.max(3, max_total - body_height - 4)
    total_height = body_height + selector_height + 4
  end
  local row = math.max(0, math.floor((vim.o.lines - total_height - 4) / 3))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  state.body_buf = dialog.create_buffer({ name = "omniac://permission", filetype = "omniac-permission" })

  state.body_win = vim.api.nvim_open_win(state.body_buf, false, {
    relative = "editor",
    width = width,
    height = body_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. state.title .. " ",
    title_pos = "left",
  })
  vim.wo[state.body_win].wrap = true
  vim.wo[state.body_win].linebreak = false
  vim.wo[state.body_win].cursorline = false
  vim.wo[state.body_win].signcolumn = "no"
  vim.wo[state.body_win].winhighlight = "FloatBorder:OmniacPermissionBorder,FloatTitle:OmniacPermissionTitle"

  state.selector_buf = dialog.create_buffer({
    name = "omniac://permission-selector",
    filetype = "omniac-permission",
  })

  state.selector_win = vim.api.nvim_open_win(state.selector_buf, true, {
    relative = "editor",
    width = width,
    height = selector_height,
    row = row + body_height + 2,
    col = col,
    style = "minimal",
    border = "rounded",
  })
  vim.wo[state.selector_win].wrap = false
  vim.wo[state.selector_win].cursorline = false
  vim.wo[state.selector_win].signcolumn = "no"
  vim.wo[state.selector_win].winhighlight = "FloatBorder:OmniacPermissionBorder"

  local function map(lhs, fn)
    vim.keymap.set({ "n", "i" }, lhs, function()
      stop_insert()
      fn()
    end, { buffer = state.selector_buf, nowait = true, silent = true })
  end

  map("<CR>", choose)
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
  map("q", reject)
  local function scroll_body(key)
    if not valid_win(state.body_win) then
      return
    end
    vim.api.nvim_win_call(state.body_win, function()
      vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(key, true, false, true))
    end)
  end
  map("<C-d>", function()
    scroll_body("<C-d>")
  end)
  map("<C-u>", function()
    scroll_body("<C-u>")
  end)
  for index = 1, math.min(9, #state.options) do
    map(tostring(index), function()
      choose(index)
    end)
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = state.selector_buf,
    once = true,
    callback = function()
      state.callback = nil
      state.selector_buf = nil
      state.selector_win = nil
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = state.body_buf,
    once = true,
    callback = function()
      state.callback = nil
      state.body_buf = nil
      state.body_win = nil
    end,
  })

  render_body()
  render_selector()
  stop_insert()
  vim.schedule(function()
    if valid_win(state.body_win) then
      markdown.render(state.body_buf, state.body_win, "OmniacPermissionRender")
    end
    if valid_win(state.selector_win) then
      render_selector_selection()
      stop_insert()
    end
  end)
  return state
end

return M
