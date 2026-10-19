local M = {}
local activity_view = require("omniac.ui.activity")
local bindings = require("omniac.ui.bindings")
local buffers = require("omniac.ui.buffers")
local chat_render = require("omniac.ui.chat.render")
local chat_scheduler = require("omniac.ui.chat.scheduler")
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
local status_view = require("omniac.ui.status")
local text = require("omniac.ui.text")
local tools = require("omniac.ui.tools")

local ns = vim.api.nvim_create_namespace("omniac.ui")
local augroup = vim.api.nvim_create_augroup("omniac.ui", { clear = false })
local mascot_augroup = vim.api.nvim_create_augroup("omniac.mascot", { clear = true })
local mascot_key_ns = vim.api.nvim_create_namespace("omniac.mascot.keys")

local state = {
  chat_buf = nil,
  chat_win = nil,
  card_buf = nil,
  card_win = nil,
  card_pinned = false,
  activity_buf = nil,
  activity_win = nil,
  input_buf = nil,
  input_win = nil,
  command_buf = nil,
  command_win = nil,
  status_buf = nil,
  status_win = nil,
  status = "idle",
  activity_timer = nil,
  tool_activity_timer = nil,
  activity_frame = 1,
  activity_height = 1,
  tool_activity = nil,
  thought_activity = nil,
  messages = {},
  input_history = {},
  input_history_index = nil,
  input_history_draft = nil,
  input_history_navigating = false,
  input_history_render_pending = false,
  input_history_render_generation = 0,
  input_history_pending_text = nil,
  input_history_pending_cursor = nil,
  streaming_message_index = nil,
  chat_render_pending = false,
  chat_render_generation = 0,
  chat_render_config = nil,
  chat_render_opts = nil,
  config = nil,
  submit = nil,
  queue_submit = nil,
  cancel_handler = nil,
  cancel_requested = false,
  suppress_current_turn = false,
  rendering_input = false,
  input_chunks = nil,
  input_attachments = {},
  next_attachment_id = 0,
  transient_activity = nil,
  failure_action = nil,
  activity_generation = 0,
  change_summary = false,
  change_shortcut_buffers = {},
  available_commands = {},
  session_mode = nil,
  session_model = nil,
  session_config = nil,
  session_usage = nil,
  plan_toggle_handler = nil,
  relayout_pending = false,
  close_pending = false,
  user_width = nil,
  active_turn_id = nil,
  mascot_gaze = "center",
  mascot_target = "center",
  mascot_gaze_pending = false,
  mascot_generation = 0,
  mascot_first_line = nil,
  mascot_last_line = nil,
  mascot_in_omniac = false,
  mascot_reacting = false,
  mascot_eye_height = 2,
  mascot_reaction_id = 0,
  mascot_antenna_offset = 0,
  mascot_arm_frame = 0,
  mascot_action_generation = 0,
  mascot_idle_direction = 1,
  mascot_x = 0,
  mascot_hop = 0,
  mascot_walk_frame = 0,
  mascot_vertical_gaze = 0,
  mascot_walk_direction = 1,
  mascot_interaction_generation = 0,
  mascot_interacting = false,
  mascot_card_cursor = nil,
  mascot_pet_count = 0,
  mascot_last_pet_at = 0,
}

local ACTIVITY_MAX_DISPLAY_LINES = 3
local CARD_HEIGHT = 15 -- 14 content lines plus the card winbar
local INPUT_PROMPT = "│ > "
local INPUT_CONTINUATION = "│ "
local CHAT_MARKDOWN_RENDER_CONFIG = {
  pipe_table = {
    border_virtual = true,
    style = "normal",
  },
}
local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function sync_change_shortcuts()
  for _, buf in ipairs(state.change_shortcut_buffers) do
    if valid_buf(buf) then
      pcall(vim.keymap.del, "n", "t", { buffer = buf })
      pcall(vim.keymap.del, "n", "s", { buffer = buf })
    end
  end
  state.change_shortcut_buffers = {}

  if not state.change_summary or not state.change_review_handler then
    return
  end

  for _, name in ipairs({ "chat_buf", "activity_buf", "status_buf", "card_buf" }) do
    local buf = state[name]
    if valid_buf(buf) and (name ~= "card_buf" or state.card_pinned) then
      for key, scope in pairs({ t = "turn", s = "session" }) do
        vim.keymap.set("n", key, function()
          state.change_review_handler(scope)
        end, {
          buffer = buf,
          nowait = true,
          desc = "Review Omniac " .. scope .. " changes",
        })
      end
      table.insert(state.change_shortcut_buffers, buf)
    end
  end
end

local function sync_failure_shortcuts()
  for _, name in ipairs({ "chat_buf", "activity_buf", "status_buf", "card_buf", "input_buf" }) do
    local buf = state[name]
    if valid_buf(buf) then
      for key, action in pairs({ r = "resend", e = "restore", d = "dismiss" }) do
        pcall(vim.keymap.del, "n", key, { buffer = buf })
        if state.failure_action then
          vim.keymap.set("n", key, function()
            local handler = state.failure_action
            M.clear_failure_action()
            handler(action)
          end, { buffer = buf, nowait = true, desc = "Omniac failed prompt: " .. action })
        end
      end
    end
  end
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

