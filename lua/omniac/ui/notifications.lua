local M = {}
local normalize = require("omniac.acp.normalize")

local function stop_reason_activity(reason, config)
  if reason == "cancelled" then
    return "Turn cancelled."
  end
  if reason == "interrupted" then
    return "Turn interrupted."
  end
  if config and config.debug and reason and reason ~= "" and reason ~= "end_turn" then
    return "Stopped: " .. reason
  end
  return nil
end

local function stop_reason_footer(reason)
  if reason == "max_tokens" or reason == "length" or reason == "token_limit" then
    return "Stopped: token limit"
  end
  return nil
end

local function belongs_to_inactive_turn(state, method, turn_id)
  if not turn_id or not state.active_turn_id or turn_id == state.active_turn_id then
    return false
  end

  return method == "omniac/response"
    or method == "omniac/response_chunk"
    or method == "omniac/response_completed"
    or method == "omniac/thought_activity"
    or method == "omniac/prompt_cancelled"
end

local function suppressed_for_current_turn(state, method)
  if not state.suppress_current_turn then
    return false
  end

  return method == "omniac/response"
    or method == "omniac/response_chunk"
    or method == "omniac/tool_activity"
    or method == "omniac/thought_activity"
    or method == "omniac/tool_result"
end

function M.handle(state, message, config, handlers)
  local method = message and message.method
  local params = message and message.params or {}
  local turn_id = normalize.turn_id(params)

  if belongs_to_inactive_turn(state, method, turn_id) then
    return
  end

  if method == "omniac/session_started" then
    if params.clearChat then
      handlers.clear_conversation(config)
    end
    handlers.set_status("ready", config)
    return
  end

  if method == "omniac/prompt_started" then
    state.streaming_message_index = nil
    state.tool_activity = nil
    state.thought_activity = nil
    state.cancel_requested = false
    state.suppress_current_turn = false
    state.active_turn_id = turn_id
    handlers.set_status("working", config)
    return
  end

  if method == "omniac/prompt_cancelled" then
    state.cancel_requested = false
    state.active_turn_id = turn_id or state.active_turn_id
    handlers.set_status("ready", config)
    handlers.set_activity("Cancelled current turn.", config)
    return
  end

  if method == "omniac/prompt_cancel_failed" then
    state.cancel_requested = false
    state.suppress_current_turn = false
    handlers.set_activity(params.message or "Cancel failed.", config)
    return
  end

  if suppressed_for_current_turn(state, method) then
    return
  end

  if method == "omniac/response" then
    local reason = normalize.stop_reason(params)
    handlers.add_message("Omniac", params.text or "", config, {
      stop_footer = stop_reason_footer(reason),
    })
    state.streaming_message_index = nil
    handlers.set_status("ready", config)
    local activity = stop_reason_activity(reason, config)
    if activity then
      handlers.set_activity(activity, config)
    end
    return
  end

  if method == "omniac/response_chunk" then
    handlers.append_response_chunk(params.text or "", config)
    return
  end

  if method == "omniac/tool_activity" then
    handlers.set_tool_activity(params, config)
    return
  end

  if method == "omniac/thought_activity" then
    if state.status == "working" and type(params.text) == "string" and params.text ~= "" then
      state.thought_activity = params.text
      handlers.render_activity()
    end
    return
  end

  if method == "omniac/tool_result" then
    handlers.add_tool_result(params, config)
    return
  end

  if method == "omniac/available_commands_update" then
    handlers.set_available_commands(normalize.available_commands(params))
    return
  end

  if method == "omniac/session_mode_update" then
    handlers.set_session_mode(params)
    return
  end

  if method == "omniac/session_model_update" then
    handlers.set_session_model(params)
    return
  end

  if method == "omniac/session_config_update" then
    handlers.set_session_config(normalize.config_options(params))
    return
  end

  if method == "omniac/usage_update" then
    handlers.set_session_usage(params)
    return
  end

  if method == "omniac/response_completed" then
    local reason = normalize.stop_reason(params)
    local suppress_stop_ui = state.suppress_current_turn
    handlers.complete_response(config, {
      stop_footer = suppress_stop_ui and nil or stop_reason_footer(reason),
    })
    handlers.set_status("ready", config)
    if not suppress_stop_ui then
      local activity = stop_reason_activity(reason, config)
      if activity then
        handlers.set_activity(activity, config)
      end
    end
    state.active_turn_id = turn_id or state.active_turn_id
    return
  end

  if method == "omniac/error" then
    handlers.add_message("Error", vim.inspect(params), config)
    handlers.set_status("error", config)
  end
end

return M
