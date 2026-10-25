local normalize = require("omniac.acp.normalize")

local M = {}

function M.mode_from_config(config_options)
  if type(config_options) ~= "table" then
    return nil
  end

  for _, option in ipairs(config_options) do
    if
      type(option) == "table"
      and (option.category == "mode" or option.id == "mode")
      and option.type == "select"
      and type(option.options) == "table"
    then
      local modes = {}
      for _, value in ipairs(option.options) do
        local id = type(value) == "table" and (value.value or value.id) or nil
        if type(value) == "table" and type(id) == "string" and id ~= "" then
          table.insert(modes, {
            id = id,
            name = value.name or id,
            description = value.description,
          })
        end
      end
      return {
        source = "config",
        configId = option.id,
        currentModeId = normalize.current_value(option),
        availableModes = modes,
      }
    end
  end

  return nil
end

function M.model_from_config(config_options)
  if type(config_options) ~= "table" then
    return nil
  end

  for _, option in ipairs(config_options) do
    if
      type(option) == "table"
      and (option.category == "model" or option.id == "model")
      and option.type == "select"
      and type(option.options) == "table"
    then
      local models = {}
      for _, value in ipairs(option.options) do
        local id = type(value) == "table" and (value.value or value.id) or value
        if type(id) == "string" and id ~= "" then
          table.insert(models, {
            id = id,
            name = type(value) == "table" and (value.name or id) or id,
            description = type(value) == "table" and value.description or nil,
          })
        end
      end
      return {
        configId = option.id,
        currentModelId = normalize.current_value(option),
        availableModels = models,
      }
    end
  end

  return nil
end

function M.mode_from_modes(modes)
  if type(modes) ~= "table" then
    return nil
  end

  local available = {}
  for _, mode in ipairs(normalize.available_modes(modes)) do
    if type(mode) == "table" and type(mode.id) == "string" and mode.id ~= "" then
      table.insert(available, {
        id = mode.id,
        name = mode.name or mode.id,
        description = mode.description,
      })
    end
  end
  return {
    source = "modes",
    currentModeId = normalize.current_mode_id(modes),
    availableModes = available,
  }
end

local function selected_name(state, items_key, current_key)
  if type(state) ~= "table" then
    return nil
  end
  local current = state[current_key]
  for _, item in ipairs(state[items_key] or {}) do
    if item.id == current then
      return item.name or item.id
    end
  end
  return current
end

function M.mode_name(state)
  return selected_name(state, "availableModes", "currentModeId")
end

function M.model_name(state)
  return selected_name(state, "availableModels", "currentModelId")
end

return M
