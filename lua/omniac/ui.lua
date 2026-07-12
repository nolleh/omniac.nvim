local M = {}
local clipboard = require("omniac.clipboard")

local ns = vim.api.nvim_create_namespace("omniac.ui")
local augroup = vim.api.nvim_create_augroup("omniac.ui", { clear = false })

local state = {
  chat_buf = nil,
  chat_win = nil,
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
  activity_frame = 1,
  tool_activity = nil,
  messages = {},
  streaming_message_index = nil,
  config = nil,
  submit = nil,
  cancel_handler = nil,
  cancel_requested = false,
  suppress_current_turn = false,
  rendering_input = false,
  input_chunks = nil,
  input_attachments = {},
  transient_activity = nil,
  available_commands = {},
  session_mode = nil,
  mode_cycle_handler = nil,
  relayout_pending = false,
  user_width = nil,
  skip_user_width_capture = false,
  active_turn_id = nil,
}

local INPUT_MIN_DISPLAY_LINES = 3
local INPUT_MAX_DISPLAY_LINES = 10
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

local function width(config)
  local value = ((config or {}).ui or {}).chat_width or 58
  return math.min(math.max(value, 42), math.max(42, vim.o.columns - 20))
end

local function target_width()
  local value = state.user_width or width(state.config)
  return math.min(math.max(value, 42), math.max(42, vim.o.columns - 20))
end

local function agent_name(config)
  local cmd = ((config or state.config or {}).agent or {}).cmd or {}
  if type(cmd) == "table" then
    return cmd[1] or "agent"
  end
  return tostring(cmd ~= "" and cmd or "agent")
end

local function center(text, size)
  local display_width = vim.fn.strdisplaywidth(text)
  local pad = math.max(0, math.floor((size - display_width) / 2))
  return string.rep(" ", pad) .. text
end

local function fit(text, size)
  local value = tostring(text or "")
  local current = vim.fn.strdisplaywidth(value)
  if current > size then
    local out = ""
    for char in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if vim.fn.strdisplaywidth(out .. char) > size - 1 then
        return out .. "…"
      end
      out = out .. char
    end
    return out
  end
  return value .. string.rep(" ", size - current)
end

local function chars(text)
  return tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

local function box_line(left, fill, right, size)
  return left .. string.rep(fill, math.max(0, size - 2)) .. right
end

