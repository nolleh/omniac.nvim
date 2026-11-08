local app = require("omniac.ui.app").new()

local public_methods = {
  add_message = true,
  add_notice = true,
  add_tool_result = true,
  append_response_chunk = true,
  attach_reference = true,
  clear_conversation = true,
  clear_failure_action = true,
  close = true,
  complete_response = true,
  flash_activity = true,
  handle_notification = true,
  is_open = true,
  open = true,
  resize = true,
  restore_input = true,
  set_activity = true,
  set_available_commands = true,
  set_cancel_handler = true,
  set_change_review_handler = true,
  set_plan_toggle_handler = true,
  set_session_config = true,
  set_session_mode = true,
  set_session_model = true,
  set_session_usage = true,
  set_status = true,
  set_tool_activity = true,
  show_failure_action = true,
  submit = true,
  toggle_tool_output = true,
  update_notice = true,
}

return setmetatable({}, {
  __index = function(_, key)
    if public_methods[key] then
      return app[key]
    end
  end,
  __newindex = function(_, key, value)
    if public_methods[key] then
      app[key] = value
      return
    end
    error("Unknown omniac.ui field: " .. tostring(key))
  end,
})
