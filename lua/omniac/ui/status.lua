local M = {}

local function capsules(state)
  local config = state.session_config or {}
  local model = state.session_model and (state.session_model.currentModelName or state.session_model.currentModelId)
  local effort = config.reasoning_effort
  local collaboration = config.collaboration_mode
  local mode_id = config.mode or (state.session_mode and state.session_mode.currentModeId)
  local mode = state.session_mode and state.session_mode.currentModeId == mode_id and state.session_mode.currentModeName
    or mode_id
  if mode_id == "plan" then
    mode = nil
  end
  if model and effort and effort ~= "" then
    model = model .. " · " .. effort:sub(1, 1):upper() .. effort:sub(2)
  end
  local usage
  if state.session_usage then
    local percent = math.floor((state.session_usage.used / state.session_usage.size) * 100 + 0.5)
    usage = string.format("ctx %d%%", math.max(0, math.min(100, percent)))
  end

  local result = {}
  local function append(label, fill, edge)
    if label and label ~= "" then
      table.insert(result, { label = label, fill = fill, edge = edge })
    end
  end
  if state.status == "error" then
    append("Error", "OmniacStatusMode", "OmniacStatusModeEdge")
  end
  append(mode, "OmniacStatusMode", "OmniacStatusModeEdge")
  if collaboration == "plan" or mode_id == "plan" then
    append("Plan", "OmniacStatusPlan", "OmniacStatusPlanEdge")
  end
  append(model, "OmniacStatusCapsuleAlt", "OmniacStatusCapsuleAltEdge")
  append(usage, "OmniacStatusUsage", "OmniacStatusUsageEdge")
  return result
end

function M.render(opts)
  if not opts.valid_buf(opts.state.status_buf) then
    return
  end

  local state = opts.state
  local win_width = opts.valid_win(state.status_win) and vim.api.nvim_win_get_width(state.status_win) or opts.width()
  local items = capsules(state)
  local parts = {}
  for _, item in ipairs(items) do
    table.insert(parts, " " .. item.label .. " ")
  end

  vim.bo[state.status_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.status_buf, opts.namespace, 0, -1)
  vim.api.nvim_buf_set_lines(state.status_buf, 0, -1, false, { opts.fit(table.concat(parts, " "), win_width) })
  vim.bo[state.status_buf].modifiable = false
  vim.bo[state.status_buf].modified = false

  local col = 0
  local function add_capsule(value, fill, edge)
    opts.add_hl(state.status_buf, 1, col, col + #"", edge)
    col = col + #""
    opts.add_hl(state.status_buf, 1, col, col + #value, fill)
    col = col + #value
    opts.add_hl(state.status_buf, 1, col, col + #"", edge)
    col = col + #""
  end
  for index, item in ipairs(items) do
    if index > 1 then
      col = col + 1
    end
    add_capsule(" " .. item.label .. " ", item.fill, item.edge)
  end
end

return M
