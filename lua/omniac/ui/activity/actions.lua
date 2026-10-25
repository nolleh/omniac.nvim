local M = {}
local tools = require("omniac.ui.tools")

function M.sync_change_shortcuts(state, opts)
  for _, buf in ipairs(state.change_shortcut_buffers) do
    if opts.valid_buf(buf) then
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
    if opts.valid_buf(buf) and (name ~= "card_buf" or state.card_pinned) then
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

local function sync_failure_shortcuts(state, opts)
  for _, name in ipairs({ "chat_buf", "activity_buf", "status_buf", "card_buf", "input_buf" }) do
    local buf = state[name]
    if opts.valid_buf(buf) then
      for key, action in pairs({ r = "resend", e = "restore", d = "dismiss" }) do
        pcall(vim.keymap.del, "n", key, { buffer = buf })
        if state.failure_action then
          vim.keymap.set("n", key, function()
            local handler = state.failure_action
            M.clear_failure(state, opts)
            handler(action)
          end, { buffer = buf, nowait = true, desc = "Omniac failed prompt: " .. action })
        end
      end
    end
  end
end

function M.stop_timer(state)
  if state.activity_timer then
    state.activity_timer:stop()
    state.activity_timer:close()
    state.activity_timer = nil
  end
end

function M.sync_timer(state, render_activity)
  if state.status ~= "working" then
    M.stop_timer(state)
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

function M.set_status(state, status, config, opts)
  state.activity_generation = state.activity_generation + 1
  local previous_status = state.status
  state.status = status or "idle"
  if state.status == "working" and state.failure_action then
    state.failure_action = nil
    sync_failure_shortcuts(state, opts)
  end
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
  M.sync_change_shortcuts(state, opts)
  opts.render_chat(config)
  if state.card_pinned then
    opts.render_card()
  end
  opts.render_activity()
  opts.render_status()
  M.sync_timer(state, opts.render_activity)
  if state.status ~= previous_status then
    opts.restart_mascot_actions()
  end
end

function M.set_activity(state, value, opts, activity_opts)
  state.activity_generation = state.activity_generation + 1
  state.transient_activity = value and value ~= "" and value or nil
  state.change_summary = state.transient_activity ~= nil
    and activity_opts ~= nil
    and activity_opts.change_summary == true
  M.sync_change_shortcuts(state, opts)
  opts.render_activity()
  opts.render_status()
  M.sync_timer(state, opts.render_activity)
end

function M.show_failure(state, handler, opts)
  state.failure_action = handler
  sync_failure_shortcuts(state, opts)
  if vim.fn.mode():match("^[iR]") then
    vim.cmd("stopinsert")
  end
  opts.render_activity()
end

function M.clear_failure(state, opts)
  state.failure_action = nil
  sync_failure_shortcuts(state, opts)
  opts.render_activity()
end

function M.flash(state, value, config, duration_ms, opts)
  local previous = state.transient_activity
  local previous_change_summary = state.change_summary
  M.set_activity(state, value, opts)
  local generation = state.activity_generation
  vim.defer_fn(function()
    if state.activity_generation == generation and opts.valid_buf(state.activity_buf) then
      M.set_activity(state, previous, opts, { change_summary = previous_change_summary })
    end
  end, duration_ms or 1000)
end

function M.set_change_review_handler(state, handler, opts)
  state.change_review_handler = handler
  M.sync_change_shortcuts(state, opts)
end

return M
