local M = {}

local ns = vim.api.nvim_create_namespace("omniac.permission_dialog")
local PERMISSION_MARKDOWN_RENDER_CONFIG = {
  pipe_table = {
    border_virtual = true,
    style = "normal",
  },
}

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

local function normalize_body(text)
  if type(text) == "table" then
    return table.concat(text, "\n")
  end

  return tostring(text or "")
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

  for _, win in ipairs({ state.selector_win, state.body_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.selector_buf, state.body_buf }) do
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  state.body_buf = nil
  state.body_win = nil
  state.selector_buf = nil
  state.selector_win = nil
  state.selected = 1
  state.options = {}
  state.prompt = ""
  state.body = ""

  if callback then
    callback(choice)
  end
end

function M.dismiss()
  state.callback = nil

  for _, win in ipairs({ state.selector_win, state.body_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.selector_buf, state.body_buf }) do
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  state.body_buf = nil
  state.body_win = nil
  state.selector_buf = nil
  state.selector_win = nil
  state.selected = 1
  state.options = {}
  state.prompt = ""
  state.body = ""
end

local function cleanup_existing()
  state.callback = nil
  for _, win in ipairs({ state.selector_win, state.body_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.selector_buf, state.body_buf }) do
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local existing = vim.fn.bufnr("omniac://permission")
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end

  state.body_buf = nil
  state.body_win = nil
  state.selector_buf = nil
  state.selector_win = nil
  state.selected = 1
  state.options = {}
  state.prompt = ""
  state.body = ""
end

local function render_permission_markdown(buf, win)
  if not valid_buf(buf) then
    return
  end

  local ok, renderer = pcall(require, "render-markdown")
  if not ok or type(renderer) ~= "table" then
    return
  end

  if renderer.initialized == false and type(renderer.setup) == "function" then
    pcall(
      renderer.setup,
      vim.tbl_deep_extend("force", {
        file_types = { "markdown" },
      }, PERMISSION_MARKDOWN_RENDER_CONFIG)
    )
  end

  if type(renderer.render) == "function" then
    local ok_state, renderer_state = pcall(require, "render-markdown.state")
    if ok_state and type(renderer_state) == "table" and type(renderer_state.cache) == "table" then
      renderer_state.cache[buf] = nil
    end
    pcall(renderer.render, {
      buf = buf,
      win = win,
      event = "OmniacPermissionRender",
      config = PERMISSION_MARKDOWN_RENDER_CONFIG,
    })
  elseif type(renderer.buf_enable) == "function" then
    pcall(renderer.buf_enable)
  end
end

local function render_selector()
  if not valid_buf(state.selector_buf) then
    return
  end

  local lines = {}
  local marks = {}

  for index, option in ipairs(state.options) do
    table.insert(lines, tostring(index) .. ". " .. option_label(option))
    table.insert(
      marks,
      { line = #lines, group = index == state.selected and "OmniacPermissionSelected" or "OmniacPermissionText" }
    )
  end

  table.insert(lines, "")
  table.insert(marks, { line = #lines, group = nil })
  table.insert(lines, "[Enter] choose   [1-9] choose   [j/k] move   [q] reject")
  table.insert(marks, { line = #lines, group = "OmniacPermissionMuted" })

  vim.bo[state.selector_buf].readonly = false
  vim.bo[state.selector_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.selector_buf, 0, -1, false, lines)
  vim.bo[state.selector_buf].modifiable = false
  vim.bo[state.selector_buf].readonly = true
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
    table.insert(lines, "> Review request details below.")
    table.insert(lines, "")
    for _, line in ipairs(vim.split(state.body, "\n", { plain = true, trimempty = false })) do
      table.insert(lines, line)
    end
  end

  vim.bo[state.body_buf].readonly = false
  vim.bo[state.body_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.body_buf, 0, -1, false, lines)
  vim.bo[state.body_buf].modifiable = false
  vim.bo[state.body_buf].readonly = true
  render_permission_markdown(state.body_buf, state.body_win)
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
  setup_highlights()
  cleanup_existing()
  state.options = type(options) == "table" and options or {}
  state.callback = callback
  state.prompt = normalize_text((opts or {}).prompt or "Permission requested")
  state.body = normalize_body((opts or {}).body or (opts or {}).details or "")
  state.selected = #state.options > 0 and 1 or 0

  local width = math.min(math.max(58, math.floor(vim.o.columns * 0.36)), math.max(42, vim.o.columns - 8))
  local body_text_lines = 1
  if state.body ~= "" then
    body_text_lines = body_text_lines + 1 + #vim.split(state.body, "\n", { plain = true, trimempty = false })
  end
  local selector_lines = math.max(3, #state.options + 2)
  local max_total = math.max(6, vim.o.lines - 8)
  local gap = 1
  local selector_height = math.min(selector_lines, max_total)
  local body_height = math.min(math.max(3, body_text_lines), math.max(3, max_total - selector_height - gap))
  local total_height = body_height + selector_height + gap
  if total_height > max_total then
    selector_height = math.max(3, max_total - body_height - gap)
    total_height = body_height + selector_height + gap
  end
  local row = math.max(0, math.floor((vim.o.lines - total_height - 4) / 3))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  state.body_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.body_buf].buftype = "nofile"
  vim.bo[state.body_buf].bufhidden = "wipe"
  vim.bo[state.body_buf].swapfile = false
  vim.bo[state.body_buf].filetype = "markdown"
  vim.bo[state.body_buf].modifiable = false
  vim.bo[state.body_buf].readonly = true
  pcall(vim.api.nvim_buf_set_name, state.body_buf, "omniac://permission")

  state.body_win = vim.api.nvim_open_win(state.body_buf, false, {
    relative = "editor",
    width = width,
    height = body_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Permission ",
    title_pos = "center",
  })
  vim.wo[state.body_win].wrap = false
  vim.wo[state.body_win].cursorline = false
  vim.wo[state.body_win].signcolumn = "no"
  vim.wo[state.body_win].winhighlight = "FloatBorder:OmniacPermissionBorder,FloatTitle:OmniacPermissionTitle"

  state.selector_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.selector_buf].buftype = "nofile"
  vim.bo[state.selector_buf].bufhidden = "wipe"
  vim.bo[state.selector_buf].swapfile = false
  vim.bo[state.selector_buf].filetype = "omniac-permission"
  vim.bo[state.selector_buf].modifiable = false
  vim.bo[state.selector_buf].readonly = true
  pcall(vim.api.nvim_buf_set_name, state.selector_buf, "omniac://permission-selector")

  state.selector_win = vim.api.nvim_open_win(state.selector_buf, true, {
    relative = "editor",
    width = width,
    height = selector_height,
    row = row + body_height + gap,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Select ",
    title_pos = "center",
  })
  vim.wo[state.selector_win].wrap = false
  vim.wo[state.selector_win].cursorline = false
  vim.wo[state.selector_win].signcolumn = "no"
  vim.wo[state.selector_win].winhighlight = "FloatBorder:OmniacPermissionBorder,FloatTitle:OmniacPermissionTitle"

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
      render_permission_markdown(state.body_buf, state.body_win)
    end
    if valid_win(state.selector_win) then
      render_selector_selection()
      stop_insert()
    end
  end)
  return state
end

return M
