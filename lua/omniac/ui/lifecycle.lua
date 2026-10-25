local M = {}
local activity_actions = require("omniac.ui.activity.actions")
local bindings = require("omniac.ui.bindings")
local buffers = require("omniac.ui.buffers")
local chat_scheduler = require("omniac.ui.chat.scheduler")
local events = require("omniac.ui.events")
local highlights = require("omniac.ui.highlights")
local input_bindings = require("omniac.ui.input.bindings")
local layout = require("omniac.ui.layout")
local mascot_motion = require("omniac.ui.mascot.motion")
local tools = require("omniac.ui.tools")

function M.relayout(state, handlers)
  if
    not (
      handlers.valid_win(state.card_win)
      or handlers.valid_win(state.chat_win)
      or handlers.valid_win(state.input_win)
      or handlers.valid_win(state.activity_win)
      or handlers.valid_win(state.status_win)
    )
  then
    return
  end

  handlers.resize_aux_windows()
  handlers.render_chat(state.config)
  handlers.render_card()
  handlers.render_activity()
  handlers.render_status()
  if handlers.valid_buf(state.input_buf) then
    handlers.render_input(handlers.raw_input_lines(), nil, { skip_command_window = true })
  end
end

function M.resize(state, value, handlers)
  local target_width = tonumber(value)
  if not target_width then
    return false
  end

  target_width = math.floor(math.min(math.max(target_width, 42), math.max(42, vim.o.columns - 20)))
  state.user_width = target_width
  for _, win in ipairs({ state.chat_win, state.activity_win, state.input_win, state.status_win }) do
    if handlers.valid_win(win) then
      pcall(vim.api.nvim_win_set_width, win, target_width)
    end
  end
  if handlers.valid_win(state.card_win) then
    pcall(vim.api.nvim_win_set_width, state.card_win, target_width)
  end
  if handlers.valid_win(state.command_win) then
    pcall(vim.api.nvim_win_set_width, state.command_win, target_width)
    pcall(vim.api.nvim_win_set_config, state.command_win, { width = target_width })
  end
  M.relayout(state, handlers)
  return true
end

function M.close(state, handlers)
  state.close_pending = false
  local failure_action = state.failure_action
  handlers.clear_failure_action()
  if failure_action then
    failure_action("dismiss")
  end
  activity_actions.stop_timer(state)
  tools.stop_timer(state)
  mascot_motion.stop(state, handlers.mascot)
  chat_scheduler.cancel(state)
  events.clear(handlers.augroup)
  layout.close_windows(state, handlers.valid_win)
end

function M.open(state, config, submit, queue_submit, handlers)
  highlights.setup()
  state.config = config or state.config
  state.submit = submit or state.submit
  state.queue_submit = queue_submit or state.queue_submit

  if M.is_open(state, handlers.valid_win) then
    handlers.resize_aux_windows()
    handlers.capture_user_width()
    handlers.focus_input()
    return state
  end

  state.card_pinned = ((state.config or {}).ui or {}).welcome_card ~= "welcome_only" and vim.o.lines >= 32
  buffers.ensure(state, handlers.valid_buf)

  if not handlers.valid_buf(state.command_buf) then
    handlers.ensure_command_buffer()
  end

  layout.open_windows(state, { card_height = handlers.card_height })
  handlers.resize_aux_windows()
  handlers.capture_user_width()

  input_bindings.setup(state, handlers.input_bindings)
  bindings.setup(state, handlers.bindings)
  events.setup(state, handlers.events)
  handlers.resize_aux_windows()
  handlers.render_chat(state.config)
  handlers.render_card()
  handlers.render_activity()
  activity_actions.sync_change_shortcuts(state, handlers.activity)
  handlers.reset_input()
  handlers.render_status()
  activity_actions.sync_timer(state, handlers.render_activity)
  handlers.focus_input()
  mascot_motion.start(state, handlers.mascot)
  return state
end

function M.is_open(state, valid_win)
  return valid_win(state.chat_win)
    and valid_win(state.activity_win)
    and valid_win(state.input_win)
    and valid_win(state.status_win)
    and (not state.card_pinned or valid_win(state.card_win))
end

return M
