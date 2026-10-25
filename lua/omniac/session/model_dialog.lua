local choice_dialog = require("omniac.ui.choice_dialog")

local M = {}

function M.open(model_state, callback)
  local models = type(model_state) == "table" and model_state.availableModels or {}
  if type(models) ~= "table" or #models == 0 then
    return false
  end

  local current = model_state.currentModelId
  local selected = 1
  local options = {}
  for index, model in ipairs(models) do
    local id = model.id or model.value
    local name = model.name or id
    local is_current = id == current or name == current
    if type(id) == "string" and type(current) == "string" and id:lower() == current:lower() then
      is_current = true
    end
    if type(name) == "string" and type(current) == "string" and name:lower() == current:lower() then
      is_current = true
    end
    if is_current then
      selected = index
      name = name .. "  (current)"
    end
    table.insert(options, {
      id = id,
      name = name,
      description = model.description,
    })
  end

  choice_dialog.open(options, {
    title = "Model",
    prompt = "Select a model",
    body = "Current model: " .. tostring(current or "unknown"),
    cancel_label = "close",
    selected = selected,
  }, callback)
  return true
end

return M
