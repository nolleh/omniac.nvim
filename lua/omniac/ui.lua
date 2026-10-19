local M = {}
local activity_controller = require("omniac.ui.activity.controller")
local activity_view = require("omniac.ui.activity")
local bindings = require("omniac.ui.bindings")
local buffers = require("omniac.ui.buffers")
local chat_controller = require("omniac.ui.chat.controller")
local chat_scheduler = require("omniac.ui.chat.scheduler")
local chat_view = require("omniac.ui.chat.view")
local events = require("omniac.ui.events")
local highlights = require("omniac.ui.highlights")
local input_attachments = require("omniac.ui.input.attachments")
local input_bindings = require("omniac.ui.input.bindings")
local input_controller = require("omniac.ui.input.controller")
local input_history = require("omniac.ui.input.history")
local input_render = require("omniac.ui.input.render")
local input_suggestions = require("omniac.ui.input.suggestions")
local layout = require("omniac.ui.layout")
local mascot_controller = require("omniac.ui.mascot.controller")
local mascot_render = require("omniac.ui.mascot.render")
local notifications = require("omniac.ui.notifications")
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
local setup_highlights = highlights.setup

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
local chat_controller_opts

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
  chat_view.render(state, config, opts, {
    valid_buf = valid_buf,
    valid_win = valid_win,
    width = target_width,
    namespace = ns,
    header = header,
    agent_name = agent_name,
    add_hl = add_hl,
  })
end

local function mascot_controller_opts()
  return {
    valid_win = valid_win,
    visible = function()
      return mascot_render.visible(state, valid_buf, valid_win)
    end,
    render = render_mascot,
    augroup = mascot_augroup,
    key_namespace = mascot_key_ns,
  }
end

local function restart_mascot_actions()
  mascot_controller.restart(state, mascot_controller_opts())
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

local function activity_controller_opts(opts)
  opts = opts or {}
  return {
    valid_buf = valid_buf,
    render_chat = render_chat,
    render_card = render_card,
    render_activity = render_activity,
    render_status = render_status,
    restart_mascot_actions = restart_mascot_actions,
    change_summary = opts.change_summary == true,
  }
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
  if type(reference) ~= "table" or reference.type ~= "reference" or (not reference.text and not reference.pathOnly) then
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
  chat_controller.clear(state, config, chat_controller_opts())
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

local function input_controller_opts()
  return {
    valid_buf = valid_buf,
    valid_win = valid_win,
    prompt = INPUT_PROMPT,
    continuation = INPUT_CONTINUATION,
    read = raw_input_lines,
    render = render_input,
    logical_cursor = logical_cursor_from_display,
    clear_history = clear_input_history_navigation,
    render_activity = render_activity,
  }
end

focus_input = function()
  input_controller.focus(state, input_controller_opts())
end

local function focus_input_if_active()
  input_controller.focus_if_active(state, input_controller_opts())
end

chat_controller_opts = function()
  return {
    close_command_window = close_command_window,
    reset_input = reset_input,
    set_status = M.set_status,
    request_render = request_chat_render,
    render_activity = render_activity,
    focus_input_if_active = focus_input_if_active,
    set_activity = M.set_activity,
    clear_input_history = clear_input_history_navigation,
    attachment_summary = attachment_summary,
    add_message = M.add_message,
  }
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
  if
    not (
      valid_win(state.card_win)
      or valid_win(state.chat_win)
      or valid_win(state.input_win)
      or valid_win(state.activity_win)
      or valid_win(state.status_win)
    )
  then
    return
  end

  if resize_aux_windows then
    resize_aux_windows()
  end
  render_chat(state.config)
  render_card()
  render_activity()
  render_status()
  if valid_buf(state.input_buf) then
    render_input(raw_input_lines(), nil, { skip_command_window = true })
  end
end

