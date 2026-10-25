local M = {}

local function aliased(value, camel_case, snake_case)
  if type(value) ~= "table" then
    return nil
  end
  if value[camel_case] ~= nil then
    return value[camel_case]
  end
  return value[snake_case]
end

function M.content_items(value)
  local items = aliased(value, "contentItems", "content_items")
  return type(items) == "table" and items or {}
end

function M.stop_reason(value)
  local reason = aliased(value, "stopReason", "stop_reason")
  if not reason and type(value) == "table" then
    reason = aliased(value.result, "stopReason", "stop_reason")
  end
  if reason == "canceled" then
    return "cancelled"
  end
  return type(reason) == "string" and reason or nil
end

function M.turn_id(value)
  local turn_id = aliased(value, "turnId", "turn_id")
  return type(turn_id) == "number" and turn_id or nil
end

local update_types = {
  availableCommandsUpdate = "available_commands_update",
  configOptionUpdate = "config_option_update",
  usageUpdate = "usage_update",
  currentModeUpdate = "current_mode_update",
  agentThoughtChunk = "agent_thought_chunk",
  agentMessageChunk = "agent_message_chunk",
  agentMessageFinal = "agent_message_final",
}

function M.update_type(value)
  if type(value) ~= "table" then
    return nil
  end
  local update_type = value.sessionUpdate or value.type
  return update_types[update_type] or update_type
end

function M.session_id(value)
  if type(value) ~= "table" then
    return nil
  end
  local session = type(value.session) == "table" and value.session or {}
  return value.sessionId or value.session_id or session.id or session.sessionId or session.session_id or value.id
end

function M.agent_capabilities(value)
  local capabilities = aliased(value, "agentCapabilities", "agent_capabilities")
  return type(capabilities) == "table" and capabilities or {}
end

function M.has_load_session(capabilities)
  return aliased(capabilities, "loadSession", "load_session") == true
end

function M.session_capability(capabilities, name)
  local session_capabilities = aliased(capabilities, "sessionCapabilities", "session_capabilities")
  return type(session_capabilities) == "table" and session_capabilities[name] ~= nil
end

function M.prompt_capability(capabilities, name)
  local prompt_capabilities = aliased(capabilities, "promptCapabilities", "prompt_capabilities")
  return type(prompt_capabilities) == "table" and prompt_capabilities[name] == true
end

function M.available_commands(value)
  local commands = aliased(value, "availableCommands", "available_commands")
  return type(commands) == "table" and commands or {}
end

function M.config_options(value)
  local options = aliased(value, "configOptions", "config_options")
  return type(options) == "table" and options or nil
end

function M.mode_id(value)
  return aliased(value, "modeId", "mode_id")
end

function M.current_mode_id(value)
  return aliased(value, "currentModeId", "current_mode_id")
end

function M.current_value(value)
  return aliased(value, "currentValue", "current_value")
end

function M.available_modes(value)
  local modes = aliased(value, "availableModes", "available_modes")
  return type(modes) == "table" and modes or {}
end

function M.raw_output(value)
  return aliased(value, "rawOutput", "raw_output")
end

return M
