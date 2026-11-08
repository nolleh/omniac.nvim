local M = {}

function M.floating_win(win, valid_win)
  if not valid_win(win) then
    return false
  end
  local ok, config = pcall(vim.api.nvim_win_get_config, win)
  return ok and config.relative ~= ""
end

function M.is_ui_win(state, win)
  return win == state.card_win
    or win == state.chat_win
    or win == state.activity_win
    or win == state.input_win
    or win == state.status_win
end

function M.target_width(state)
  local configured = ((state.config or {}).ui or {}).chat_width or 58
  local value = state.user_width or math.min(math.max(configured, 42), math.max(42, vim.o.columns - 20))
  return math.min(math.max(value, 42), math.max(42, vim.o.columns - 20))
end

function M.capture_width(state, valid_win)
  if valid_win(state.chat_win) then
    state.user_width = vim.api.nvim_win_get_width(state.chat_win)
  end
end

function M.configure_window(win)
  vim.w[win].omniac_ui = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  vim.wo[win].list = false
end

function M.reset_leftcol(win, valid_win)
  if not valid_win(win) then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.fn.winrestview({ leftcol = 0 })
  end)
end

function M.open_split(command, buf)
  vim.cmd(command .. " sbuffer " .. buf)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buflisted = false
  return win
end

function M.input_bottom_position(state, valid_win)
  if not valid_win(state.input_win) then
    return 0, 0
  end
  local pos = vim.api.nvim_win_get_position(state.input_win)
  return pos[1] + vim.api.nvim_win_get_height(state.input_win), pos[2]
end

function M.external_bottom_height(state, target_win, valid_win)
  if not valid_win(target_win) then
    return 0
  end

  local target_pos = vim.api.nvim_win_get_position(target_win)
  local target_left = target_pos[2]
  local target_right = target_left + vim.api.nvim_win_get_width(target_win)
  local windows = {}
  local editor_bottom = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if valid_win(win) and not M.floating_win(win, valid_win) then
      local pos = vim.api.nvim_win_get_position(win)
      local bottom = pos[1] + vim.api.nvim_win_get_height(win)
      editor_bottom = math.max(editor_bottom, bottom)
      table.insert(
        windows,
        { win = win, top = pos[1], left = pos[2], right = pos[2] + vim.api.nvim_win_get_width(win), bottom = bottom }
      )
    end
  end

  local top
  for _, window in ipairs(windows) do
    if
      window.win ~= target_win
      and not vim.w[window.win].omniac_ui
      and window.bottom >= editor_bottom - 1
      and window.left < target_right
      and window.right > target_left
    then
      top = top and math.min(top, window.top) or window.top
    end
  end
  return top and math.max(0, editor_bottom - top) or 0
end

function M.open_windows(state, opts)
  state.chat_win = M.open_split("botright vertical", state.chat_buf)
  M.configure_window(state.chat_win)
  if state.card_pinned then
    vim.wo[state.chat_win].winfixheight = false
  end
  pcall(vim.api.nvim_win_set_width, state.chat_win, M.target_width(state))
  vim.wo[state.chat_win].winfixwidth = true

  state.activity_win = M.open_split("belowright", state.activity_buf)
  M.configure_window(state.activity_win)
  pcall(vim.api.nvim_win_set_height, state.activity_win, state.activity_height or 1)

  state.input_win = M.open_split("belowright", state.input_buf)
  M.configure_window(state.input_win)
  pcall(vim.api.nvim_win_set_height, state.input_win, 3)

  state.status_win = M.open_split("belowright", state.status_buf)
  M.configure_window(state.status_win)
  pcall(vim.api.nvim_win_set_height, state.status_win, 1)

  if state.card_pinned then
    vim.api.nvim_set_current_win(state.chat_win)
    state.card_win = M.open_split("aboveleft", state.card_buf)
    M.configure_window(state.card_win)
    vim.wo[state.card_win].wrap = false
    vim.wo[state.card_win].winbar = " omniac"
    vim.wo[state.chat_win].winbar = ""
    pcall(vim.api.nvim_win_set_height, state.card_win, opts.card_height)
  end
end

function M.resize_windows(state, opts)
  local target = M.target_width(state)
  if state.card_pinned and opts.valid_win(state.card_win) then
    pcall(vim.api.nvim_win_set_width, state.card_win, target)
  end
  if opts.valid_win(state.chat_win) then
    pcall(vim.api.nvim_win_set_width, state.chat_win, target)
    local available = vim.o.lines
      - opts.bottom_stack_height()
      - 3
      - M.external_bottom_height(state, state.chat_win, opts.valid_win)
    if state.card_pinned and opts.valid_win(state.card_win) then
      available = available - opts.card_height - (vim.o.laststatus == 3 and 1 or 2)
    end
    pcall(vim.api.nvim_win_set_height, state.chat_win, math.max(1, available))
  end
  if opts.valid_win(state.status_win) then
    pcall(vim.api.nvim_win_set_width, state.status_win, target)
    pcall(vim.api.nvim_win_set_height, state.status_win, 1)
  end
  if opts.valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_width, state.input_win, target)
    pcall(vim.api.nvim_win_set_height, state.input_win, opts.input_height(target))
    M.reset_leftcol(state.input_win, opts.valid_win)
  end
  if opts.valid_win(state.command_win) then
    pcall(vim.api.nvim_win_set_width, state.command_win, target)
    pcall(vim.api.nvim_win_set_height, state.command_win, 5)
  end
  if opts.valid_win(state.activity_win) then
    pcall(vim.api.nvim_win_set_width, state.activity_win, target)
    pcall(vim.api.nvim_win_set_height, state.activity_win, state.activity_height or 1)
  end
  if state.card_pinned and opts.valid_win(state.card_win) then
    pcall(vim.api.nvim_win_set_height, state.card_win, opts.card_height)
    opts.pin_card_view()
  end
end

function M.move_sidebar(state, direction, valid_win, resize)
  local windows = {}
  if valid_win(state.card_win) then
    table.insert(windows, state.card_win)
  end
  for _, win in ipairs({ state.chat_win, state.activity_win, state.input_win, state.status_win }) do
    if valid_win(win) then
      table.insert(windows, win)
    end
  end
  if #windows == 0 then
    return
  end

  local current = vim.api.nvim_get_current_win()
  local fixed = {}
  for _, win in ipairs(windows) do
    fixed[win] = { height = vim.wo[win].winfixheight, width = vim.wo[win].winfixwidth }
    vim.wo[win].winfixheight = false
    vim.wo[win].winfixwidth = false
  end
  vim.api.nvim_win_call(windows[1], function()
    vim.cmd("wincmd " .. direction)
  end)
  for index = 2, #windows do
    vim.fn.win_splitmove(windows[index], windows[index - 1], { rightbelow = true, vertical = false })
  end
  for _, win in ipairs(windows) do
    vim.wo[win].winfixheight = fixed[win].height
    vim.wo[win].winfixwidth = fixed[win].width
  end
  resize()
  if valid_win(current) then
    vim.api.nvim_set_current_win(current)
  end
end

function M.close_windows(state, valid_win)
  for _, name in ipairs({ "command_win", "input_win", "activity_win", "status_win", "card_win", "chat_win" }) do
    if valid_win(state[name]) then
      pcall(vim.api.nvim_win_close, state[name], true)
    end
    state[name] = nil
  end
end

return M
