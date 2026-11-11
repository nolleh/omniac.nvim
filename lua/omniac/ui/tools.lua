local M = {}
local chat_render = require("omniac.ui.chat.render")
local tool_result = require("omniac.ui.chat.tool_result")

local function is_terminal_activity(state)
  return state.tool_activity and (state.tool_activity:match("^Completed ") or state.tool_activity:match("^Failed "))
end

local function result_mode(state, config)
  local mode = ((config or state.config or {}).ui or {}).tool_results
  if mode == "all" or mode == "none" or mode == "compact" then
    return mode
  end
  return "compact"
end

local function result_max_lines(state, config)
  local value = tonumber(((config or state.config or {}).ui or {}).tool_result_max_lines)
  if not value then
    return 4
  end
  return math.max(0, math.floor(value))
end

local function is_opaque_name(value)
  return type(value) == "string" and value:match("^call_[%w_%-]+$")
end

local function should_show_result(state, params, config)
  if params.status == "failed" then
    return true
  end

  local mode = result_mode(state, config)
  if mode == "none" then
    return false
  end
  if mode == "all" then
    return true
  end

  local command = params.command
  local title = params.title
  local display = command or title or params.kind
  if is_opaque_name(display) or (not command and is_opaque_name(title)) then
    return false
  end

  return true
end

function M.stop_timer(state)
  if state.tool_activity_timer then
    state.tool_activity_timer:stop()
    state.tool_activity_timer:close()
    state.tool_activity_timer = nil
  end
end

function M.clear_completed(state, render_activity)
  if state.status == "working" and is_terminal_activity(state) then
    M.stop_timer(state)
    state.tool_activity = nil
    render_activity()
  end
end

function M.set_activity(state, params, render_activity)
  params = params or {}
  local status = params.status or "running"
  local kind = params.kind or "tool"
  local title = params.title or kind
  local prefix = "Running"

  if status == "completed" then
    prefix = "Completed"
  elseif status == "failed" then
    prefix = "Failed"
  elseif status == "pending" then
    prefix = "Pending"
  elseif status == "in_progress" then
    prefix = "Running"
  end

  local exit = params.exitCode ~= nil and (" exit " .. tostring(params.exitCode)) or ""
  state.tool_activity = string.format("%s %s: %s%s", prefix, kind, title, exit)

  M.stop_timer(state)
  if status == "completed" or status == "failed" then
    local uv = vim.uv or vim.loop
    state.tool_activity_timer = uv.new_timer()
    state.tool_activity_timer:start(
      500,
      0,
      vim.schedule_wrap(function()
        state.tool_activity_timer = nil
        if state.status == "working" and is_terminal_activity(state) then
          state.tool_activity = nil
          render_activity()
        end
      end)
    )
  end
  render_activity()
end

function M.toggle_output(state, config, handlers)
  local width = state.chat_win
      and vim.api.nvim_win_is_valid(state.chat_win)
      and vim.api.nvim_win_get_width(state.chat_win)
    or (state.chat_render_cache and state.chat_render_cache.width)
    or 60
  for index = #state.messages, 1, -1 do
    local message = state.messages[index]
    if message and message.type == "tool_result" and tool_result.can_expand(message, width) then
      message.expanded = not message.expanded
      chat_render.invalidate(state, index)
      handlers.render_chat(config or state.config)
      handlers.focus_input()
      return true
    end
  end
  return false
end

function M.add_result(state, params, config, handlers)
  params = params or {}
  local output = params.output
  if type(output) ~= "string" or output == "" or not should_show_result(state, params, config) then
    return
  end

  if state.streaming_message_index and state.messages[state.streaming_message_index] then
    state.messages[state.streaming_message_index].complete = true
    chat_render.invalidate(state, state.streaming_message_index)
    state.streaming_message_index = nil
  end

  table.insert(state.messages, {
    type = "tool_result",
    role = "Tool",
    kind = params.kind,
    status = params.status,
    title = params.title,
    command = params.command,
    cwd = params.cwd,
    output = output,
    exitCode = params.exitCode,
    expanded = false,
    output_preview_lines = result_max_lines(state, config),
  })
  handlers.request_chat_render(config, { immediate = true, follow = true })
  handlers.focus_input_if_active()
end

return M