local function start_chat_treesitter()
  if not valid_buf(state.chat_buf) or not (vim.treesitter and vim.treesitter.start) then
    return
  end

  pcall(vim.treesitter.start, state.chat_buf, "markdown")
end

local function render_chat_markdown()
  if not valid_buf(state.chat_buf) then
    return
  end

  local ok, renderer = pcall(require, "render-markdown")
  if not ok or type(renderer) ~= "table" then
    return
  end

  if renderer.initialized == false and type(renderer.setup) == "function" then
    pcall(
      renderer.setup,
      vim.tbl_deep_extend("force", {
        file_types = { "markdown" },
      }, CHAT_MARKDOWN_RENDER_CONFIG)
    )
  end

  if type(renderer.render) == "function" then
    local ok_state, renderer_state = pcall(require, "render-markdown.state")
    if ok_state and type(renderer_state) == "table" and type(renderer_state.cache) == "table" then
      renderer_state.cache[state.chat_buf] = nil
    end
    pcall(renderer.render, {
      buf = state.chat_buf,
      win = state.chat_win,
      event = "OmniacRender",
      config = CHAT_MARKDOWN_RENDER_CONFIG,
    })
  elseif type(renderer.buf_enable) == "function" then
    pcall(renderer.buf_enable)
  end
end

local function request_chat_render(config, opts)
  chat_scheduler.request(state, config, opts, render_chat)
end

local function clear_render_markdown_marks()
  if not valid_buf(state.chat_buf) then
    return
  end

  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if type(name) == "string" and name:match("render.markdown") then
      pcall(vim.api.nvim_buf_clear_namespace, state.chat_buf, id, 0, -1)
    end
  end
end

local split_lines = text.split_lines

local function transport_activity_text(text)
  local value = tostring(text or ""):gsub("\r", "")
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

