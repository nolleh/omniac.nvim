local M = {}

local ns = vim.api.nvim_create_namespace("omniac.permission_dialog")

local state = {
  buf = nil,
  win = nil,
  selected = 1,
  options = {},
  callback = nil,
  prompt = "",
}

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function stop_insert()
  if vim.fn.mode():match("^[iR]") then
    pcall(vim.cmd, "stopinsert")
  end
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "OmniacPermissionBorder", { fg = "#89dceb" })
  vim.api.nvim_set_hl(0, "OmniacPermissionTitle", { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "OmniacPermissionText", { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "OmniacPermissionMuted", { fg = "#7f849c" })
  vim.api.nvim_set_hl(0, "OmniacPermissionSelected", { fg = "#11111b", bg = "#94e2d5", bold = true })
end

local function normalize_text(text)
  return tostring(text or ""):gsub("[\r\n]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function fit(text, size)
  local value = normalize_text(text)
  local current = vim.fn.strdisplaywidth(value)
  if current > size then
    local out = ""
    for char in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if vim.fn.strdisplaywidth(out .. char) > size - 1 then
        return out .. "..."
      end
      out = out .. char
    end
    return out
  end
  return value .. string.rep(" ", size - current)
end

local function option_label(option)
  if type(option) ~= "table" then
    return tostring(option)
  end
  return option.name or option.label or option.kind or option.optionId or option.id or "Select"
end

local function close(choice)
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
  state.selected = 1
  state.options = {}
  state.prompt = ""

  if callback then
    callback(choice)
  end
end

function M.dismiss()
  state.callback = nil

  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if valid_buf(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  state.buf = nil
  state.win = nil
  state.selected = 1
  state.options = {}
  state.prompt = ""
end

local function cleanup_existing()
  state.callback = nil
  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if valid_buf(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  local existing = vim.fn.bufnr("omniac://permission")
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end

  state.buf = nil
  state.win = nil
  state.selected = 1
  state.options = {}
  state.prompt = ""
end

local function render()
  if not valid_buf(state.buf) then
    return
  end

  local width = valid_win(state.win) and vim.api.nvim_win_get_width(state.win) or 58
  local inner_width = math.max(1, width - 4)
  local lines = {}
  local marks = {}

  local function add(text, group)
    table.insert(lines, "  " .. fit(text, inner_width))
    if group then
      table.insert(marks, { #lines - 1, 0, -1, group })
    end
  end

  add(state.prompt, "OmniacPermissionTitle")
  add("", nil)
  for index, option in ipairs(state.options) do
    local prefix = index == state.selected and "> " or "  "
    add(
      prefix .. tostring(index) .. ". " .. option_label(option),
      index == state.selected and "OmniacPermissionSelected" or "OmniacPermissionText"
    )
  end
  add("", nil)
  add("[Enter] choose   [1-9] choose   [j/k] move   [q] reject", "OmniacPermissionMuted")

  vim.bo[state.buf].readonly = false
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].readonly = true
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, mark[4], mark[1], mark[2], mark[3])
  end
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
  render()
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
  setup_highlights()
  cleanup_existing()
  state.options = type(options) == "table" and options or {}
  state.callback = callback
  state.prompt = normalize_text((opts or {}).prompt or "Permission requested")
  state.selected = #state.options > 0 and 1 or 0

  local width = math.min(math.max(58, math.floor(vim.o.columns * 0.36)), math.max(42, vim.o.columns - 8))
  local height = math.min(math.max(6, #state.options + 4), math.max(6, vim.o.lines - 8))
  local row = math.max(0, math.floor((vim.o.lines - height - 4) / 3))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "omniac-permission"
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].readonly = true
  pcall(vim.api.nvim_buf_set_name, state.buf, "omniac://permission")

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Permission ",
    title_pos = "center",
  })
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].winhighlight = "FloatBorder:OmniacPermissionBorder,FloatTitle:OmniacPermissionTitle"

  local function map(lhs, fn)
    vim.keymap.set({ "n", "i" }, lhs, function()
      stop_insert()
      fn()
    end, { buffer = state.buf, nowait = true, silent = true })
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
  for index = 1, math.min(9, #state.options) do
    map(tostring(index), function()
      choose(index)
    end)
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = state.buf,
    once = true,
    callback = function()
      state.callback = nil
      state.buf = nil
      state.win = nil
    end,
  })

  render()
  stop_insert()
  vim.schedule(function()
    if valid_win(state.win) then
      stop_insert()
    end
  end)
  return state
end

return M
