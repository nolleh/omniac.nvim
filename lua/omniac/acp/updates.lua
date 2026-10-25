local content = require("omniac.acp.content")
local filesystem = require("omniac.editor.filesystem")
local normalize = require("omniac.acp.normalize")

local M = {}

local function emit(client, method, params)
  client:_emit_notification({ method = method, params = params })
end

local function tool_activity(update)
  local raw_input = type(update.rawInput) == "table" and update.rawInput or {}
  local normalized_output = normalize.raw_output(update)
  local raw_output = type(normalized_output) == "table" and normalized_output or {}
  local meta = type(update._meta) == "table" and update._meta or {}
  local terminal_exit = type(meta.terminal_exit) == "table" and meta.terminal_exit or {}
  return {
    toolCallId = update.toolCallId,
    kind = update.kind,
    status = update.status,
    title = update.title or raw_input.command or update.kind or update.toolCallId,
    exitCode = raw_output.exit_code or raw_output.exitCode or terminal_exit.exit_code or terminal_exit.exitCode,
  }
end

local function raw_output_text(raw_output)
  if type(raw_output) == "string" then
    return raw_output
  end
  if type(raw_output) ~= "table" then
    return nil
  end
  for _, key in ipairs({ "output", "stdout", "stderr", "text", "message", "content" }) do
    local value = raw_output[key]
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return content.text(raw_output)
end

local function tool_result(update)
  local raw_input = type(update.rawInput) == "table" and update.rawInput or {}
  local raw_output = normalize.raw_output(update)
  local output = raw_output_text(raw_output) or content.text(update.content)
  if type(output) ~= "string" or output == "" then
    return nil
  end
  local raw_output_table = type(raw_output) == "table" and raw_output or {}
  local meta = type(update._meta) == "table" and update._meta or {}
  local terminal_exit = type(meta.terminal_exit) == "table" and meta.terminal_exit or {}
  return {
    toolCallId = update.toolCallId,
    kind = update.kind,
    status = update.status,
    title = update.title or raw_input.command or update.kind or update.toolCallId,
    command = raw_input.command or raw_input.cmd or update.title,
    cwd = raw_input.cwd,
    output = output,
    exitCode = raw_output_table.exit_code
      or raw_output_table.exitCode
      or terminal_exit.exit_code
      or terminal_exit.exitCode,
  }
end

local function file_items(update)
  if type(update) ~= "table" or type(update.content) ~= "table" then
    return {}
  end
  return update.content
end

local function is_file_item(item)
  local meta_kind = type(item) == "table" and type(item._meta) == "table" and item._meta.kind or nil
  return type(item) == "table"
    and (item.type == "diff" or meta_kind == "update" or meta_kind == "add")
    and type(item.path) == "string"
    and type(item.newText) == "string"
end

local function old_text(item)
  return type(item.oldText) == "string" and item.oldText or ""
end

local function edit_call(client, update)
  local call = update.toolCallId and client.edit_tool_calls[update.toolCallId] or nil
  if update.kind == "edit" and update.toolCallId and type(call) ~= "table" then
    call = { turn_id = client.active_turn_id, files = {}, order = {}, title = update.title }
    client.edit_tool_calls[update.toolCallId] = call
  end
  return call
end