function M.resize(value)
  local target_width = tonumber(value)
  if not target_width then
    return false
  end

  target_width = math.floor(math.min(math.max(target_width, 42), math.max(42, vim.o.columns - 20)))
  state.user_width = target_width
  for _, win in ipairs({ state.chat_win, state.activity_win, state.input_win, state.status_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_set_width, win, target_width)
    end
  end
  if valid_win(state.card_win) then
    pcall(vim.api.nvim_win_set_width, state.card_win, target_width)
  end
  if valid_win(state.command_win) then
    pcall(vim.api.nvim_win_set_width, state.command_win, target_width)
    pcall(vim.api.nvim_win_set_config, state.command_win, { width = target_width })
  end
  relayout()
  return true
end

function M.close()
  state.close_pending = false
  local failure_action = state.failure_action
  M.clear_failure_action()
  if failure_action then
    failure_action("dismiss")
  end
  activity_controller.stop_timer(state)
  tools.stop_timer(state)
  mascot_controller.stop(state, mascot_controller_opts())
  chat_scheduler.cancel(state)
  events.clear(augroup)
  layout.close_windows(state, valid_win)
end

function M.open(config, submit, queue_submit)
  setup_highlights()
  state.config = config or state.config
  state.submit = submit or state.submit
  state.queue_submit = queue_submit or state.queue_submit

  if
    valid_win(state.chat_win)
    and valid_win(state.activity_win)
    and valid_win(state.input_win)
    and valid_win(state.status_win)
    and (not state.card_pinned or valid_win(state.card_win))
  then
    resize_aux_windows()
    capture_user_width()
    focus_input()
    return state
  end

  state.card_pinned = ((state.config or {}).ui or {}).welcome_card ~= "welcome_only" and vim.o.lines >= 32
  buffers.ensure(state, valid_buf)

  if not valid_buf(state.command_buf) then
    ensure_command_buffer()
  end

  layout.open_windows(state, { card_height = CARD_HEIGHT })
  resize_aux_windows()
  capture_user_width()

  input_bindings.setup(state, {
    augroup = augroup,
    valid_buf = valid_buf,
    valid_win = valid_win,
    raw_text = raw_input_text,
    input_text = input_text,
    prepared_input = prepared_input,
    remember_history = remember_input_history,
    navigate_history = navigate_input_history,
    reset = reset_input,
    clear_attachments = clear_input_attachments,
    close_suggestions = close_command_window,
    focus = focus_input,
    close_ui = M.close,
    set_activity = M.set_activity,
    controller = input_controller_opts(),
  })

  bindings.setup(state, {
    valid_win = valid_win,
    focus_input = focus_input,
    toggle_tool_output = function()
      M.toggle_tool_output(state.config)
    end,
    move_sidebar = function(direction)
      layout.move_sidebar(state, direction, valid_win, resize_aux_windows)
    end,
  })

  events.setup(state, {
    augroup = augroup,
    valid_buf = valid_buf,
    valid_win = valid_win,
    relayout = relayout,
    close = M.close,
  })
  if resize_aux_windows then
    resize_aux_windows()
  end
  render_chat(state.config)
  render_card()
  render_activity()
  activity_controller.sync_change_shortcuts(state, activity_controller_opts())
  reset_input()
  render_status()
  activity_controller.sync_timer(state, render_activity)
  focus_input()
  mascot_controller.start(state, mascot_controller_opts())
  return state
end

function M.set_status(status, config)
  activity_controller.set_status(state, status, config, activity_controller_opts())
end

function M.set_activity(text, config, opts)
  activity_controller.set_activity(state, text, activity_controller_opts(opts))
end

function M.show_failure_action(handler)
  activity_controller.show_failure(state, handler, activity_controller_opts())
end

function M.clear_failure_action()
  activity_controller.clear_failure(state, activity_controller_opts())
end

function M.flash_activity(text, config, duration_ms)
  activity_controller.flash(state, text, config, duration_ms, activity_controller_opts())
end

function M.set_change_review_handler(handler)
  activity_controller.set_change_review_handler(state, handler, activity_controller_opts())
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
  return tools.toggle_output(state, config, {
    render_chat = render_chat,
    focus_input = focus_input,
  })
end

function M.add_tool_result(params, config)
  tools.add_result(state, params, config, {
    request_chat_render = request_chat_render,
    focus_input_if_active = focus_input_if_active,
  })
end

function M.add_message(role, text, config, opts)
  chat_controller.add_message(state, role, text, config, opts, chat_controller_opts())
end

function M.add_notice(role, text, config)
  return chat_controller.add_notice(state, role, text, config, chat_controller_opts())
end

function M.update_notice(index, text, config, opts)
  chat_controller.update_notice(state, index, text, config, opts, chat_controller_opts())
end

function M.append_response_chunk(text, config)
  chat_controller.append_response_chunk(state, text, config, chat_controller_opts())
end

function M.complete_response(config, opts)
  chat_controller.complete_response(state, config, opts, chat_controller_opts())
end

function M.submit(text, config, attachments)
  chat_controller.submit(state, text, config, attachments, chat_controller_opts())
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
  notifications.handle(state, message, config, {
    clear_conversation = M.clear_conversation,
    set_status = M.set_status,
    set_activity = M.set_activity,
    add_message = M.add_message,
    append_response_chunk = M.append_response_chunk,
    set_tool_activity = M.set_tool_activity,
    render_activity = render_activity,
    add_tool_result = M.add_tool_result,
    set_available_commands = M.set_available_commands,
    set_session_mode = M.set_session_mode,
    set_session_model = M.set_session_model,
    set_session_config = M.set_session_config,
    set_session_usage = M.set_session_usage,
    complete_response = M.complete_response,
  })
end

function M.set_available_commands(commands)
  session.set_available_commands(state, commands, update_command_window)
end

function M.is_open()
  return valid_win(state.chat_win)
    and valid_win(state.activity_win)
    and valid_win(state.input_win)
    and valid_win(state.status_win)
    and (not state.card_pinned or valid_win(state.card_win))
end

function M.statusline()
  local text = string.format(" %s | %s | %s ", "Omniac", state.status, agent_name(state.config))
  return "%#OmniacStatusMode#" .. text .. "%#OmniacStatus#%="
end

return M
