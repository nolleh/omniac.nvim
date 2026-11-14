local M = {}

local markers = { pending = "[ ]", in_progress = "[~]", completed = "[x]", cancelled = "[-]" }

function M.clear(state)
  state.plan_entries = nil
  state.plan_notice_index = nil
  state.plan_documents = nil
  state.plan_document_order = nil
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

local function document_text(document, footer)
  local value
  if document.type == "items" then
    return text(document.entries, footer)
  elseif document.type == "markdown" then
    value = document.content
  elseif document.type == "file" then
    value = "Plan file: " .. document.uri
  else
    value = "Unsupported plan content: " .. tostring(document.type)
  end
  return footer and (value .. "\n\n" .. footer) or value
end

local function update_document(state, params, config, handlers)
  local documents = state.plan_documents or {}
  if type(params.removedPlanId) == "string" then
    local previous = documents[params.removedPlanId]
    if previous then
      handlers.update_notice(previous.notice_index, "Plan removed.", config)
      documents[params.removedPlanId] = nil
      handlers.render_activity()
    end
    return
  end
  local document = params.plan
  if type(document) ~= "table" or type(document.planId) ~= "string" or type(document.type) ~= "string" then
    return
  end
  document = vim.deepcopy(document)
  if document.type == "items" then
    if type(document.entries) ~= "table" then
      return
    end
    local entries = {}
    for _, entry in ipairs(document.entries) do
      if type(entry) == "table" and type(entry.content) == "string" and markers[entry.status] then
        table.insert(entries, entry)
      end
    end
    document.entries = entries
  elseif document.type == "markdown" and type(document.content) ~= "string" then
    return
  elseif document.type == "file" and type(document.uri) ~= "string" then
    return
  end
  local previous = documents[document.planId]
  document.notice_index = previous and previous.notice_index or nil
  if document.notice_index then
    handlers.update_notice(document.notice_index, document_text(document), config)
  else
    document.notice_index = handlers.add_notice("Plan", document_text(document), config)
  end
  documents[document.planId] = document
  state.plan_documents = documents
  local order = state.plan_document_order or {}
  for index = #order, 1, -1 do
    if order[index] == document.planId then
      table.remove(order, index)
    end
  end
  table.insert(order, document.planId)
  state.plan_document_order = order
  handlers.render_activity()
end

function M.update(state, params, config, handlers)
  if params.plan ~= nil or params.removedPlanId ~= nil then
    update_document(state, params, config, handlers)
    return
  end
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
  for _, document in pairs(state.plan_documents or {}) do
    handlers.update_notice(document.notice_index, document_text(document, reason), config)
  end
  M.clear(state)
end

function M.activity(state)
  local entries = state.plan_entries
  for index = #(state.plan_document_order or {}), 1, -1 do
    local document = state.plan_documents[state.plan_document_order[index]]
    if document then
      if document.type == "items" then
        entries = document.entries
        break
      elseif document.type == "markdown" then
        local title = document.content:match("[^\r\n]+") or ""
        return "Plan: " .. title:gsub("^%s*#+%s*", "")
      elseif document.type == "file" then
        return "Plan: " .. document.uri
      else
        return "Plan: unsupported content"
      end
    end
  end
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
