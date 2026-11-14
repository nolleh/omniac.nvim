local function new()
  local M = {}
  local activity_actions = require("omniac.ui.activity.actions")
  local activity_view = require("omniac.ui.activity")
  local chat_messages = require("omniac.ui.chat.messages")
  local chat_scheduler = require("omniac.ui.chat.scheduler")
  local chat_view = require("omniac.ui.chat.view")
  local input_attachments = require("omniac.ui.input.attachments")
  local input_editing = require("omniac.ui.input.editing")
  local input_history = require("omniac.ui.input.history")
  local input_render = require("omniac.ui.input.render")
  local input_suggestions = require("omniac.ui.input.suggestions")
  local layout = require("omniac.ui.layout")
  local lifecycle = require("omniac.ui.lifecycle")
  local mascot_motion = require("omniac.ui.mascot.motion")
  local mascot_render = require("omniac.ui.mascot.render")
  local notifications = require("omniac.ui.notifications")
  local runtime_factory = require("omniac.ui.runtime")
  local session = require("omniac.ui.session")
  local state_factory = require("omniac.ui.state")
  local status_view = require("omniac.ui.status")
  local text = require("omniac.ui.text")
  local tools = require("omniac.ui.tools")

  local ns = vim.api.nvim_create_namespace("omniac.ui")
  local augroup = vim.api.nvim_create_augroup("omniac.ui", { clear = false })
  local mascot_augroup = vim.api.nvim_create_augroup("omniac.mascot", { clear = true })
  local mascot_key_ns = vim.api.nvim_create_namespace("omniac.mascot.keys")

  local state = state_factory.new()

  local ACTIVITY_MAX_DISPLAY_LINES = 3
  local CARD_HEIGHT = 15 -- 14 content lines plus the card winbar
  local INPUT_PROMPT = "│ > "
  local INPUT_CONTINUATION = "│ "
  local function valid_buf(buf)
    return buf and vim.api.nvim_buf_is_valid(buf)
  end

  local function valid_win(win)
    return win and vim.api.nvim_win_is_valid(win)
  end

  local function target_width()
    return layout.target_width(state)
  end

  local function capture_user_width()
    layout.capture_width(state, valid_win)
  end

  local function agent_name(config)
    local cmd = ((config or state.config or {}).agent or {}).cmd or {}
    if type(cmd) == "table" then
      return cmd[1] or "agent"
    end
    return tostring(cmd ~= "" and cmd or "agent")
  end

  local fit = text.fit

  local function add_hl(buf, line, start_col, end_col, group)
    if valid_buf(buf) then
      vim.api.nvim_buf_add_highlight(buf, ns, group, line - 1, start_col, end_col)
    end
  end

  local render_chat

  local function request_chat_render(config, opts)
    chat_scheduler.request(state, config, opts, render_chat)
  end

  local split_lines = text.split_lines

  local render_activity
  local attachment_summary
  local resize_aux_windows
  local runtime

  local function header(lines, marks, size)
    mascot_render.header(state, lines, marks, size, agent_name)
  end

  local function pin_card_view()
    mascot_render.pin_view(state, valid_win)
  end

  local function render_card()
    mascot_render.card(state, {
      valid_buf = valid_buf,
      valid_win = valid_win,
      width = target_width,
      namespace = ns,
      agent_name = agent_name,
      add_hl = add_hl,
    })
  end

  local function render_mascot()
    mascot_render.refresh(state, render_card, render_chat)
  end

  render_chat = function(config, opts)
    if state.session_loading then
      opts = vim.tbl_extend("force", opts or {}, { skip_markdown = true })
    end
    chat_view.render(state, config, opts, runtime.chat_view)
  end

  local function restart_mascot_actions()
    mascot_motion.restart(state, runtime.mascot)
  end

  local function render_status()
    status_view.render({
      state = state,
      namespace = ns,
      valid_buf = valid_buf,
      valid_win = valid_win,
      width = target_width,
      fit = fit,
      add_hl = add_hl,
    })
  end

  render_activity = function()
    local height_changed = activity_view.render({
      state = state,
      namespace = ns,
      max_lines = ACTIVITY_MAX_DISPLAY_LINES,
      valid_buf = valid_buf,
      valid_win = valid_win,
      width = target_width,
      fit = fit,
      split_lines = split_lines,
      add_hl = add_hl,
    })
    if height_changed and resize_aux_windows then
      resize_aux_windows()
    end
  end

  local clear_input_history_navigation
  local attachment_ranges

  local function reset_input()
    input_render.reset(state, {
      valid_buf = valid_buf,
      valid_win = valid_win,
      width = target_width,
      namespace = ns,
      add_hl = add_hl,
      attachment_ranges = attachment_ranges,
      clear_history = clear_input_history_navigation,
      reset_leftcol = function(win)
        layout.reset_leftcol(win, valid_win)
      end,
    })
  end

  attachment_summary = function(attachments)
    return input_attachments.summary(attachments)
  end

  attachment_ranges = function(line)
    return input_attachments.ranges(state, line)
  end

  local function raw_input_lines()
    return input_render.read(state, valid_buf)
  end

  local function raw_input_text()
    return table.concat(raw_input_lines(), "\n")
  end

  local render_input
  local logical_cursor_from_display
  clear_input_history_navigation = function()
    input_history.clear(state)
  end

  local function remember_input_history(text)
    input_history.remember(state, text)
  end

  local function navigate_input_history(direction)
    return input_history.navigate(state, direction, {
      read = raw_input_text,
      render = render_input,
      valid_buf = valid_buf,
    })
  end

  local function input_text()
    return (raw_input_text():gsub("^%s+", ""):gsub("%s+$", ""))
  end

  local function prepared_input()
    return input_attachments.prepare(state, input_text())
  end

  local focus_input

  local function clear_input_attachments()
    input_attachments.clear(state)
    render_activity()
  end

  function M.attach_reference(reference, config)
    if
      type(reference) ~= "table"
      or reference.type ~= "reference"
      or (not reference.text and not reference.pathOnly)
    then
      return false
    end

    local lines = raw_input_lines()
    local cursor = valid_win(state.input_win) and vim.api.nvim_win_get_cursor(state.input_win) or { 2, #INPUT_PROMPT }
    lines, cursor = input_attachments.insert(state, reference, lines, logical_cursor_from_display(cursor))
    render_input(lines, cursor)
    vim.schedule(function()
      focus_input()
    end)
    return true
  end

  local function ensure_command_buffer()
    input_suggestions.ensure_buffer(state, valid_buf)
  end

  local function close_command_window()
    input_suggestions.close(state, { valid_win = valid_win, resize = resize_aux_windows })
  end

  function M.clear_conversation(config)
    chat_messages.clear(state, config, runtime.chat)
  end

  local update_command_window

  local function input_bottom_position()
    return layout.input_bottom_position(state, valid_win)
  end

  local function input_display_height(lines, _)
    return input_render.display_height(lines)
  end

  local function bottom_stack_height()
    local status_height = 1
    local input_height = input_display_height(raw_input_lines(), target_width())

    return (state.activity_height or 1) + input_height + status_height
  end

  local reset_leftcol

  render_input = function(lines, cursor, opts)
    opts = opts or {}
    input_render.render(state, lines, cursor, {
      valid_buf = valid_buf,
      valid_win = valid_win,
      width = target_width,
      namespace = ns,
      add_hl = add_hl,
      attachment_ranges = attachment_ranges,
      reset_leftcol = reset_leftcol,
      update_completion = update_command_window,
      skip_command_window = opts.skip_command_window,
    })
  end

  logical_cursor_from_display = function(cursor)
    return input_render.logical_cursor(state, cursor, raw_input_lines)
  end

  focus_input = function()
    input_editing.focus(state, runtime.input_editing)
  end

  local function focus_input_if_active()
    input_editing.focus_if_active(state, runtime.input_editing)
  end

  reset_leftcol = function(win)
    layout.reset_leftcol(win, valid_win)
  end

  update_command_window = function()
    input_suggestions.update(state, raw_input_text(), {
      valid_buf = valid_buf,
      valid_win = valid_win,
      width = target_width,
      position = input_bottom_position,
      configure_window = layout.configure_window,
      namespace = ns,
      fit = fit,
      add_hl = add_hl,
      resize = resize_aux_windows,
    })
  end

  resize_aux_windows = function()
    layout.resize_windows(state, {
      valid_win = valid_win,
      card_height = CARD_HEIGHT,
      bottom_stack_height = bottom_stack_height,
      input_height = function(target)
        return input_display_height(raw_input_lines(), target)
      end,
      pin_card_view = pin_card_view,
    })
  end

  local function relayout()
    lifecycle.relayout(state, runtime.lifecycle)
  end

  runtime = runtime_factory.new(state, {
    valid_buf = valid_buf,
    valid_win = valid_win,
    width = target_width,
    namespace = ns,
    header = header,
    agent_name = agent_name,
    add_hl = add_hl,
    mascot_visible = function()
      return mascot_render.visible(state, valid_buf, valid_win)
    end,
    render_mascot = render_mascot,
    mascot_augroup = mascot_augroup,
    mascot_key_namespace = mascot_key_ns,
    render_chat = render_chat,
    render_card = render_card,
    render_activity = render_activity,
    render_status = render_status,
    restart_mascot_actions = restart_mascot_actions,
    input_prompt = INPUT_PROMPT,
    input_continuation = INPUT_CONTINUATION,
    raw_input_lines = raw_input_lines,
    render_input = render_input,
    logical_cursor_from_display = logical_cursor_from_display,
    clear_input_history = clear_input_history_navigation,
    close_command_window = close_command_window,
    reset_input = reset_input,
    set_status = function(...)
      return M.set_status(...)
    end,
    request_chat_render = request_chat_render,
    focus_input_if_active = focus_input_if_active,
    set_activity = function(...)
      return M.set_activity(...)
    end,
    attachment_summary = attachment_summary,
    add_notice = function(...)
      return M.add_notice(...)
    end,
    update_notice = function(...)
      return M.update_notice(...)
    end,
    add_message = function(...)
      return M.add_message(...)
    end,
    focus_input = focus_input,
    augroup = augroup,
    raw_input_text = raw_input_text,
    input_text = input_text,
    prepared_input = prepared_input,
    remember_input_history = remember_input_history,
    navigate_input_history = navigate_input_history,
    clear_input_attachments = clear_input_attachments,
    close_ui = function(...)
      return M.close(...)
    end,
    toggle_tool_output = function()
      return M.toggle_tool_output(state.config)
    end,
    move_sidebar = function(direction)
      layout.move_sidebar(state, direction, valid_win, resize_aux_windows)
    end,
    relayout = relayout,
    clear_conversation = function(...)
      return M.clear_conversation(...)
    end,
    append_response_chunk = function(...)
      return M.append_response_chunk(...)
    end,
    set_tool_activity = function(...)
      return M.set_tool_activity(...)
    end,
    add_tool_result = function(...)
      return M.add_tool_result(...)
    end,
    set_available_commands = function(...)
      return M.set_available_commands(...)
    end,
    set_session_mode = function(...)
      return M.set_session_mode(...)
    end,
    set_session_model = function(...)
      return M.set_session_model(...)
    end,
    set_session_config = function(...)
      return M.set_session_config(...)
    end,
    set_session_usage = function(...)
      return M.set_session_usage(...)
    end,
    complete_response = function(...)
      return M.complete_response(...)
    end,
    resize_aux_windows = resize_aux_windows,
    capture_user_width = capture_user_width,
    ensure_command_buffer = ensure_command_buffer,
    card_height = CARD_HEIGHT,
    clear_failure_action = function(...)
      return M.clear_failure_action(...)
    end,
  })

  function M.resize(value)
    return lifecycle.resize(state, value, runtime.lifecycle)
  end

  function M.close()
    lifecycle.close(state, runtime.lifecycle)
  end

  function M.open(config, submit, queue_submit)
    return lifecycle.open(state, config, submit, queue_submit, runtime.lifecycle)
  end

  function M.set_status(status, config)
    activity_actions.set_status(state, status, config, runtime.activity)
  end

  function M.set_activity(text, config, opts)
    activity_actions.set_activity(state, text, runtime.activity, opts)
  end

  function M.show_failure_action(handler)
    activity_actions.show_failure(state, handler, runtime.activity)
  end

  function M.clear_failure_action()
    activity_actions.clear_failure(state, runtime.activity)
  end

  function M.flash_activity(text, config, duration_ms)
    activity_actions.flash(state, text, config, duration_ms, runtime.activity)
  end

  function M.set_change_review_handler(handler)
    activity_actions.set_change_review_handler(state, handler, runtime.activity)
  end

  function M.set_plan_toggle_handler(handler)
    state.plan_toggle_handler = handler
  end

  function M.set_cancel_handler(handler)
    state.cancel_handler = handler
  end

  function M.set_session_mode(mode)
    session.set_mode(state, mode, render_status)
  end

  function M.set_session_model(model)
    session.set_model(state, model, render_status)
  end

  function M.set_session_config(options)
    session.set_config(state, options, render_status)
  end

  function M.set_session_usage(usage)
    session.set_usage(state, usage, render_status)
  end

  function M.set_tool_activity(params, config)
    tools.set_activity(state, params, render_activity)
  end

  function M.toggle_tool_output(config)
    return tools.toggle_output(state, config, runtime.tool_output)
  end

  function M.add_tool_result(params, config)
    tools.add_result(state, params, config, runtime.tool_result)
  end

  function M.add_message(role, text, config, opts)
    chat_messages.add_message(state, role, text, config, opts, runtime.chat)
  end

  function M.add_notice(role, text, config)
    return chat_messages.add_notice(state, role, text, config, runtime.chat)
  end

  function M.update_notice(index, text, config, opts)
    chat_messages.update_notice(state, index, text, config, opts, runtime.chat)
  end

  function M.append_response_chunk(text, config)
    chat_messages.append_response_chunk(state, text, config, runtime.chat)
  end

  function M.complete_response(config, opts)
    chat_messages.complete_response(state, config, opts, runtime.chat)
  end

  function M.queue_prompt(text, config, attachments)
    return chat_messages.queue_prompt(state, text, config, attachments, runtime.chat)
  end

  function M.submit(text, config, attachments, message)
    chat_messages.submit(state, text, config, attachments, runtime.chat, message)
  end

  function M.restore_input(text, attachments)
    if raw_input_text() ~= "" or #state.input_attachments > 0 then
      return false
    end
    local restored = input_attachments.restore(state, text, attachments)
    local lines = vim.split(restored, "\n", { plain = true })
    render_input(lines, { line = #lines, col = #(lines[#lines] or "") })
    render_activity()
    focus_input()
    return true
  end

  function M.handle_notification(message, config)
    notifications.handle(state, message, config, runtime.notifications)
  end

  function M.set_available_commands(commands)
    session.set_available_commands(state, commands, update_command_window)
  end

  function M.is_open()
    return lifecycle.is_open(state, valid_win)
  end

  return M
end

return { new = new }
