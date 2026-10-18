local M = {}

function M.clear(state)
  state.input_history_index = nil
  state.input_history_draft = nil
  state.input_history_navigating = false
  state.input_history_render_pending = false
  state.input_history_pending_text = nil
  state.input_history_pending_cursor = nil
  state.input_history_render_generation = state.input_history_render_generation + 1
end

function M.remember(state, text)
  if type(text) == "string" and not text:match("^%s*$") then
    table.insert(state.input_history, text)
  end
end

local function schedule_render(state, value, cursor_col, opts)
  state.input_history_pending_text = value or ""
  state.input_history_pending_cursor = cursor_col or #state.input_history_pending_text
  if state.input_history_render_pending then
    return
  end

  state.input_history_render_pending = true
  state.input_history_navigating = true
  local generation = state.input_history_render_generation
  vim.schedule(function()
    if generation ~= state.input_history_render_generation then
      return
    end
    state.input_history_render_pending = false
    if not opts.valid_buf(state.input_buf) then
      state.input_history_navigating = false
      return
    end

    local text = state.input_history_pending_text or ""
    local col = math.max(0, tonumber(state.input_history_pending_cursor) or #text)
    opts.render(text, { line = 1, col = col })
    state.input_history_navigating = false
  end)
end

function M.navigate(state, direction, opts)
  local history = state.input_history or {}
  if #history == 0 then
    return false
  end

  local current_text = opts.read()
  if not state.input_history_index then
    if direction > 0 or current_text:match("^%s*$") == nil then
      return false
    end
    state.input_history_draft = current_text
    state.input_history_index = #history
  else
    state.input_history_index = state.input_history_index + direction
    if state.input_history_index < 1 then
      state.input_history_index = 1
    end
    if state.input_history_index > #history then
      local draft = state.input_history_draft or ""
      M.clear(state)
      schedule_render(state, draft, #draft, opts)
      vim.cmd("startinsert!")
      return true
    end
  end

  local text = history[state.input_history_index] or ""
  schedule_render(state, text, #text, opts)
  vim.cmd("startinsert!")
  return true
end

return M
