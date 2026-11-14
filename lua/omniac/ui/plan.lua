local M = {}

local markers = { pending = "[ ]", in_progress = "[~]", completed = "[x]" }

function M.clear(state)
  state.plan_entries = nil
  state.plan_notice_index = nil
end

local function text(entries, footer)
  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, "- " .. markers[entry.status] .. " " .. entry.content)
  end
  if #lines == 0 then
    table.insert(lines, "Plan cleared.")
  end
  if footer then
    table.insert(lines, "")
    table.insert(lines, footer)
  end
  return table.concat(lines, "\n")
end

function M.update(state, params, config, handlers)
  if type(params.entries) ~= "table" then
    return
  end
  local entries = {}
  for _, entry in ipairs(params.entries) do
    if type(entry) == "table" and type(entry.content) == "string" and markers[entry.status] then
      table.insert(entries, {
        content = entry.content,
        priority = entry.priority,
        status = entry.status,
      })
    end
  end
  state.plan_entries = entries
  local value = text(entries)
  if state.plan_notice_index then
    handlers.update_notice(state.plan_notice_index, value, config)
  elseif #entries > 0 then
    state.plan_notice_index = handlers.add_notice("Plan", value, config)
  end
  handlers.render_activity()
end

function M.finish(state, reason, config, handlers)
  if state.plan_notice_index then
    handlers.update_notice(state.plan_notice_index, text(state.plan_entries, reason), config)
  end
  M.clear(state)
end

function M.activity(state)
  local entries = state.plan_entries
  if type(entries) ~= "table" or #entries == 0 then
    return nil
  end
  local completed = 0
  local current
  local pending
  for _, entry in ipairs(entries) do
    if entry.status == "completed" then
      completed = completed + 1
    elseif entry.status == "in_progress" then
      current = current or entry.content
    else
      pending = pending or entry.content
    end
  end
  local summary = string.format("Plan %d/%d", completed, #entries)
  local step = current or pending
  if step then
    summary = summary .. ": " .. step:gsub("%s+", " ")
  end
  return summary
end

return M
