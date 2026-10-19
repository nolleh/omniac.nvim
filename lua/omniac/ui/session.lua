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
  local used = type(usage) == "table" and tonumber(usage.used) or nil
  local size = type(usage) == "table" and tonumber(usage.size) or nil
  if used and size and used >= 0 and size > 0 then
    state.session_usage = {
      used = used,
      size = size,
      cost = usage.cost,
    }
  else
    state.session_usage = nil
  end
  render_status()
end

function M.set_available_commands(state, commands, update_command_window)
  state.available_commands = type(commands) == "table" and commands or {}
  if update_command_window then
    update_command_window()
  end
end

return M
