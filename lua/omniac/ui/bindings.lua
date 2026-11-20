local M = {}

local function move_focus(state, direction, valid_win)
  if vim.fn.mode():match("^[iR]") then
    vim.cmd("stopinsert")
  end

  local windows = {}
  if valid_win(state.card_win) then
    table.insert(windows, state.card_win)
  end
  local areas = { state.chat_win }
  if state.activity_plan_visible and state.plan_expanded then
    table.insert(areas, state.activity_win)
  end
  table.insert(areas, state.input_win)
  for _, win in ipairs(areas) do
    if valid_win(win) then
      table.insert(windows, win)
    end
  end

  local current = vim.api.nvim_get_current_win()
  local index
  for window_index, win in ipairs(windows) do
    if win == current then
      index = window_index
      break
    end
  end

  local target_index
  if index then
    target_index = index + direction
  elseif current == state.activity_win then
    target_index = direction == -1 and #windows - 1 or #windows
  elseif current == state.status_win and direction == -1 then
    target_index = #windows
  end
  local target = target_index and windows[target_index]
  if target then
    vim.api.nvim_set_current_win(target)
  end
end

local function bind_focus_movement(state, buf, opts)
  local function bind(key, direction)
    vim.keymap.set({ "n", "i" }, key, function()
      move_focus(state, direction, opts.valid_win)
    end, {
      buffer = buf,
      nowait = true,
      desc = "Move to Omniac area " .. (direction == -1 and "above" or "below"),
    })
  end
  bind("<C-k>", -1)
  bind("<C-j>", 1)
end

local function bind_sidebar_movement(buf, opts)
  local function bind(key, direction)
    vim.keymap.set("n", key, function()
      opts.move_sidebar(direction)
    end, {
      buffer = buf,
      nowait = true,
      desc = "Move Omniac sidebar " .. (direction == "H" and "left" or "right"),
    })
  end
  bind("<C-w>H", "H")
  bind("<C-w>L", "L")
end

function M.setup(state, opts)
  for _, buf in ipairs({ state.chat_buf, state.activity_buf, state.status_buf }) do
    vim.keymap.set({ "n", "i" }, "<C-p>", opts.toggle_plan_details, {
      buffer = buf,
      nowait = true,
      desc = "Expand or collapse Omniac plan",
    })
  end

  for _, buf in ipairs({ state.chat_buf, state.activity_buf, state.input_buf, state.status_buf }) do
    vim.keymap.set({ "n", "i" }, "<C-t>", opts.toggle_tool_output, {
      buffer = buf,
      nowait = true,
      desc = "Toggle Omniac tool output",
    })
  end

  for _, buf in ipairs({ state.chat_buf, state.activity_buf, state.status_buf }) do
    vim.keymap.set("n", "i", opts.focus_input, { buffer = buf, nowait = true, desc = "Focus Omniac input" })
  end

  for _, buf in ipairs({ state.chat_buf, state.activity_buf, state.input_buf, state.status_buf, state.card_buf }) do
    bind_focus_movement(state, buf, opts)
    bind_sidebar_movement(buf, opts)
  end

  for _, buf in ipairs({ state.chat_buf, state.input_buf, state.activity_buf }) do
    vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
      if state.plan_toggle_handler then
        state.plan_toggle_handler()
      end
    end, {
      buffer = buf,
      nowait = true,
      desc = "Toggle Omniac plan mode",
    })
  end
end

return M