local function handle_edit(client, update, call)
  call.title = update.title or call.title
  for _, item in ipairs(file_items(update)) do
    if is_file_item(item) then
      local file = call.files[item.path]
      if not file then
        local completed_without_snapshot = update.status == "completed"
        file = {
          path = item.path,
          oldText = completed_without_snapshot and old_text(item)
            or filesystem.read_disk_content(item.path)
            or old_text(item),
          newText = item.newText,
          operation = type(item._meta) == "table" and item._meta.kind or nil,
          captured_before = not completed_without_snapshot,
        }
        call.files[item.path] = file
        table.insert(call.order, item.path)
      else
        file.newText = item.newText
        file.operation = (type(item._meta) == "table" and item._meta.kind) or file.operation
      end

      if update.status ~= "completed" and update.status ~= "failed" then
        emit(client, "omniac/permission_diff", {
          sessionId = client.session_id,
          turnId = call.turn_id,
          path = item.path,
          oldText = old_text(item),
          newText = item.newText,
          toolCallId = update.toolCallId,
          title = update.title,
          status = update.status,
        })
      end
    end
  end

  if update.status == "completed" then
    for _, path in ipairs(call.order) do
      local file = call.files[path]
      local new_text = file.newText
      if file.captured_before then
        new_text = filesystem.read_disk_content(path)
        if new_text == nil and file.operation == "delete" then
          new_text = ""
        end
        new_text = new_text or file.newText
      end
      emit(client, "omniac/file_update", {
        sessionId = client.session_id,
        turnId = call.turn_id,
        path = path,
        oldText = file.oldText,
        newText = new_text,
        operation = file.operation,
        toolCallId = update.toolCallId,
        title = call.title,
        status = update.status,
        error = update.error or update.rawOutput,
      })
    end
  elseif update.status == "failed" then
    emit(client, "omniac/edit_failed", {
      toolCallId = update.toolCallId,
      title = update.title,
      error = update.error or update.rawOutput,
    })
  end

  if update.status == "completed" or update.status == "failed" then
    client.edit_tool_calls[update.toolCallId] = nil
  end
end

function M.handle(client, update)
  local update_type = normalize.update_type(update)

  if update_type == "tool_call" or update_type == "tool_call_update" then
    emit(client, "omniac/tool_activity", tool_activity(update))
  end
  if update_type == "available_commands_update" then
    emit(client, "omniac/available_commands_update", {
      sessionId = client.session_id,
      availableCommands = normalize.available_commands(update),
    })
    return true
  end
  if update_type == "config_option_update" then
    client:_apply_session_state({ configOptions = normalize.config_options(update) })
    return true
  end
  if update_type == "usage_update" then
    emit(client, "omniac/usage_update", {
      sessionId = client.session_id,
      used = update.used,
      size = update.size,
      cost = update.cost,
    })
    return true
  end
  if update_type == "current_mode_update" then
    if client.session_mode then
      client.session_mode.currentModeId = normalize.mode_id(update) or client.session_mode.currentModeId
    else
      client.session_mode = {
        source = "modes",
        currentModeId = normalize.mode_id(update),
        availableModes = {},
      }
    end
    client:_emit_session_mode_update()
    return true
  end

  local call = type(update) == "table" and edit_call(client, update) or nil
  if (update_type == "tool_call" or update_type == "tool_call_update") and call then
    handle_edit(client, update, call)
    return true
  end
  if
    (update_type == "tool_call" or update_type == "tool_call_update")
    and (update.status == "completed" or update.status == "failed")
  then
    local result = tool_result(update)
    if result then
      emit(client, "omniac/tool_result", result)
    end
  end

  if update_type == "agent_thought_chunk" then
    local text = content.text(update.content or update.delta or update)
    local title = type(text) == "string" and text:match("^%s*%*%*(.-)%*%*%s*$") or nil
    if title and title ~= "" and client.active_turn_id ~= nil then
      emit(client, "omniac/thought_activity", {
        text = title,
        sessionId = client.session_id,
        turnId = client.active_turn_id,
      })
    end
    return true
  end
  if update_type == "agent_message_chunk" or update_type == "agent_message_final" then
    local text = content.text(update.content or update.delta or update)
    if text and text ~= "" then
      if client.active_turn_id ~= nil then
        table.insert(client.response_chunks, text)
        client.response_streamed = true
      end
      emit(client, "omniac/response_chunk", {
        text = text,
        sessionId = client.session_id,
        turnId = client.active_turn_id,
      })
    end
    return true
  end

  return false
end

return M
