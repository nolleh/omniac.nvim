local M = {}

function M.new(state, deps)
  local runtime = { state = state }

  runtime.chat_view = {
    valid_buf = deps.valid_buf,
    valid_win = deps.valid_win,
    width = deps.width,
    namespace = deps.namespace,
    header = deps.header,
    agent_name = deps.agent_name,
    add_hl = deps.add_hl,
  }

  runtime.mascot = {
    valid_win = deps.valid_win,
    visible = deps.mascot_visible,
    render = deps.render_mascot,
    augroup = deps.mascot_augroup,
    key_namespace = deps.mascot_key_namespace,
  }

  runtime.activity = {
    valid_buf = deps.valid_buf,
    render_chat = deps.render_chat,
    render_card = deps.render_card,
    render_activity = deps.render_activity,
    render_status = deps.render_status,
    restart_mascot_actions = deps.restart_mascot_actions,
  }

  runtime.input_controller = {
    valid_buf = deps.valid_buf,
    valid_win = deps.valid_win,
    prompt = deps.input_prompt,
    continuation = deps.input_continuation,
    read = deps.raw_input_lines,
    render = deps.render_input,
    logical_cursor = deps.logical_cursor_from_display,
    clear_history = deps.clear_input_history,
    render_activity = deps.render_activity,
  }

  runtime.chat = {
    close_command_window = deps.close_command_window,
    reset_input = deps.reset_input,
    set_status = deps.set_status,
    request_render = deps.request_chat_render,
    render_activity = deps.render_activity,
    focus_input_if_active = deps.focus_input_if_active,
    set_activity = deps.set_activity,
    clear_input_history = deps.clear_input_history,
    attachment_summary = deps.attachment_summary,
    add_message = deps.add_message,
  }

  runtime.tool_output = {
    render_chat = deps.render_chat,
    focus_input = deps.focus_input,
  }

  runtime.tool_result = {
    request_chat_render = deps.request_chat_render,
    focus_input_if_active = deps.focus_input_if_active,
  }

  runtime.input_bindings = {
    augroup = deps.augroup,
    valid_buf = deps.valid_buf,
    valid_win = deps.valid_win,
    raw_text = deps.raw_input_text,
    input_text = deps.input_text,
    prepared_input = deps.prepared_input,
    remember_history = deps.remember_input_history,
    navigate_history = deps.navigate_input_history,
    reset = deps.reset_input,
    clear_attachments = deps.clear_input_attachments,
    close_suggestions = deps.close_command_window,
    focus = deps.focus_input,
    close_ui = deps.close_ui,
    set_activity = deps.set_activity,
    controller = runtime.input_controller,
  }

  runtime.bindings = {
    valid_win = deps.valid_win,
    focus_input = deps.focus_input,
    toggle_tool_output = deps.toggle_tool_output,
    move_sidebar = deps.move_sidebar,
  }

  runtime.events = {
    augroup = deps.augroup,
    valid_buf = deps.valid_buf,
    valid_win = deps.valid_win,
    relayout = deps.relayout,
    close = deps.close_ui,
  }

  runtime.notifications = {
    clear_conversation = deps.clear_conversation,
    set_status = deps.set_status,
    set_activity = deps.set_activity,
    add_message = deps.add_message,
    append_response_chunk = deps.append_response_chunk,
    set_tool_activity = deps.set_tool_activity,
    render_activity = deps.render_activity,
    add_tool_result = deps.add_tool_result,
    set_available_commands = deps.set_available_commands,
    set_session_mode = deps.set_session_mode,
    set_session_model = deps.set_session_model,
    set_session_config = deps.set_session_config,
    set_session_usage = deps.set_session_usage,
    complete_response = deps.complete_response,
  }

  return runtime
end

return M
