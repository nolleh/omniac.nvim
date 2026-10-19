local completion = require("omniac.ui.input.completion")

local M = {}

function M.ensure_buffer(state, valid_buf)
  if valid_buf(state.command_buf) then
    return
  end
  state.command_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.command_buf].buftype = "nofile"
  vim.bo[state.command_buf].bufhidden = "wipe"
  vim.bo[state.command_buf].swapfile = false
  vim.bo[state.command_buf].buflisted = false
  vim.bo[state.command_buf].filetype = "omniac-commands"
  vim.api.nvim_buf_set_name(state.command_buf, "omniac://commands")
end

function M.close(state, opts)
  local had_window = opts.valid_win(state.command_win)
  if had_window then
    pcall(vim.api.nvim_win_close, state.command_win, true)
  end
  state.command_win = nil
  if had_window and opts.resize then
    opts.resize()
    vim.schedule(opts.resize)
  end
end

function M.update(state, value, opts)
  if not opts.valid_win(state.input_win) or not opts.valid_buf(state.input_buf) then
    M.close(state, opts)
    return
  end

  local kind, matches, trigger = completion.current(state.available_commands, value)
  if kind == nil or #matches == 0 then
    M.close(state, opts)
    return
  end

  M.ensure_buffer(state, opts.valid_buf)
  if not opts.valid_win(state.command_win) then
    local row, col = opts.position()
    state.command_win = vim.api.nvim_open_win(state.command_buf, false, {
      relative = "editor",
      width = opts.width(),
      height = 1,
      row = row,
      col = col,
      style = "minimal",
      border = "none",
      focusable = false,
    })
    opts.configure_window(state.command_win)
    vim.wo[state.command_win].wrap = false
    vim.wo[state.command_win].statusline = "%#OmniacStatus#%="
  end

  local target = opts.width()
  local display_count = math.min(5, #matches)
  local row, col = opts.position()
  pcall(vim.api.nvim_win_set_config, state.command_win, {
    relative = "editor",
    width = target,
    height = display_count,
    row = row,
    col = col,
  })
  pcall(vim.api.nvim_win_set_width, state.command_win, target)
  pcall(vim.api.nvim_win_set_height, state.command_win, display_count)

  local lines = {}
  local marks = {}
  for index = 1, display_count do
    local item = matches[index]
    local item_trigger = kind == "mention" and "@" or (item.trigger or trigger or "/")
    local hint = item.input and item.input.hint and (" " .. item.input.hint) or ""
    local description = item.description ~= "" and (" - " .. item.description) or ""
    local source = item.source == "omniac" and " client" or ""
    local line = opts.fit(item_trigger .. item.name .. hint .. description .. source, target)
    table.insert(lines, line)
    table.insert(marks, {
      line = index,
      name_to = math.min(#item.name + 1, #line),
      source = item.source,
    })
  end

  vim.bo[state.command_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.command_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.command_buf, opts.namespace, 0, -1)
  for _, mark in ipairs(marks) do
    opts.add_hl(state.command_buf, mark.line, 0, 1, "OmniacCommandMuted")
    local name_group = mark.source == "omniac" and "OmniacCommandClientName" or "OmniacCommandName"
    opts.add_hl(state.command_buf, mark.line, 1, mark.name_to + 1, name_group)
    opts.add_hl(state.command_buf, mark.line, mark.name_to + 1, -1, "OmniacCommandText")
  end
  vim.bo[state.command_buf].modifiable = false
  vim.bo[state.command_buf].modified = false
end

return M
