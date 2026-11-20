local content = require("omniac.acp.content")
local filesystem = require("omniac.editor.filesystem")
local normalize = require("omniac.acp.normalize")
local tool_calls = require("omniac.acp.tool_calls")
local snapshot = require("omniac.changes.snapshot")

local M = {}

local function emit(client, method, params)
  client:_emit_notification({ method = method, params = params })
end

local function file_items(update, client)
  if type(update) ~= "table" then
    return {}
  end
  local items = type(update.content) == "table" and update.content or {}
  for _, item in ipairs(items) do
    if type(item) == "table" and item.type == "diff" then
      return items
    end
  end
  local previous = update.toolCallId and client.tool_calls[update.toolCallId]
  local kind = update.kind or (previous and previous.kind)
  if kind == "edit" and update.status ~= "completed" and update.status ~= "failed" then
    local preview = require("omniac.acp.edit_preview").from_input(update.rawInput, (client.config.agent or {}).cwd)
    if preview then
      items = vim.list_extend(vim.list_slice(items), { preview })
    end
  end
  return items
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
  local previous = update.toolCallId and client.tool_calls[update.toolCallId]
  local kind = update.kind or (previous and previous.kind)
  for _, item in ipairs(file_items(update, client)) do
    if is_file_item(item) then
      kind = "edit"
      break
    end
  end
  if (kind == "edit" or kind == "delete" or kind == "move") and update.toolCallId and type(call) ~= "table" then
    call = { turn_id = client.active_turn_id, files = {}, order = {}, title = update.title }
    call.baseline = client.workspace and client.workspace:checkpoint()
    client.edit_tool_calls[update.toolCallId] = call
  end
  return call
end

local function handle_edit(client, update, call)
  call.title = update.title or call.title
  local workspace = client.workspace
  local function recover_before(path, item, before)
    if not call.baseline then
      return before
    end
    local current = before
    if current == nil and not (vim.uv or vim.loop).fs_lstat(path) then
      current = ""
    end
    local old, new = old_text(item), item.newText
    if type(current) ~= "string" or old == new then
      return before
    end
    -- A start notification can arrive after the agent has saved the file.
    -- Recover only when the reported edit already appears on disk and its
    -- old text agrees with our preceding workspace snapshot.
    local already_applied = (new == "" or current:find(new, 1, true)) and (old == "" or not current:find(old, 1, true))
    if already_applied then
      local previous = snapshot.content(call.baseline, path)
      if
        type(previous) == "string"
        and previous ~= current
        and ((old == "" and previous == "") or (old ~= "" and previous:find(old, 1, true)))
      then
        return previous
      end
    end
    return before
  end
  local function absolute(path)
    if path:sub(1, 1) == "/" then
      return vim.fs.normalize(path)
    end
    return vim.fs.normalize(((client.config.agent or {}).cwd or vim.loop.cwd()) .. "/" .. path)
  end
  for _, location in ipairs(type(update.locations) == "table" and update.locations or {}) do
    if type(location.path) == "string" then
      local path = absolute(location.path)
      if not call.files[path] then
        local before
        if update.status ~= "completed" and update.status ~= "failed" then
          before = filesystem.read_disk_content(path)
          if before == nil and not (vim.uv or vim.loop).fs_lstat(path) then
            before = ""
          end
        else
          before = workspace and snapshot.content(workspace.initial, path)
        end
        call.files[path] = { path = path, oldText = before, captured_before = before ~= nil }
        table.insert(call.order, path)
      end
    end
  end
  for _, item in ipairs(file_items(update, client)) do
    if is_file_item(item) then
      local path = absolute(item.path)
      local file = call.files[path]
      if not file then
        local completed_without_snapshot = update.status == "completed"
        local before
        if not completed_without_snapshot and update.status ~= "failed" then
          before = recover_before(path, item, filesystem.read_disk_content(path))
        else
          before = workspace and snapshot.content(workspace.initial, path)
        end
        file = {
          path = path,
          oldText = type(before) == "string" and before
            or (completed_without_snapshot and old_text(item) or filesystem.read_disk_content(path) or old_text(item)),
          newText = item.newText,
          operation = type(item._meta) == "table" and item._meta.kind or nil,
          captured_before = type(before) == "string" or not completed_without_snapshot,
        }
        call.files[path] = file
        table.insert(call.order, path)
      else
        file.oldText = recover_before(path, item, file.oldText)
        file.captured_before = type(file.oldText) == "string"
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

  if update.status == "completed" or update.status == "failed" then
    for _, path in ipairs(call.order) do
      local file = call.files[path]
      local new_text = file.newText
      if file.captured_before then
        new_text = filesystem.read_disk_content(path)
        if new_text == nil and not (vim.uv or vim.loop).fs_lstat(path) then
          new_text = ""
        end
        if update.status ~= "failed" then
          new_text = new_text or file.newText
        end
      end
      if type(file.oldText) == "string" and type(new_text) == "string" and file.oldText ~= new_text then
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
    end
  end
  if update.status == "failed" then
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
  if update_type == "session_info_update" then
    require("omniac.acp.steering").status(client, update)
    return true
  end
  if update_type == "plan_update" or update_type == "plan_removed" then
    emit(client, "omniac/plan_update", {
      sessionId = client.session_id,
      turnId = client.active_turn_id,
      plan = update.plan,
      removedPlanId = update_type == "plan_removed" and update.planId or nil,
    })
    return true
  end
  if update_type == "plan" then
    emit(client, "omniac/plan_update", {
      sessionId = client.session_id,
      turnId = client.active_turn_id,
      entries = update.entries,
    })
    return true
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
  if update_type == "tool_call" or update_type == "tool_call_update" then
    local activity, result = tool_calls.update(client, update)
    emit(client, "omniac/tool_activity", activity)
    if client.workspace then
      client.workspace:update(update, activity)
    end
    if call then
      handle_edit(client, update, call)
    elseif result then
      emit(client, "omniac/tool_result", result)
    end
    return true
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

  if update_type == "user_message_chunk" then
    local block = update.content or update.delta or update
    local text = type(block) == "table" and block.type == "image" and "[Image attachment]" or content.text(block)
    if text and text ~= "" then
      emit(client, "omniac/user_message_chunk", {
        text = text,
        sessionId = client.session_id,
        messageId = update.messageId or update.message_id,
      })
    end
    return true
  end

  return false
end

return M