local function boxed_text(text, size)
  return "│" .. fit(center(text, size - 2), size - 2) .. "│"
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "OmniacTitle", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacBorder", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "OmniacMuted", { fg = "#7f849c" })
  vim.api.nvim_set_hl(0, "OmniacAccent", { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "OmniacGraphic", { fg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacGraphicShade", { fg = "#89dceb" })
  vim.api.nvim_set_hl(0, "OmniacUser", { fg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "OmniacUserBubble", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacAssistant", { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacAssistantText", { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "OmniacCode", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "OmniacError", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking1", { fg = "#585b70", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking2", { fg = "#7f849c", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking3", { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacWorking4", { fg = "#f5c2e7", bold = true })
  vim.api.nvim_set_hl(0, "OmniacInput", { bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacInputText", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacInputPrompt", { fg = "#89b4fa", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusMode", { fg = "#11111b", bg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatus", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsule", { fg = "#11111b", bg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsuleEdge", { fg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusModeEdge", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsuleAlt", { fg = "#cdd6f4", bg = "#45475a", bold = true })
  vim.api.nvim_set_hl(0, "OmniacStatusCapsuleAltEdge", { fg = "#45475a", bold = true })
  vim.api.nvim_set_hl(0, "OmniacCommandName", { fg = "#94e2d5", bold = true })
  vim.api.nvim_set_hl(0, "OmniacCommandText", { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "OmniacCommandMuted", { fg = "#7f849c" })
end

local function add_hl(buf, line, start_col, end_col, group)
  if valid_buf(buf) then
    vim.api.nvim_buf_add_highlight(buf, ns, group, line - 1, start_col, end_col)
  end
end

local function add_line(lines, marks, text, group)
  table.insert(lines, text)
  if group then
    table.insert(marks, { line = #lines, from = 0, to = -1, group = group })
  end
end

local function add_mark(marks, line, from, to, group)
  table.insert(marks, { line = line, from = from, to = to, group = group })
end

local render_chat

local function add_boxed_line(lines, marks, text, size, group)
  local line = boxed_text(text, size)
  table.insert(lines, line)
  local lnum = #lines
  local border_width = #"│"
  add_mark(marks, lnum, 0, border_width, "OmniacBorder")
  add_mark(marks, lnum, #line - border_width, -1, "OmniacBorder")
  if group then
    add_mark(marks, lnum, border_width, #line - border_width, group)
  end
end

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
  opts = opts or {}
  render_chat(config or state.config, opts)
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

local function wrapped(text, max_width)
  local result = {}
  for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      table.insert(result, "")
    else
      local current = ""
      for char in chars(raw) do
        if vim.fn.strdisplaywidth(current .. char) > max_width and current ~= "" then
          table.insert(result, current)
          current = char
        else
          current = current .. char
        end
      end
      if current ~= "" then
        table.insert(result, current)
      end
    end
  end
  if result[#result] == "" then
    table.remove(result)
  end
  return result
end

local function split_lines(text)
  local result = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    table.insert(result, line)
  end
  if #result > 0 and result[#result] == "" then
    table.remove(result)
  end
  return result
end

local function unwrap_markdown_fences(text)
  local result = {}
  local in_markdown_fence = false

  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local lang = line:match("^%s*```%s*([%w_-]+)%s*$")
    if in_markdown_fence and line:match("^%s*```%s*$") then
      in_markdown_fence = false
    elseif not in_markdown_fence and lang and (lang == "markdown" or lang == "md") then
      in_markdown_fence = true
    else
      table.insert(result, line)
    end
  end

  if #result > 0 and result[#result] == "" then
    table.remove(result)
  end
  return table.concat(result, "\n")
end

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

local function normalized_stop_reason(params)
  params = params or {}
  local reason = params.stopReason or params.stop_reason
  if not reason and type(params.result) == "table" then
    reason = params.result.stopReason or params.result.stop_reason
  end
  return type(reason) == "string" and reason or nil
end

local function notification_turn_id(params)
  params = params or {}
  local turn_id = params.turnId or params.turn_id
  return type(turn_id) == "number" and turn_id or nil
end

local function stop_reason_activity(reason, config)
  if reason == "cancelled" or reason == "canceled" then
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

local render_activity

local function clear_completed_tool_activity()
  if state.status == "working" and state.tool_activity and state.tool_activity:match("^Completed ") then
    state.tool_activity = nil
    render_activity()
  end
end

local function nonempty_tail(lines)
  for index = #lines, 1, -1 do
    if tostring(lines[index] or ""):match("%S") then
      return lines[index]
    end
  end
  return nil
end

local function collapsed_tool_lines(lines)
  if #lines <= 4 then
    return vim.deepcopy(lines)
  end

  return {
    lines[1],
    lines[2],
    "…",
    lines[#lines - 1],
    lines[#lines],
  }
end

local function tool_result_text(message)
  local command = message.command or message.title or message.kind or "tool"
  local lines = split_lines(message.output or "")
  local visible = message.expanded and lines or collapsed_tool_lines(lines)
  local hidden = math.max(0, #lines - 4)
  local title = message.status == "failed" and "Failed" or "Ran"
  local suffix = message.exitCode ~= nil and (" (exit " .. tostring(message.exitCode) .. ")") or ""
  local result = { title .. " " .. command .. suffix }

  if #lines == 1 then
    local tail = nonempty_tail(lines)
    if tail and tail ~= "" then
      result[1] = result[1] .. ": " .. tail
    end
  elseif #visible > 0 then
    table.insert(result, "```text")
    for _, line in ipairs(visible) do
      table.insert(result, line)
    end
    table.insert(result, "```")
  end

  if #lines > 4 then
    table.insert(
      result,
      message.expanded and ("-" .. tostring(hidden) .. " lines (Ctrl-T to collapse)")
        or ("+" .. tostring(hidden) .. " lines (Ctrl-T to expand)")
    )
  end

  return table.concat(result, "\n")
end

local function is_markdown_structural_line(line)
  local value = tostring(line or "")
  return value == ""
    or value:match("^%s*|")
    or value:match("^%s*```")
    or value:match("^%s*~~~")
    or value:match("^%s*%-%-%-+%s*$")
end

local function chat_message_lines(line, width)
  if is_markdown_structural_line(line) then
    return { line }
  end

  local result = {}
  for _, wrapped_line in ipairs(wrapped(line, math.max(1, width - 4))) do
    table.insert(result, "  " .. fit(wrapped_line, math.max(1, width - 4)) .. "  ")
  end
  return result
end

local function is_opaque_tool_name(value)
  return type(value) == "string" and value:match("^call_[%w_%-]+$")
end

local function tool_result_mode(config)
  local mode = ((config or state.config or {}).ui or {}).tool_results
  if mode == "all" or mode == "none" or mode == "compact" then
    return mode
  end
  return "compact"
end

local function tool_result_max_lines(config)
  local value = tonumber(((config or state.config or {}).ui or {}).tool_result_max_lines)
  if not value then
    return 4
  end
  return math.max(0, math.floor(value))
end

local function should_show_tool_result(params, config)
  if params.status == "failed" then
    return true
  end

  local mode = tool_result_mode(config)
  if mode == "none" then
    return false
  end
  if mode == "all" then
    return true
  end

  local command = params.command
  local title = params.title
  local display = command or title or params.kind
  if is_opaque_tool_name(display) or (not command and is_opaque_tool_name(title)) then
    return false
  end

  local line_count = #(split_lines(params.output or ""))
  return line_count <= tool_result_max_lines(config)
end

local function header(lines, marks, size)
  local box_width = math.max(40, size)
  local inner = box_width - 2
  local user = vim.env.USER or "there"
  local title = "Omniac Code"
  local top = "╭─ "
    .. title
    .. " "
    .. string.rep("─", math.max(0, box_width - vim.fn.strdisplaywidth(title) - 5))
    .. "╮"
  local bottom = box_line("╰", "─", "╯", box_width)

  add_line(lines, marks, top, "OmniacBorder")
  add_boxed_line(lines, marks, "", box_width, nil)
  add_boxed_line(lines, marks, "Welcome back " .. user .. "!", box_width, "OmniacAccent")
  add_boxed_line(lines, marks, "", box_width, nil)

  local graphic = {
    "        ▄▄▄▄▄▄▄        ",
    "     ▄███████████▄     ",
    "   ▄██▀  ▀███▀  ▀██▄   ",
    "   ██    ▄███▄    ██   ",
    "   ▀██▄  ▀▀▀▀▀  ▄██▀   ",
    "      ▀█████████▀      ",
    "       ▀▀  ▀  ▀▀       ",
  }
  for _, line in ipairs(graphic) do
    add_boxed_line(lines, marks, line, box_width, "OmniacGraphic")
  end

  add_boxed_line(lines, marks, "", box_width, nil)
  add_boxed_line(
    lines,
    marks,
    agent_name(state.config) .. " / " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"),
    box_width,
    "OmniacMuted"
  )
  add_line(lines, marks, bottom, "OmniacBorder")
end

render_chat = function(config, opts)
  opts = opts or {}
  state.config = config or state.config
  if not valid_buf(state.chat_buf) then
    return
  end

  local win_width = valid_win(state.chat_win) and vim.api.nvim_win_get_width(state.chat_win) or target_width()
  local text_width = math.max(28, win_width - 6)
  local lines = {}
  local marks = {}

  local function add_message_separator()
    add_line(
      lines,
      marks,
      "  " .. fit(string.rep("─", math.max(0, win_width - 4)), win_width - 4) .. "  ",
      "OmniacMuted"
    )
  end

  header(lines, marks, win_width)
  add_line(lines, marks, "", nil)

  if #state.messages == 0 then
    add_line(lines, marks, box_line("╭", "─", "╮", win_width), "OmniacBorder")
    add_boxed_line(
      lines,
      marks,
      "Agent: " .. agent_name(state.config) .. "  •  Status: " .. state.status,
      win_width,
      "OmniacAccent"
    )
    add_boxed_line(lines, marks, "cwd: " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"), win_width, "OmniacMuted")
    add_line(lines, marks, box_line("╰", "─", "╯", win_width), "OmniacBorder")
  else
    for _, message in ipairs(state.messages) do
      local group = message.role == "You" and "OmniacUserBubble" or nil
      if message.role == "Error" then
        group = "OmniacError"
      end

      if message.role == "You" then
        for _, line in ipairs(wrapped(message.text, text_width)) do
          add_line(lines, marks, "  " .. fit(line, win_width - 4) .. "  ", group)
        end
        add_message_separator()
      else
        local message_text = message.type == "tool_result" and tool_result_text(message) or message.text
        if message.type ~= "tool_result" then
          message_text = unwrap_markdown_fences(message_text)
        end
        for _, line in ipairs(split_lines(message_text)) do
          for _, display_line in ipairs(chat_message_lines(line, win_width)) do
            add_line(lines, marks, display_line, group)
          end
        end
        if message.stop_footer and message.stop_footer ~= "" then
          add_line(lines, marks, "  " .. fit(message.stop_footer, win_width - 4) .. "  ", "OmniacMuted")
        end
        local complete = message.complete or (message.complete == nil and message.role == "Omniac" and not message.type)
        if complete then
          add_message_separator()
        end
      end
      add_line(lines, marks, "", nil)
    end
  end

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

  for _, mark in ipairs(marks) do
    add_hl(state.chat_buf, mark.line, mark.from, mark.to, mark.group)
  end

  if not opts.skip_markdown then
    render_chat_markdown()
  end

  if valid_win(state.chat_win) and #lines > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { #lines, 0 })
  end
end

local function render_status()
  if not valid_buf(state.status_buf) then
    return
  end

  local win_width = valid_win(state.status_win) and vim.api.nvim_win_get_width(state.status_win) or target_width()
  local mode = state.session_mode and (state.session_mode.currentModeName or state.session_mode.currentModeId)
  local left = " Omniac "
  local middle = "  " .. state.status .. " "
  local mode_capsule = mode and mode ~= "" and ("  " .. mode .. " ") or ""
  local right = "  " .. agent_name(state.config) .. " "
  local spacer =
    string.rep(" ", math.max(1, win_width - vim.fn.strdisplaywidth(left .. middle .. mode_capsule .. right)))
  local line = left .. middle .. mode_capsule .. spacer .. right

  vim.bo[state.status_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.status_buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.status_buf, 0, -1, false, { fit(line, win_width) })
  vim.bo[state.status_buf].modifiable = false
  vim.bo[state.status_buf].modified = false

  local col = 0
  local function add_capsule(text, fill_group, edge_group)
    add_hl(state.status_buf, 1, col, col + #"", edge_group)
    col = col + #""
    add_hl(state.status_buf, 1, col, col + #text, fill_group)
    col = col + #text
    add_hl(state.status_buf, 1, col, col + #"", edge_group)
    col = col + #""
  end

  add_capsule(" Omniac ", "OmniacStatusCapsule", "OmniacStatusCapsuleEdge")
  col = col + #" "
  add_capsule(" " .. state.status .. " ", "OmniacStatusMode", "OmniacStatusModeEdge")
  if mode_capsule ~= "" then
    col = col + #" "
    add_capsule(" " .. mode .. " ", "OmniacStatusCapsuleAlt", "OmniacStatusCapsuleAltEdge")
  end
  col = col + #spacer + #" "
  add_capsule(" " .. agent_name(state.config) .. " ", "OmniacStatusCapsuleAlt", "OmniacStatusCapsuleAltEdge")
end

render_activity = function()
  if not valid_buf(state.activity_buf) then
    return
  end

  local win_width = valid_win(state.activity_win) and vim.api.nvim_win_get_width(state.activity_win) or target_width()
  local frames = {
    "Working",
    "Working.",
    "Working..",
    "Working...",
  }
  local groups = {
    "OmniacWorking1",
    "OmniacWorking2",
    "OmniacWorking3",
    "OmniacWorking4",
  }
  local text = ""
  if state.transient_activity then
    text = state.transient_activity
  elseif state.status == "working" and state.tool_activity then
    text = state.tool_activity
  elseif state.status == "working" then
    text = frames[state.activity_frame]
  elseif state.status == "connecting" then
    text = "Connecting..."
  end
  local line = ""
  if text ~= "" then
    local inner_width = math.max(1, win_width - 4)
    local display = fit(text, inner_width)
    local padded = vim.fn.strdisplaywidth(text) > inner_width and display or center(display, inner_width)
    line = "  " .. padded .. "  "
  end

  vim.bo[state.activity_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.activity_buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.activity_buf, 0, -1, false, { line })
  vim.bo[state.activity_buf].modifiable = false
  vim.bo[state.activity_buf].modified = false

  if text ~= "" then
    add_hl(state.activity_buf, 1, 0, -1, groups[state.activity_frame])
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

local function reset_input()
  if not valid_buf(state.input_buf) then
    return
  end

  local win_width = valid_win(state.input_win) and vim.api.nvim_win_get_width(state.input_win) or target_width()
  state.rendering_input = true
  vim.bo[state.input_buf].modifiable = true
  local buffer_lines = { box_line("╭", "─", "╮", win_width), INPUT_PROMPT }
  for _ = 2, INPUT_MIN_DISPLAY_LINES do
    table.insert(buffer_lines, INPUT_CONTINUATION)
  end
  table.insert(buffer_lines, box_line("╰", "─", "╯", win_width))
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, buffer_lines)
  vim.api.nvim_buf_clear_namespace(state.input_buf, ns, 0, -1)
  add_hl(state.input_buf, 1, 0, -1, "OmniacBorder")
  for index = 1, INPUT_MIN_DISPLAY_LINES do
    local line_number = index + 1
    local prefix = index == 1 and INPUT_PROMPT or INPUT_CONTINUATION
    vim.api.nvim_buf_set_extmark(state.input_buf, ns, line_number - 1, 0, {
      line_hl_group = "OmniacInput",
    })
    vim.api.nvim_buf_set_extmark(state.input_buf, ns, line_number - 1, 0, {
      virt_text = { { "│", "OmniacBorder" } },
      virt_text_pos = "overlay",
      virt_text_win_col = win_width - 1,
    })
    add_hl(state.input_buf, line_number, 0, #"│", "OmniacBorder")
    if index == 1 then
      add_hl(state.input_buf, line_number, #"│", #prefix, "OmniacInputPrompt")
    end
    add_hl(state.input_buf, line_number, #prefix, -1, "OmniacInputText")
  end
  add_hl(state.input_buf, #buffer_lines, 0, -1, "OmniacBorder")
  vim.bo[state.input_buf].modified = false
  state.rendering_input = false
  state.input_chunks = { { source_line = 1, start_col = 0, end_col = 0 } }
  for index = 2, INPUT_MIN_DISPLAY_LINES do
    state.input_chunks[index] = { padding = true }
  end
  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_height, state.input_win, INPUT_MIN_DISPLAY_LINES + 2)
  end
end

local function attachment_summary(attachments)
  local count = #(attachments or {})
  if count == 0 then
    return nil
  end

  local parts = {}
  for index, attachment in ipairs(attachments) do
    local size = attachment.byteSize and string.format(" %.1fKB", attachment.byteSize / 1024) or ""
    table.insert(parts, string.format("image %d: %s%s", index, attachment.mimeType or "image", size))
  end
  return table.concat(parts, ", ")
end

local function strip_input_prefix(line, index)
  local prefix = index == 1 and INPUT_PROMPT or INPUT_CONTINUATION
  if line:sub(1, #prefix) == prefix then
    return line:sub(#prefix + 1)
  end
  if prefix:sub(1, #line) == line then
    return ""
  end
  if line:sub(1, #"│") == "│" then
    return (line:gsub("^│%s*", "", 1))
  end
  return line
end

local function previous_char_start(text, col)
  local last_start = 0
  local byte_col = 0

  for char in chars(text) do
    local next_col = byte_col + #char
    if next_col >= col then
      return byte_col
    end
    last_start = byte_col
    byte_col = next_col
  end

  return last_start
end

local function raw_input_lines()
  if not valid_buf(state.input_buf) then
    return { "" }
  end

  local buffer_lines = vim.api.nvim_buf_get_lines(state.input_buf, 1, -1, false)
  if #buffer_lines > 0 then
    table.remove(buffer_lines)
  end
  if #buffer_lines == 0 then
    return { "" }
  end

  if state.input_chunks and #state.input_chunks == #buffer_lines then
    local result = {}
    for index, line in ipairs(buffer_lines) do
      local chunk = state.input_chunks[index]
      if not chunk.padding then
        local source_line = chunk.source_line
        result[source_line] = (result[source_line] or "") .. strip_input_prefix(line, index)
      end
    end
    return #result > 0 and result or { "" }
  end

  local result = {}
  for index, line in ipairs(buffer_lines) do
    table.insert(result, strip_input_prefix(line, index))
  end
  return result
end

local function raw_input_text()
  return table.concat(raw_input_lines(), "\n")
end

local function input_text()
  return (raw_input_text():gsub("^%s+", ""):gsub("%s+$", ""))
end

local function local_commands()
  return {
    {
      name = "exit",
      description = "Close Omniac chat",
    },
    {
      name = "resume",
      description = "Open the ACP session selector",
    },
  }
end

local function normalized_commands()
  local seen = {}
  local result = {}
  local function add(command, source)
    if type(command) ~= "table" or type(command.name) ~= "string" or command.name == "" then
      return
    end
    local trigger = "/"
    local name = command.name
    local first = name:sub(1, 1)
    if first == "/" or first == "$" then
      trigger = first
      name = name:sub(2)
    end
    if name == "" then
      return
    end
    local key = trigger .. name
    if seen[key] then
      return
    end
    seen[key] = true
    local description = type(command.description) == "string" and command.description or ""
    local input = type(command.input) == "table" and command.input or nil
    table.insert(result, {
      trigger = trigger,
      name = name,
      description = description,
      input = input,
      source = source,
    })
  end

  for _, command in ipairs(local_commands()) do
    add(command, "omniac")
  end
  for _, command in ipairs(state.available_commands or {}) do
    add(command, "agent")
  end

  table.sort(result, function(left, right)
    if left.source ~= right.source then
      return left.source == "omniac"
    end
    if left.trigger ~= right.trigger then
      return left.trigger < right.trigger
    end
    return left.name < right.name
  end)
  return result
end

local function command_prefix()
  local text = raw_input_text()
  if text:find("\n", 1, true) then
    return nil, nil
  end
  local trigger, prefix = text:match("^%s*([/$])([^%s]*)$")
  return trigger, prefix
end

local function mention_prefix()
  local text = raw_input_text()
  if text:find("\n", 1, true) then
    return nil
  end
  return text:match("^%s*@([^%s]*)$")
end

local function command_matches(trigger, prefix)
  if trigger == nil or prefix == nil then
    return {}
  end

  local matches = {}
  for _, command in ipairs(normalized_commands()) do
    if command.trigger == trigger and command.name:sub(1, #prefix) == prefix then
      table.insert(matches, command)
    end
  end
  return matches
end

local function file_matches(prefix)
  if prefix == nil then
    return {}
  end

  local cwd = vim.loop.cwd() or "."
  local pattern = prefix == "" and "*" or (prefix .. "*")
  local paths = vim.fn.globpath(cwd, pattern, false, true)
  local matches = {}
  for _, path in ipairs(paths or {}) do
    local relative = vim.fn.fnamemodify(path, ":.")
    if relative ~= "." and relative ~= "" then
      local is_dir = vim.fn.isdirectory(path) == 1
      table.insert(matches, {
        name = relative .. (is_dir and "/" or ""),
        description = is_dir and "directory" or "file",
        source = "file",
      })
    end
  end
  table.sort(matches, function(left, right)
    if left.description ~= right.description then
      return left.description == "directory"
    end
    return left.name < right.name
  end)
  return matches
end

local function current_suggestions()
  local trigger, prefix = command_prefix()
  if trigger ~= nil then
    return "command", command_matches(trigger, prefix), trigger
  end

  local mention = mention_prefix()
  if mention ~= nil then
    return "mention", file_matches(mention)
  end

  return nil, {}
end

local function completed_suggestion_text(text)
  local trigger, prefix = command_prefix()
  if trigger ~= nil then
    local matches = command_matches(trigger, prefix)
    if #matches > 0 then
      return matches[1].trigger .. matches[1].name
    end
  end

  prefix = mention_prefix()
  if prefix ~= nil then
    local matches = file_matches(prefix)
    if #matches > 0 then
      return "@" .. matches[1].name
    end
  end

  return text
end

local render_input
local focus_input
local focus_chat

local function complete_current_suggestion()
  local text = input_text()
  local completed = completed_suggestion_text(text)
  if completed == text then
    return false
  end

  render_input(completed, {
    line = 1,
    col = #completed,
  })
  vim.cmd("startinsert!")
  return true
end

local function cancel_active_turn()
  if state.status ~= "working" or state.cancel_requested then
    return false
  end

  state.cancel_requested = true
  state.suppress_current_turn = true
  vim.schedule(function()
    M.set_activity("Cancelling current turn.", state.config)
    if state.cancel_handler then
      state.cancel_handler()
    end
    focus_input()
  end)
  return true
end

local function add_clipboard_image()
  local image, err = clipboard.read_image()
  if not image then
    return false, err
  end

  table.insert(state.input_attachments, image)
  vim.schedule(function()
    M.set_activity("Attached " .. (attachment_summary({ image }) or "image") .. ".", state.config)
    focus_input()
  end)
  return true
end

local function clear_input_attachments()
  state.input_attachments = {}
end

local function ensure_command_buffer()
  if valid_buf(state.command_buf) then
    return
  end
  state.command_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.command_buf].buftype = "nofile"
  vim.bo[state.command_buf].bufhidden = "wipe"
  vim.bo[state.command_buf].swapfile = false
  vim.bo[state.command_buf].buflisted = false
  vim.bo[state.command_buf].filetype = "omniac-commands"
  vim.api.nvim_buf_set_name(state.command_buf, "omniac://commands")
end

local resize_aux_windows

local function clear_command_window()
  if valid_buf(state.command_buf) then
    vim.bo[state.command_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.command_buf, 0, -1, false, { "", "", "", "", "" })
    vim.api.nvim_buf_clear_namespace(state.command_buf, ns, 0, -1)
    vim.bo[state.command_buf].modifiable = false
    vim.bo[state.command_buf].modified = false
  end
end

local function close_command_window()
  local had_window = valid_win(state.command_win)
  if valid_win(state.command_win) then
    pcall(vim.api.nvim_win_close, state.command_win, true)
  end
  state.command_win = nil
  if had_window and resize_aux_windows then
    resize_aux_windows()
    vim.schedule(resize_aux_windows)
  end
end

local update_command_window

local function input_bottom_position()
  if not valid_win(state.input_win) then
    return 0, 0
  end
  local pos = vim.api.nvim_win_get_position(state.input_win)
  local row = pos[1] + vim.api.nvim_win_get_height(state.input_win)
  return row, pos[2]
end

local function input_content_width(win_width, prefix)
  return math.max(1, win_width - vim.fn.strdisplaywidth(prefix or INPUT_PROMPT) - 3)
end

local function input_display_height(lines, win_width)
  return math.min(INPUT_MAX_DISPLAY_LINES, math.max(INPUT_MIN_DISPLAY_LINES, #lines)) + 2
end

local function bottom_stack_height()
  local activity_height = 1
  local status_height = 1
  local input_height = input_display_height(raw_input_lines(), target_width())

  return activity_height + input_height + status_height
end

local function wrap_input_lines(lines, cursor, win_width)
  local wrapped_lines = {}
  local chunks = {}

  for line_index, line in ipairs(lines) do
    if line == "" then
      table.insert(wrapped_lines, "")
      table.insert(chunks, { source_line = line_index, start_col = 0, end_col = 0 })
    else
      local current = ""
      local current_width = 0
      local current_start = 0
      local byte_col = 0

      for char in chars(line) do
        local prefix = #wrapped_lines == 0 and INPUT_PROMPT or INPUT_CONTINUATION
        local max_width = input_content_width(win_width, prefix)
        local char_width = vim.fn.strdisplaywidth(char)
        if current ~= "" and current_width + char_width > max_width then
          table.insert(wrapped_lines, current)
          table.insert(chunks, { source_line = line_index, start_col = current_start, end_col = byte_col })
          current = char
          current_width = char_width
          current_start = byte_col
        else
          current = current .. char
          current_width = current_width + char_width
        end
        byte_col = byte_col + #char
      end

      table.insert(wrapped_lines, current)
      table.insert(chunks, { source_line = line_index, start_col = current_start, end_col = #line })
    end
  end

  local wrapped_cursor
  if cursor then
    for index, chunk in ipairs(chunks) do
      if cursor.line == chunk.source_line and cursor.col >= chunk.start_col and cursor.col <= chunk.end_col then
        wrapped_cursor = {
          line = index,
          col = cursor.col - chunk.start_col,
        }
        break
      end
    end
  end

  return wrapped_lines, wrapped_cursor or cursor, chunks
end

local reset_leftcol

render_input = function(lines, cursor, opts)
  opts = opts or {}
  if not valid_buf(state.input_buf) then
    return
  end

  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if not lines or #lines == 0 then
    lines = { "" }
  end

  local win_width = valid_win(state.input_win) and vim.api.nvim_win_get_width(state.input_win) or target_width()
  local chunks
  lines, cursor, chunks = wrap_input_lines(lines, cursor, win_width)
  local display_line_count = math.max(INPUT_MIN_DISPLAY_LINES, #lines)
  local buffer_lines = { box_line("╭", "─", "╮", win_width) }
  for index = 1, display_line_count do
    local line = lines[index] or ""
    table.insert(buffer_lines, (index == 1 and INPUT_PROMPT or INPUT_CONTINUATION) .. line)
    if not chunks[index] then
      chunks[index] = { padding = true }
    end
  end
  table.insert(buffer_lines, box_line("╰", "─", "╯", win_width))

  state.rendering_input = true
  vim.bo[state.input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, buffer_lines)
  vim.api.nvim_buf_clear_namespace(state.input_buf, ns, 0, -1)
  add_hl(state.input_buf, 1, 0, -1, "OmniacBorder")
  for index = 1, display_line_count do
    local line_number = index + 1
    local prefix = index == 1 and INPUT_PROMPT or INPUT_CONTINUATION
    vim.api.nvim_buf_set_extmark(state.input_buf, ns, line_number - 1, 0, {
      line_hl_group = "OmniacInput",
    })
    vim.api.nvim_buf_set_extmark(state.input_buf, ns, line_number - 1, 0, {
      virt_text = { { "│", "OmniacBorder" } },
      virt_text_pos = "overlay",
      virt_text_win_col = win_width - 1,
    })
    add_hl(state.input_buf, line_number, 0, #"│", "OmniacBorder")
    if index == 1 then
      add_hl(state.input_buf, line_number, #"│", #prefix, "OmniacInputPrompt")
    end
    add_hl(state.input_buf, line_number, #prefix, -1, "OmniacInputText")
  end
  add_hl(state.input_buf, #buffer_lines, 0, -1, "OmniacBorder")
  vim.bo[state.input_buf].modified = false
  state.rendering_input = false
  state.input_chunks = chunks

  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_height, state.input_win, math.min(INPUT_MAX_DISPLAY_LINES, display_line_count) + 2)
    if cursor and vim.api.nvim_get_current_buf() == state.input_buf then
      local cursor_line = math.min(math.max(cursor.line or 1, 1), #lines)
      local prefix = cursor_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
      local cursor_col = math.min(math.max(cursor.col or 0, 0), #(lines[cursor_line] or ""))
      pcall(vim.api.nvim_win_set_cursor, state.input_win, { cursor_line + 1, #prefix + cursor_col })
    end
    reset_leftcol(state.input_win)
  end
  if update_command_window and not opts.skip_command_window then
    update_command_window()
  end
end

local function logical_cursor_from_display(cursor)
  local input_line = math.max(cursor[1] - 1, 1)
  local chunks = state.input_chunks
  if chunks and chunks[input_line] then
    local chunk = chunks[input_line]
    if chunk.padding then
      local lines = raw_input_lines()
      local last_line = math.max(1, #lines)
      return {
        line = last_line,
        col = #(lines[last_line] or ""),
      }
    end
    local prefix = input_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
    return {
      line = chunk.source_line,
      col = math.max(0, cursor[2] - #prefix) + (chunk.start_col or 0),
    }
  end

  local prefix = input_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
  return {
    line = input_line,
    col = math.max(0, cursor[2] - #prefix),
  }
end

local function clamp_input_cursor()
  if state.rendering_input or not valid_win(state.input_win) or not valid_buf(state.input_buf) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local buffer_line_count = vim.api.nvim_buf_line_count(state.input_buf)
  local input_line_count = math.max(1, buffer_line_count - 2)
  local input_line = math.min(math.max(cursor[1] - 1, 1), input_line_count)
  local prefix = input_line == 1 and INPUT_PROMPT or INPUT_CONTINUATION
  local row = input_line + 1
  local col = math.max(cursor[2], #prefix)

  if cursor[1] ~= row or cursor[2] ~= col then
    pcall(vim.api.nvim_win_set_cursor, state.input_win, { row, col })
  end
end

focus_input = function()
  if not valid_win(state.input_win) then
    return
  end

  vim.api.nvim_set_current_win(state.input_win)
  local lines = raw_input_lines()
  local line = math.max(1, #lines)
  render_input(lines, {
    line = line,
    col = #(lines[line] or ""),
  })
  vim.cmd("startinsert!")
end

focus_chat = function()
  if not valid_win(state.chat_win) then
    return
  end

  pcall(vim.cmd, "stopinsert")
  vim.api.nvim_set_current_win(state.chat_win)
  if valid_buf(state.chat_buf) then
    local line_count = math.max(1, vim.api.nvim_buf_line_count(state.chat_buf))
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { line_count, 0 })
  end
end

local function focus_adjacent_omniac_window()
  if vim.api.nvim_get_current_win() == state.input_win then
    focus_chat()
  else
    focus_input()
  end
end

local function complete_or_focus_adjacent_omniac_window()
  if vim.api.nvim_get_current_win() == state.input_win and complete_current_suggestion() then
    return
  end
  focus_adjacent_omniac_window()
end

local function enforce_input()
  if state.rendering_input or not valid_buf(state.input_buf) then
    return
  end

  clamp_input_cursor()
  local cursor = valid_win(state.input_win) and vim.api.nvim_win_get_cursor(state.input_win) or { 2, #INPUT_PROMPT }
  local lines = raw_input_lines()
  local input_cursor = logical_cursor_from_display(cursor)
  render_input(lines, {
    line = math.min(math.max(input_cursor.line, 1), #lines),
    col = input_cursor.col,
  })
end

local function insert_input_newline()
  if not valid_win(state.input_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local lines = raw_input_lines()
  local input_cursor = logical_cursor_from_display(cursor)
  local input_line = math.min(math.max(input_cursor.line, 1), #lines)
  local text = lines[input_line] or ""
  local col = math.min(math.max(input_cursor.col, 0), #text)
  lines[input_line] = text:sub(1, col)
  table.insert(lines, input_line + 1, text:sub(col + 1))
  render_input(lines, { line = input_line + 1, col = 0 })
  if lines[input_line + 1] == "" then
    vim.cmd("startinsert!")
  else
    vim.cmd("startinsert")
  end
end

local function delete_input_backwards()
  if not valid_win(state.input_win) then
    return ""
  end

  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  local lines = raw_input_lines()
  local input_cursor = logical_cursor_from_display(cursor)
  local input_line = math.min(math.max(input_cursor.line, 1), #lines)
  local text = lines[input_line] or ""
  local col = math.min(math.max(input_cursor.col, 0), #text)

  if col > 0 then
    local start_col = previous_char_start(text, col)
    lines[input_line] = text:sub(1, start_col) .. text:sub(col + 1)
    render_input(lines, { line = input_line, col = start_col })
  elseif input_line > 1 then
    local previous = lines[input_line - 1] or ""
    lines[input_line - 1] = previous .. text
    table.remove(lines, input_line)
    render_input(lines, { line = input_line - 1, col = #previous })
  else
    render_input(lines, { line = 1, col = 0 })
  end

  return ""
end

local function configure_window(win)
  vim.w[win].omniac_ui = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  vim.wo[win].list = false
end

reset_leftcol = function(win)
  if not valid_win(win) then
    return
  end

  pcall(vim.api.nvim_win_call, win, function()
    vim.fn.winrestview({ leftcol = 0 })
  end)
end

local function open_split_with_buffer(command, buf)
  vim.cmd(command .. " sbuffer " .. buf)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buflisted = false
  return win
end

update_command_window = function()
  if not valid_win(state.input_win) or not valid_buf(state.input_buf) then
    close_command_window()
    return
  end

  local kind, matches, trigger = current_suggestions()
  if kind == nil then
    close_command_window()
    return
  end

  if #matches == 0 then
    close_command_window()
    return
  end

  ensure_command_buffer()

  if not valid_win(state.command_win) then
    local row, col = input_bottom_position()
    state.command_win = vim.api.nvim_open_win(state.command_buf, false, {
      relative = "editor",
      width = target_width(),
      height = 1,
      row = row,
      col = col,
      style = "minimal",
      border = "none",
      focusable = false,
    })
    configure_window(state.command_win)
    vim.wo[state.command_win].wrap = false
    vim.wo[state.command_win].statusline = "%#OmniacStatus#%="
  end

  local target = target_width()
  local display_count = math.min(5, #matches)
  local row, col = input_bottom_position()
  pcall(vim.api.nvim_win_set_config, state.command_win, {
    relative = "editor",
    width = target,
    height = display_count,
    row = row,
    col = col,
  })
  pcall(vim.api.nvim_win_set_width, state.command_win, target)
  pcall(vim.api.nvim_win_set_height, state.command_win, display_count)

  local lines = {}
  local marks = {}
  for index = 1, display_count do
    local item = matches[index]
    local item_trigger = kind == "mention" and "@" or (item.trigger or trigger or "/")
    local hint = item.input and item.input.hint and (" " .. item.input.hint) or ""
    local description = item.description ~= "" and (" - " .. item.description) or ""
    local source = item.source == "omniac" and " client" or ""
    local line = fit(item_trigger .. item.name .. hint .. description .. source, target)
    table.insert(lines, line)
    table.insert(marks, {
      line = index,
      name_to = math.min(#item.name + 1, #line),
    })
  end
  vim.bo[state.command_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.command_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.command_buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    add_hl(state.command_buf, mark.line, 0, 1, "OmniacCommandMuted")
    add_hl(state.command_buf, mark.line, 1, mark.name_to + 1, "OmniacCommandName")
    add_hl(state.command_buf, mark.line, mark.name_to + 1, -1, "OmniacCommandText")
  end
  vim.bo[state.command_buf].modifiable = false
  vim.bo[state.command_buf].modified = false
end

resize_aux_windows = function()
  local target = target_width()
  if valid_win(state.chat_win) then
    pcall(vim.api.nvim_win_set_width, state.chat_win, target)
    local available = vim.o.lines - bottom_stack_height() - 3
    pcall(vim.api.nvim_win_set_height, state.chat_win, math.max(1, available))
  end
  if valid_win(state.status_win) then
    pcall(vim.api.nvim_win_set_width, state.status_win, target)
    pcall(vim.api.nvim_win_set_height, state.status_win, 1)
  end
  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_width, state.input_win, target)
    pcall(vim.api.nvim_win_set_height, state.input_win, input_display_height(raw_input_lines(), target))
    reset_leftcol(state.input_win)
  end
  if valid_win(state.command_win) then
    pcall(vim.api.nvim_win_set_width, state.command_win, target)
    pcall(vim.api.nvim_win_set_height, state.command_win, 5)
  end
  if valid_win(state.activity_win) then
    pcall(vim.api.nvim_win_set_width, state.activity_win, target)
    pcall(vim.api.nvim_win_set_height, state.activity_win, 1)
  end
end

local function relayout()
  if
    not (
      valid_win(state.chat_win)
      or valid_win(state.input_win)
      or valid_win(state.activity_win)
      or valid_win(state.status_win)
    )
  then
    return
  end

  if valid_win(state.chat_win) and not state.skip_user_width_capture then
    state.user_width = vim.api.nvim_win_get_width(state.chat_win)
  end
  state.skip_user_width_capture = false

  render_chat(state.config)
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
  if valid_win(state.command_win) then
    pcall(vim.api.nvim_win_set_width, state.command_win, target_width)
    pcall(vim.api.nvim_win_set_config, state.command_win, { width = target_width })
  end
  relayout()
  return true
end

local function schedule_relayout()
  if state.relayout_pending then
    return
  end

  state.relayout_pending = true
  vim.schedule(function()
    state.relayout_pending = false
    relayout()
  end)
end

function M.close()
  if valid_win(state.chat_win) then
    state.user_width = vim.api.nvim_win_get_width(state.chat_win)
  end
  stop_activity_timer()
  vim.api.nvim_clear_autocmds({ group = augroup, event = { "VimResized", "WinResized", "WinClosed" } })
  close_command_window()
  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_close, state.input_win, true)
  end
  if valid_win(state.activity_win) then
    pcall(vim.api.nvim_win_close, state.activity_win, true)
  end
  if valid_win(state.status_win) then
    pcall(vim.api.nvim_win_close, state.status_win, true)
  end
  if valid_win(state.chat_win) then
    pcall(vim.api.nvim_win_close, state.chat_win, true)
  end
end

function M.open(config, submit)
  setup_highlights()
  state.config = config or state.config
  state.submit = submit or state.submit

  if
    valid_win(state.chat_win)
    and valid_win(state.activity_win)
    and valid_win(state.input_win)
    and valid_win(state.status_win)
  then
    resize_aux_windows()
    focus_input()
    return state
  end

  if not valid_buf(state.chat_buf) then
    state.chat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.chat_buf].buftype = "nofile"
    vim.bo[state.chat_buf].bufhidden = "hide"
    vim.bo[state.chat_buf].swapfile = false
    vim.bo[state.chat_buf].buflisted = false
    vim.bo[state.chat_buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(state.chat_buf, "omniac")
  end

  if not valid_buf(state.input_buf) then
    state.input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.input_buf].buftype = "nofile"
    vim.bo[state.input_buf].bufhidden = "hide"
    vim.bo[state.input_buf].swapfile = false
    vim.bo[state.input_buf].buflisted = false
    vim.bo[state.input_buf].filetype = "omniac-input"
    vim.api.nvim_buf_set_name(state.input_buf, "omniac://input")
  end

  if not valid_buf(state.activity_buf) then
    state.activity_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.activity_buf].buftype = "nofile"
    vim.bo[state.activity_buf].bufhidden = "hide"
    vim.bo[state.activity_buf].swapfile = false
    vim.bo[state.activity_buf].buflisted = false
    vim.bo[state.activity_buf].filetype = "omniac-activity"
    vim.api.nvim_buf_set_name(state.activity_buf, "omniac://activity")
  end

  if not valid_buf(state.command_buf) then
    ensure_command_buffer()
  end

  if not valid_buf(state.status_buf) then
    state.status_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.status_buf].buftype = "nofile"
    vim.bo[state.status_buf].bufhidden = "hide"
    vim.bo[state.status_buf].swapfile = false
    vim.bo[state.status_buf].buflisted = false
    vim.bo[state.status_buf].filetype = "omniac-status"
    vim.api.nvim_buf_set_name(state.status_buf, "omniac://status")
  end

  state.chat_win = open_split_with_buffer("botright vertical", state.chat_buf)
  configure_window(state.chat_win)
  pcall(vim.api.nvim_win_set_width, state.chat_win, target_width())
  vim.wo[state.chat_win].winfixwidth = true
  vim.wo[state.chat_win].statusline = "%!v:lua.require'omniac.ui'.statusline()"

  state.activity_win = open_split_with_buffer("belowright", state.activity_buf)
  configure_window(state.activity_win)
  vim.wo[state.activity_win].winfixwidth = true
  vim.wo[state.activity_win].winfixheight = true
  pcall(vim.api.nvim_win_set_height, state.activity_win, 1)
  vim.wo[state.activity_win].statusline = "%#OmniacStatus#%="

  state.input_win = open_split_with_buffer("belowright", state.input_buf)
  configure_window(state.input_win)
  vim.wo[state.input_win].winfixwidth = true
  vim.wo[state.input_win].winfixheight = true
  vim.wo[state.input_win].wrap = true
  pcall(vim.api.nvim_win_set_height, state.input_win, 3)
  vim.wo[state.input_win].statusline = "%#OmniacStatus#%="

  state.status_win = open_split_with_buffer("belowright", state.status_buf)
  configure_window(state.status_win)
  vim.wo[state.status_win].winfixwidth = true
  vim.wo[state.status_win].winfixheight = true
  pcall(vim.api.nvim_win_set_height, state.status_win, 1)
  vim.wo[state.status_win].statusline = "%#OmniacStatus#%="
  resize_aux_windows()

  vim.keymap.set({ "n", "i" }, "<CR>", function()
    local text = input_text()
    local attachments = vim.deepcopy(state.input_attachments or {})
    if text == "" and #attachments == 0 then
      reset_input()
      focus_input()
      return
    end
    if mention_prefix() ~= nil and #attachments == 0 then
      complete_current_suggestion()
      focus_input()
      return
    end
    text = completed_suggestion_text(text)
    reset_input()
    clear_input_attachments()
    if state.submit then
      state.submit(text, attachments)
    end
  end, { buffer = state.input_buf, nowait = true, desc = "Send Omniac prompt" })

  vim.keymap.set("i", "<C-v>", function()
    local ok = add_clipboard_image()
    if ok then
      return ""
    end
    return "<C-r>+"
  end, {
    buffer = state.input_buf,
    expr = true,
    nowait = true,
    desc = "Paste Omniac clipboard image or text",
  })
  vim.keymap.set("n", "<C-v>", function()
    local ok = add_clipboard_image()
    if not ok then
      vim.cmd('normal! "+p')
    end
  end, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Paste Omniac clipboard image or text",
  })

  vim.keymap.set({ "n", "i" }, "<S-CR>", insert_input_newline, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Insert newline in Omniac prompt",
  })
  vim.keymap.set({ "n", "i" }, "<S-Enter>", insert_input_newline, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Insert newline in Omniac prompt",
  })
  vim.keymap.set("i", "<BS>", delete_input_backwards, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Delete Omniac input character",
  })
  vim.keymap.set("i", "<Esc>", function()
    if cancel_active_turn() then
      return ""
    end
    return "<Esc>"
  end, {
    buffer = state.input_buf,
    expr = true,
    nowait = true,
    desc = "Cancel active Omniac turn",
  })
  vim.keymap.set("n", "<Esc>", function()
    cancel_active_turn()
  end, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Cancel active Omniac turn",
  })

  local function toggle_tool_output()
    M.toggle_tool_output(state.config)
  end
  for _, buf in ipairs({ state.chat_buf, state.activity_buf, state.input_buf, state.status_buf }) do
    vim.keymap.set({ "n", "i" }, "<C-t>", toggle_tool_output, {
      buffer = buf,
      nowait = true,
      desc = "Toggle Omniac tool output",
    })
  end

  for _, buf in ipairs({ state.chat_buf, state.activity_buf, state.status_buf }) do
    vim.keymap.set("n", "i", focus_input, { buffer = buf, nowait = true, desc = "Focus Omniac input" })
  end

  vim.keymap.set({ "n", "i" }, "<Tab>", focus_adjacent_omniac_window, {
    buffer = state.chat_buf,
    nowait = true,
    desc = "Switch Omniac chat/input focus",
  })
  vim.keymap.set({ "n", "i" }, "<Tab>", focus_input, {
    buffer = state.activity_buf,
    nowait = true,
    desc = "Focus Omniac input",
  })
  vim.keymap.set({ "n", "i" }, "<Tab>", complete_or_focus_adjacent_omniac_window, {
    buffer = state.input_buf,
    nowait = true,
    desc = "Complete Omniac suggestion or switch focus",
  })
  for _, buf in ipairs({ state.chat_buf, state.input_buf }) do
    vim.keymap.set({ "n", "i" }, "<S-Tab>", focus_adjacent_omniac_window, {
      buffer = buf,
      nowait = true,
      desc = "Switch Omniac chat/input focus",
    })
  end
  vim.keymap.set({ "n", "i" }, "<S-Tab>", focus_chat, {
    buffer = state.activity_buf,
    nowait = true,
    desc = "Focus Omniac chat",
  })

  vim.keymap.set("n", "q", M.close, { buffer = state.input_buf, nowait = true, desc = "Close Omniac chat" })

  vim.api.nvim_clear_autocmds({ group = augroup, buffer = state.input_buf })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = augroup,
    buffer = state.input_buf,
    callback = enforce_input,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "InsertCharPre" }, {
    group = augroup,
    buffer = state.input_buf,
    callback = clamp_input_cursor,
  })
  vim.api.nvim_clear_autocmds({ group = augroup, event = { "VimResized", "WinResized", "WinClosed" } })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = augroup,
    callback = schedule_relayout,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if not win then
        return
      end

      if valid_win(win) and vim.w[win].omniac_ui then
        return
      end

      state.skip_user_width_capture = true
    end,
  })

  render_chat(state.config)
  render_activity()
  reset_input()
  render_status()
  sync_activity_timer()
  focus_input()
  return state
end

function M.set_status(status, config)
  state.status = status or "idle"
  if state.status ~= "working" then
    state.tool_activity = nil
    state.cancel_requested = false
  end
  if state.status == "working" or state.status ~= "connecting" then
    state.transient_activity = nil
  end
  render_chat(config)
  render_activity()
  render_status()
  sync_activity_timer()
end

function M.set_activity(text, config)
  state.transient_activity = text and text ~= "" and text or nil
  render_activity()
  render_status()
  sync_activity_timer()
end

function M.set_mode_cycle_handler(handler)
  state.mode_cycle_handler = handler
end

function M.set_cancel_handler(handler)
  state.cancel_handler = handler
end

function M.set_session_mode(mode)
  if type(mode) == "table" then
    state.session_mode = mode
  else
    state.session_mode = nil
  end
  render_status()
end

function M.set_tool_activity(params, config)
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
  render_activity()
end

function M.toggle_tool_output(config)
  for index = #state.messages, 1, -1 do
    local message = state.messages[index]
    if message and message.type == "tool_result" and #(split_lines(message.output or "")) > 4 then
      message.expanded = not message.expanded
      render_chat(config or state.config)
      focus_input()
      return true
    end
  end
  return false
end

function M.add_tool_result(params, config)
  params = params or {}
  local output = params.output
  if type(output) ~= "string" or output == "" then
    return
  end
  if not should_show_tool_result(params, config) then
    return
  end

  if state.streaming_message_index and state.messages[state.streaming_message_index] then
    state.messages[state.streaming_message_index].complete = true
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
  })
  if state.status == "working" and (params.status == "completed" or params.status == "failed") then
    state.tool_activity = nil
    render_activity()
  end
  request_chat_render(config, { immediate = true })
  focus_input()
end

function M.add_message(role, text, config, opts)
  opts = opts or {}
  if role == "Omniac" then
    clear_completed_tool_activity()
  end
  table.insert(state.messages, {
    role = role,
    text = text or "",
    stop_footer = opts.stop_footer,
  })
  if role ~= "Omniac" then
    state.streaming_message_index = nil
  end
  request_chat_render(config, { immediate = true })
  focus_input()
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
  request_chat_render(config, { immediate = true })
  focus_input()
  return index
end

function M.update_notice(index, text, config)
  if type(index) ~= "number" or not state.messages[index] then
    return
  end
  state.messages[index].text = text or state.messages[index].text or ""
  request_chat_render(config, { immediate = true })
  focus_input()
end

function M.append_response_chunk(text, config)
  if not text or text == "" then
    return
  end

  clear_completed_tool_activity()

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
      complete = false,
    })
    index = #state.messages
    state.streaming_message_index = index
  end

  state.messages[index].complete = false
  state.messages[index].text = (state.messages[index].text or "") .. text
  request_chat_render(config, { skip_markdown = true })
end

function M.complete_response(config, opts)
  opts = opts or {}
  local index = state.streaming_message_index
  if index and state.messages[index] and state.messages[index].role == "Omniac" then
    state.messages[index].complete = true
    state.messages[index].stop_footer = opts.stop_footer
    request_chat_render(config, { immediate = true })
  end
  state.streaming_message_index = nil
end

function M.submit(text, config, attachments)
  state.suppress_current_turn = false
  local display = text
  local summary = attachment_summary(attachments)
  if summary then
    display = display ~= "" and (display .. "\n[" .. summary .. "]") or ("[" .. summary .. "]")
  end
  M.add_message("You", display, config)
  M.set_status("working", config)
end

function M.handle_notification(message, config)
  local method = message and message.method
  local params = message and message.params or {}
  local turn_id = notification_turn_id(params)
  local current_turn_id = state.active_turn_id

  if turn_id and current_turn_id and turn_id ~= current_turn_id then
    if
      method == "omniac/response"
      or method == "omniac/response_chunk"
      or method == "omniac/response_completed"
      or method == "omniac/prompt_cancelled"
    then
      return
    end
  end

  if method == "_transport/thread_started" or method == "omniac/session_started" then
    M.set_status("ready", config)
    return
  end

  if method == "thread/started" or method == "turn/started" or method == "omniac/prompt_started" then
    state.streaming_message_index = nil
    state.tool_activity = nil
    state.cancel_requested = false
    state.suppress_current_turn = false
    state.active_turn_id = turn_id
    M.set_status("working", config)
    return
  end

  if method == "omniac/prompt_cancelled" then
    state.cancel_requested = false
    state.active_turn_id = turn_id or state.active_turn_id
    M.set_status("ready", config)
    M.set_activity("Cancelled current turn.", config)
    return
  end

  if method == "omniac/prompt_cancel_failed" then
    state.cancel_requested = false
    state.suppress_current_turn = false
    M.set_activity(params.message or "Cancel failed.", config)
    return
  end

  if method == "turn/completed" then
    M.set_status("ready", config)
    return
  end

  if
    state.suppress_current_turn
    and (
      method == "omniac/response"
      or method == "omniac/response_chunk"
      or method == "omniac/tool_activity"
      or method == "omniac/tool_result"
    )
  then
    return
  end

  if method == "omniac/response" then
    local reason = normalized_stop_reason(params)
    M.add_message("Omniac", params.text or "", config, {
      stop_footer = stop_reason_footer(reason),
    })
    state.streaming_message_index = nil
    M.set_status("ready", config)
    local activity = stop_reason_activity(reason, config)
    if activity then
      M.set_activity(activity, config)
    end
    return
  end

  if method == "omniac/response_chunk" then
    M.append_response_chunk(params.text or "", config)
    return
  end

  if method == "omniac/tool_activity" then
    M.set_tool_activity(params, config)
    return
  end

  if method == "omniac/tool_result" then
    M.add_tool_result(params, config)
    return
  end

  if method == "omniac/available_commands_update" then
    M.set_available_commands(params.availableCommands or params.available_commands or {})
    return
  end

  if method == "omniac/session_mode_update" then
    M.set_session_mode(params)
    return
  end

  if method == "omniac/response_completed" then
    local reason = normalized_stop_reason(params)
    local suppress_stop_ui = state.suppress_current_turn
    M.complete_response(config, {
      stop_footer = suppress_stop_ui and nil or stop_reason_footer(reason),
    })
    M.set_status("ready", config)
    if not suppress_stop_ui then
      local activity = stop_reason_activity(reason, config)
      if activity then
        M.set_activity(activity, config)
      end
    end
    state.active_turn_id = turn_id or state.active_turn_id
    return
  end

  if method == "omniac/error" or method == "turn/error" or method == "_transport/error" then
    M.add_message("Error", vim.inspect(params), config)
    M.set_status("error", config)
  end
end

function M.set_available_commands(commands)
  state.available_commands = type(commands) == "table" and commands or {}
  if update_command_window then
    update_command_window()
  end
end

function M.is_open()
  return valid_win(state.chat_win)
    and valid_win(state.activity_win)
    and valid_win(state.input_win)
    and valid_win(state.status_win)
end

function M.statusline()
  local text = string.format(" %s | %s | %s ", "Omniac", state.status, agent_name(state.config))
  return "%#OmniacStatusMode#" .. text .. "%#OmniacStatus#%="
end

return M
