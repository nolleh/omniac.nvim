local choice_dialog = require("omniac.ui.choice_dialog")

local M = {}

function M.open(mode_state, callback)
  local modes = type(mode_state) == "table" and mode_state.availableModes or {}
  if type(modes) ~= "table" or #modes == 0 then
    return false
  end

  local current = mode_state.currentModeId
  local selected = 1
  local options = {}
  for index, mode in ipairs(modes) do
    local name = mode.name or mode.id
    if mode.id == current then
      selected = index
      name = name .. "  (current)"
    end
    table.insert(options, {
      id = mode.id,
      name = name,
      description = mode.description,
    })
  end

  choice_dialog.open(options, {
    title = "Mode",
    prompt = "Select a mode",
    body = "Current mode: " .. tostring(current or "unknown"),
    cancel_label = "close",
    selected = selected,
  }, callback)
  return true
end

return M
