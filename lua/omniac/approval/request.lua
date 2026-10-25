local function as_lines(value)
  if type(value) == "table" then
    return value
  end

  if type(value) == "string" then
    return vim.split(value, "\n", { plain = true })
  end

  return nil
end

local function first_option_id(request)
  local options = request and request.options or {}
  if type(options) ~= "table" then
    return nil
  end

  local first = options[1]
  if type(first) == "table" then
    return first.id or first.optionId or first.value or first.label
  end

  return nil
end

local function allow_once_option_id(request)
  for _, option in ipairs((request and request.options) or {}) do
    if type(option) == "table" and option.kind == "allow_once" then
      return option.id or option.optionId or option.value
    end
  end
  return nil
end

local function reject_option_id(request)
  for _, option in ipairs((request and request.options) or {}) do
    if type(option) == "table" and option.kind == "reject_once" then
      return option.id or option.optionId or option.value
    end
  end
  return nil
end

local content_items

content_items = function(value)
  if type(value) ~= "table" then
    return {}
  end

  if type(value.content) == "table" then
    return value.content
  end
  if type(value.contentItems) == "table" then
    return value.contentItems
  end
  if type(value.content_items) == "table" then
    return value.content_items
  end

  return {}
end

local function option_id(option)
  if type(option) ~= "table" then
    return nil
  end

  return option.id or option.optionId or option.value or option.label or option.name
end

local function option_label(option)
  if type(option) ~= "table" then
    return tostring(option)
  end

  return option.name or option.label or option.kind or option_id(option) or "Select"
end

local function permission_summary(params)
  local tool_call = params and params.toolCall or {}
  local kind = tool_call.kind or params.kind or "tool"
  return "Permission requested: " .. tostring(kind)
end

local function string_list(value)
  if type(value) ~= "table" then
    return nil
  end

  local parts = {}
  for _, item in ipairs(value) do
    if type(item) == "string" and item ~= "" then
      table.insert(parts, item)
    end
  end

  if #parts == 0 then
    return nil
  end

  return table.concat(parts, " ")
end

local function content_text(value, seen)
  if type(value) == "string" then
    return value
  end
  if type(value) ~= "table" then
    return nil
  end

  seen = seen or {}
  if seen[value] then
    return nil
  end
  seen[value] = true

  for _, key in ipairs({ "text", "message", "description", "content" }) do
    local found = content_text(value[key], seen)
    if found and found ~= "" then
      return found
    end
  end

  for _, item in ipairs(value) do
    local found = content_text(item, seen)
    if found and found ~= "" then
      return found
    end
  end

  return nil
end

local function permission_paths(tool_call, raw_input)
  local paths = {}
  local seen = {}
  local function add(path)
    if type(path) == "string" and path ~= "" and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end
  local function add_locations(locations)
    if type(locations) ~= "table" then
      return
    end
    for _, location in ipairs(locations) do
      if type(location) == "table" then
        add(location.path or location.filePath or location.uri)
      end
    end
  end

  add(raw_input.path or raw_input.filePath)
  add(tool_call.path)
  add_locations(tool_call.locations)
  add_locations(raw_input.locations)
  for _, item in ipairs(content_items(tool_call)) do
    if type(item) == "table" then
      add(item.path or item.filePath)
    end
  end
  return paths
end

local function permission_body(params)
  local tool_call = params and params.toolCall or {}
  local raw_input = type(tool_call.rawInput) == "table" and tool_call.rawInput or {}
  local lines = {}
  local summary = raw_input.summary or tool_call.summary or params.summary
  local reason = raw_input.reason or tool_call.reason or params.reason
  local description = raw_input.description
    or tool_call.description
    or params.description
    or content_text(tool_call.content)

  local title = tool_call.title or raw_input.title
  if type(title) == "string" and title ~= "" then
    table.insert(lines, "Title: " .. title)
  end

  if type(summary) == "string" and summary ~= "" then
    table.insert(lines, "Summary: " .. summary)
  end

  if type(reason) == "string" and reason ~= "" then
    table.insert(lines, "Reason: " .. reason)
  end

  if type(description) == "string" and description ~= "" then
    table.insert(lines, "")
    table.insert(lines, description)
  end

  local command = raw_input.command or raw_input.cmd
  if type(command) == "string" and command ~= "" then
    table.insert(lines, "")
    table.insert(lines, "Command:")
    table.insert(lines, "```sh")
    table.insert(lines, command)
    table.insert(lines, "```")
  end

  local args = string_list(raw_input.args or raw_input.argv)
  if args then
    table.insert(lines, "")
    table.insert(lines, "Args:")
    table.insert(lines, "```sh")
    table.insert(lines, args)
    table.insert(lines, "```")
  end

  local cwd = raw_input.cwd
  if type(cwd) == "string" and cwd ~= "" then
    table.insert(lines, "")
    table.insert(lines, "cwd: `" .. cwd .. "`")
  end

  local paths = permission_paths(tool_call, raw_input)
  if #paths == 1 then
    table.insert(lines, "")
    table.insert(lines, "path: `" .. paths[1] .. "`")
  elseif #paths > 1 then
    table.insert(lines, "")
    table.insert(lines, "Files:")
    for _, path in ipairs(paths) do
      table.insert(lines, "- `" .. path .. "`")
    end
  end

  return table.concat(lines, "\n")
end

local function permission_details(params)
  local body = permission_body(params)
  if body == "" then
    return permission_summary(params)
  end

  return table.concat({ permission_summary(params), "", body }, "\n")
end

local function permission_result_text(option, accepted)
  if type(option) == "table" then
    return "Decision: " .. option_label(option)
  end
  return accepted and "Decision: Accepted" or "Decision: Cancelled"
end

local function permission_choice_status(option)
  if not option then
    return "rejected"
  end
  local kind = tostring(option.kind or option_id(option) or ""):lower()
  if kind:find("reject", 1, true) or kind:find("deny", 1, true) then
    return "rejected"
  end
  return "approved"
end

local function show_permission_text(params, config)
  local ok, ui = pcall(require, "omniac.ui")
  if not ok or not ui then
    return nil, nil
  end
  local notice_index = nil
  local details = permission_details(params)
  if ui.add_notice then
    notice_index = ui.add_notice("Permission", details, config)
  elseif ui.add_message then
    ui.add_message("Permission", details, config)
  end
  if ui.set_activity then
    ui.set_activity(permission_summary(params), config)
  end
  return notice_index, details
end

local function update_permission_text(notice_index, base_text, decision, config, status)
  local ok, ui = pcall(require, "omniac.ui")
  if not ok or not ui or not ui.update_notice then
    return
  end

  ui.update_notice(notice_index, table.concat({ base_text or "", "", decision }, "\n"), config, {
    permission_status = status,
  })
  if decision:match("^Decision:") and ui.set_activity then
    ui.set_activity(nil, config)
  end
end

local function selected_permission_response(option)
  if not option then
    return {
      outcome = {
        outcome = "cancelled",
      },
    }
  end

  return {
    outcome = {
      outcome = "selected",
      optionId = option_id(option),
    },
  }
end

return {
  as_lines = as_lines,
  content_items = content_items,
  first_option_id = first_option_id,
  allow_once_option_id = allow_once_option_id,
  reject_option_id = reject_option_id,
  summary = permission_summary,
  body = permission_body,
  result_text = permission_result_text,
  choice_status = permission_choice_status,
  show = show_permission_text,
  update = update_permission_text,
  selected_response = selected_permission_response,
}
