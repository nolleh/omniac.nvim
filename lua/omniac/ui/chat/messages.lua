local M = {}
local tools = require("omniac.ui.tools")
local render = require("omniac.ui.chat.render")
local markdown = require("omniac.ui.markdown")

local function transport_activity_text(value)
  value = tostring(value or ""):gsub("\r", "")
  value = value:gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then
    return nil
  end

  if value:match("^Reconnecting%.%.%.%s*%d+/%d+$") then
    return value
  end

  if value:match("^Warning:%s*Falling back from WebSockets to HTTPS transport%.") then
    return value
  end

  if value:match("^stream disconnected before completion:") then
    return value
  end

  return nil
end

function M.clear(state, config, handlers)
  state.messages = {}
  state.chat_render_cache = nil
  state.chat_dirty_from = nil
  state.streaming_message_index = nil
  state.tool_activity = nil
  state.cancel_requested = false
  state.suppress_current_turn = false
  state.active_turn_id = nil
  state.available_commands = {}
  state.input_attachments = {}
  state.transient_activity = nil
  state.change_summary = false
  handlers.close_command_window()
  handlers.reset_input()
  local resolved_config = config or state.config
  handlers.set_status("ready", resolved_config)
  handlers.request_render(resolved_config, { immediate = true, follow = false, reset_view = true })
end

function M.add_message(state, role, value, config, opts, handlers)
  opts = opts or {}
  if role == "Omniac" then
    tools.clear_completed(state, handlers.render_activity)
  end
  table.insert(state.messages, {
    role = role,
    text = value or "",
    stop_footer = opts.stop_footer,
  })
  if role ~= "Omniac" then
    state.streaming_message_index = nil
  end
  handlers.request_render(config, { immediate = true, follow = true })
  handlers.focus_input_if_active()
end

function M.add_notice(state, role, value, config, handlers)
  if state.streaming_message_index and state.messages[state.streaming_message_index] then
    state.messages[state.streaming_message_index].complete = true
    render.invalidate(state, state.streaming_message_index)
    state.streaming_message_index = nil
  end
  table.insert(state.messages, {
    role = role or "Notice",
    text = value or "",
  })
  local index = #state.messages
  handlers.request_render(config, { immediate = true, follow = true })
  handlers.focus_input_if_active()
  return index
end

function M.update_notice(state, index, value, config, opts, handlers)
  if type(index) ~= "number" or not state.messages[index] then
    return
  end
  state.messages[index].text = value or state.messages[index].text or ""
  render.invalidate(state, index)
  if opts and opts.permission_status then
    state.messages[index].permission_status = opts.permission_status
  end
  handlers.request_render(config, { immediate = true, follow = true })
  handlers.focus_input_if_active()
end

function M.append_response_chunk(state, value, config, handlers)
  if not value or value == "" then
    return
  end

  tools.clear_completed(state, handlers.render_activity)

  local activity = transport_activity_text(value)
  if activity then
    if state.streaming_message_index and state.messages[state.streaming_message_index] then
      state.messages[state.streaming_message_index].complete = true
      render.invalidate(state, state.streaming_message_index)
      state.streaming_message_index = nil
    end
    handlers.set_activity(activity, config)
    return
  end

  local index = state.streaming_message_index
  if not index or not state.messages[index] or state.messages[index].role ~= "Omniac" then
    table.insert(state.messages, {
      role = "Omniac",
      text = "",
      pending_chunks = {},
      complete = false,
    })
    index = #state.messages
    state.streaming_message_index = index
  end

  local message = state.messages[index]
  markdown.suspend(state.chat_buf)
  message.complete = false
  message.pending_chunks = message.pending_chunks or {}
  table.insert(message.pending_chunks, value)
  render.invalidate(state, index)
  handlers.request_render(config, { skip_markdown = true, follow = true })
end

function M.complete_response(state, config, opts, handlers)
  opts = opts or {}
  local index = state.streaming_message_index
  if index and state.messages[index] and state.messages[index].role == "Omniac" then
    state.messages[index].complete = true
    state.messages[index].stop_footer = opts.stop_footer
    render.invalidate(state, index)
    handlers.request_render(config, { immediate = true, follow = true })
  end
  state.streaming_message_index = nil
end

function M.submit(state, value, config, attachments, handlers)
  state.suppress_current_turn = false
  handlers.clear_input_history()
  local display = value or ""
  local positioned = {}
  local trailing = {}
  for _, attachment in ipairs(attachments or {}) do
    if type(attachment._position) == "number" and attachment._input_marker then
      table.insert(positioned, attachment)
    else
      table.insert(trailing, attachment)
    end
  end
  table.sort(positioned, function(left, right)
    if left._position == right._position then
      return (left._order or 0) < (right._order or 0)
    end
    return left._position < right._position
  end)
  for index = #positioned, 1, -1 do
    local attachment = positioned[index]
    local position = math.min(math.max(attachment._position, 0), #display)
    display = display:sub(1, position) .. attachment._input_marker .. display:sub(position + 1)
  end
  local summary = handlers.attachment_summary(trailing)
  if summary then
    display = display ~= "" and (display .. "\n[" .. summary .. "]") or ("[" .. summary .. "]")
  end
  handlers.add_message("You", display, config)
  handlers.set_status("working", config)
end

return M