local render_activity
local attachment_summary
local resize_aux_windows

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
  opts = opts or {}
  state.config = config or state.config
  if not valid_buf(state.chat_buf) then
    return
  end

  local previous_view
  local should_follow = false
  if valid_win(state.chat_win) then
    local cursor = vim.api.nvim_win_get_cursor(state.chat_win)
    local is_active = vim.api.nvim_get_current_win() == state.chat_win
    local mode = is_active and vim.fn.mode(1) or ""
    previous_view = vim.api.nvim_win_call(state.chat_win, vim.fn.winsaveview)
    should_follow = opts.follow == true
      and (is_active or vim.api.nvim_get_current_win() == state.input_win)
      and mode:match("^[vV\22]") == nil
      and cursor[1] >= vim.api.nvim_buf_line_count(state.chat_buf)
  end

  local win_width = valid_win(state.chat_win) and vim.api.nvim_win_get_width(state.chat_win) or target_width()
  local content = chat_render.build({
    state = state,
    width = win_width,
    header = header,
    agent_name = agent_name,
  })
  local lines = content.lines

  vim.bo[state.chat_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.chat_buf, ns, 0, -1)
  if not opts.skip_markdown then
    clear_render_markdown_marks()
  end
  vim.api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, lines)
  vim.bo[state.chat_buf].modifiable = false
  vim.bo[state.chat_buf].modified = false
  if not opts.skip_markdown then
    start_chat_treesitter()
  end

  for _, mark in ipairs(content.marks) do
    add_hl(state.chat_buf, mark.line, mark.from, mark.to, mark.group)
  end
  for _, mark in ipairs(content.permission_marks) do
    vim.api.nvim_buf_set_extmark(state.chat_buf, ns, mark.line - 1, 0, {
      virt_text = { { mark.label, mark.group }, { "  ", "Normal" } },
      virt_text_pos = "right_align",
    })
  end

  if not opts.skip_markdown then
    render_chat_markdown()
  end

  if opts.reset_view and valid_win(state.chat_win) then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { 1, 0 })
    pcall(vim.api.nvim_win_call, state.chat_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
  elseif should_follow and valid_win(state.chat_win) and #lines > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { #lines, 0 })
  elseif previous_view and valid_win(state.chat_win) then
    local line_count = math.max(#lines, 1)
    previous_view.lnum = math.min(previous_view.lnum, line_count)
    previous_view.topline = math.min(previous_view.topline, line_count)
    pcall(vim.api.nvim_win_call, state.chat_win, function()
      vim.fn.winrestview(previous_view)
    end)
  end
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

local function stop_activity_timer()
  if state.activity_timer then
    state.activity_timer:stop()
    state.activity_timer:close()
    state.activity_timer = nil
  end
end

local function sync_activity_timer()
  if state.status ~= "working" then
    stop_activity_timer()
    state.activity_frame = 1
    render_activity()
    return
  end

  if state.activity_timer then
    return
  end

  local uv = vim.uv or vim.loop
  state.activity_timer = uv.new_timer()
  state.activity_timer:start(
    0,
    180,
    vim.schedule_wrap(function()
      state.activity_frame = (state.activity_frame % 4) + 1
      render_activity()
    end)
  )
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
  state.messages = {}
  state.streaming_message_index = nil
  state.tool_activity = nil
  state.cancel_requested = false
  state.suppress_current_turn = false
  state.active_turn_id = nil
  state.available_commands = {}
  state.input_attachments = {}
  state.transient_activity = nil
  state.change_summary = false
  close_command_window()
  reset_input()
  M.set_status("ready", config or state.config)
  request_chat_render(config or state.config, { immediate = true, follow = false, reset_view = true })
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
  stop_activity_timer()
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
  sync_change_shortcuts()
  reset_input()
  render_status()
  sync_activity_timer()
  focus_input()
  mascot_controller.start(state, mascot_controller_opts())
  return state
end

function M.set_status(status, config)
  state.activity_generation = state.activity_generation + 1
  local previous_status = state.status
  state.status = status or "idle"
  if state.status ~= "working" then
    state.tool_activity = nil
    state.thought_activity = nil
    state.cancel_requested = false
    tools.stop_timer(state)
  end
  if state.status == "working" or state.status ~= "connecting" then
    state.transient_activity = nil
    state.change_summary = false
  end
  sync_change_shortcuts()
  render_chat(config)
  if state.card_pinned then
    render_card()
  end
  render_activity()
  render_status()
  sync_activity_timer()
  if state.status ~= previous_status then
    restart_mascot_actions()
  end
end

function M.set_activity(text, config, opts)
  state.activity_generation = state.activity_generation + 1
  state.transient_activity = text and text ~= "" and text or nil
  state.change_summary = state.transient_activity ~= nil and opts ~= nil and opts.change_summary == true
  sync_change_shortcuts()
  render_activity()
  render_status()
  sync_activity_timer()
end

function M.show_failure_action(handler)
  state.failure_action = handler
  sync_failure_shortcuts()
  if vim.fn.mode():match("^[iR]") then
    vim.cmd("stopinsert")
  end
  render_activity()
end

function M.clear_failure_action()
  state.failure_action = nil
  sync_failure_shortcuts()
  render_activity()
end

function M.flash_activity(text, config, duration_ms)
  local previous = state.transient_activity
  local previous_change_summary = state.change_summary
  M.set_activity(text, config)
  local generation = state.activity_generation
  vim.defer_fn(function()
    if state.activity_generation == generation and valid_buf(state.activity_buf) then
      M.set_activity(previous, config, { change_summary = previous_change_summary })
    end
  end, duration_ms or 1000)
end

function M.set_change_review_handler(handler)
  state.change_review_handler = handler
  sync_change_shortcuts()
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
  opts = opts or {}
  if role == "Omniac" then
    tools.clear_completed(state, render_activity)
  end
  table.insert(state.messages, {
    role = role,
    text = text or "",
    stop_footer = opts.stop_footer,
  })
  if role ~= "Omniac" then
    state.streaming_message_index = nil
  end
  request_chat_render(config, { immediate = true, follow = true })
  focus_input_if_active()
end

function M.add_notice(role, text, config)
  if state.streaming_message_index and state.messages[state.streaming_message_index] then
    state.messages[state.streaming_message_index].complete = true
    state.streaming_message_index = nil
  end
  table.insert(state.messages, {
    role = role or "Notice",
    text = text or "",
  })
  local index = #state.messages
  request_chat_render(config, { immediate = true, follow = true })
  focus_input_if_active()
  return index
end

function M.update_notice(index, text, config, opts)
  if type(index) ~= "number" or not state.messages[index] then
    return
  end
  state.messages[index].text = text or state.messages[index].text or ""
  if opts and opts.permission_status then
    state.messages[index].permission_status = opts.permission_status
  end
  request_chat_render(config, { immediate = true, follow = true })
  focus_input_if_active()
end

function M.append_response_chunk(text, config)
  if not text or text == "" then
    return
  end

  tools.clear_completed(state, render_activity)

  local activity = transport_activity_text(text)
  if activity then
    if state.streaming_message_index and state.messages[state.streaming_message_index] then
      state.messages[state.streaming_message_index].complete = true
      state.streaming_message_index = nil
    end
    M.set_activity(activity, config)
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
  message.complete = false
  message.pending_chunks = message.pending_chunks or {}
  table.insert(message.pending_chunks, text)
  request_chat_render(config, { skip_markdown = true, follow = true })
end

function M.complete_response(config, opts)
  opts = opts or {}
  local index = state.streaming_message_index
  if index and state.messages[index] and state.messages[index].role == "Omniac" then
    state.messages[index].complete = true
    state.messages[index].stop_footer = opts.stop_footer
    request_chat_render(config, { immediate = true, follow = true })
  end
  state.streaming_message_index = nil
end

function M.submit(text, config, attachments)
  state.suppress_current_turn = false
  clear_input_history_navigation()
  local display = text or ""
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
  local summary = attachment_summary(trailing)
  if summary then
    display = display ~= "" and (display .. "\n[" .. summary .. "]") or ("[" .. summary .. "]")
  end
  M.add_message("You", display, config)
  M.set_status("working", config)
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
