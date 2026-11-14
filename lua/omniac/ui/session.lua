local M = {}

function M.set_mode(state, mode, render_status)
  state.session_mode = type(mode) == "table" and mode or nil
  render_status()
end

function M.set_model(state, model, render_status)
  state.session_model = type(model) == "table" and model or nil
  render_status()
end

function M.set_config(state, options, render_status)
  local config = {}
  for _, option in ipairs(options or {}) do
    if type(option) == "table" and type(option.id) == "string" then
      config[option.id] = option.currentValue or option.current_value
    end
  end
  state.session_config = config
  render_status()
end

function M.set_usage(state, usage, render_status)
  if type(usage) ~= "table" then
    state.session_usage = nil
    render_status()
    return
  end
  local merged = vim.deepcopy(state.session_usage or {})
  local used, size = tonumber(usage.used), tonumber(usage.size)
  if used and used >= 0 and used < math.huge then
    merged.used = used
  end
  if size and size > 0 and size < math.huge then
    merged.size = size
  end
  local cost = usage.cost
  if type(cost) == "table" and type(cost.amount) == "number" and cost.amount >= 0 and cost.amount < math.huge then
    merged.cost = vim.deepcopy(merged.cost or {})
    merged.cost.amount = cost.amount
    if type(cost.currency) == "string" then
      merged.cost.currency = cost.currency
    end
  end
  state.session_usage = next(merged) and merged or nil
  render_status()
end

function M.set_available_commands(state, commands, update_command_window)
  state.available_commands = type(commands) == "table" and commands or {}
  if update_command_window then
    update_command_window()
  end
end

return M
