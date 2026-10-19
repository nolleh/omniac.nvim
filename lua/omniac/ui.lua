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
local status_view = require("omniac.ui.status")
local text = require("omniac.ui.text")

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
local MASCOT_GAZE_DELAY_MS = 180
local MASCOT_BLINK_FRAME_MS = 100
local MASCOT_WORK_FRAME_MS = 650
local MASCOT_IDLE_DELAY_MS = 11000
local MASCOT_IDLE_GESTURE_MS = 350
local MASCOT_WALK_STEP_MS = 380
local MASCOT_PET_DURATION_MS = 320
local MASCOT_PET_WINDOW_MS = 2400
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

local center = text.center
local fit = text.fit
local box_line = text.box_line
local boxed_text = text.boxed_text
local setup_highlights = highlights.setup

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
local attachment_summary
local resize_aux_windows

local function stop_tool_activity_timer()
  if state.tool_activity_timer then
    state.tool_activity_timer:stop()
    state.tool_activity_timer:close()
    state.tool_activity_timer = nil
  end
end

local function is_terminal_tool_activity()
  return state.tool_activity and (state.tool_activity:match("^Completed ") or state.tool_activity:match("^Failed "))
end

local function schedule_tool_activity_clear()
  stop_tool_activity_timer()

  local uv = vim.uv or vim.loop
  state.tool_activity_timer = uv.new_timer()
  state.tool_activity_timer:start(
    500,
    0,
    vim.schedule_wrap(function()
      state.tool_activity_timer = nil
      if state.status == "working" and is_terminal_tool_activity() then
        state.tool_activity = nil
        render_activity()
      end
    end)
  )
end

local function clear_completed_tool_activity()
  if state.status == "working" and is_terminal_tool_activity() then
    stop_tool_activity_timer()
    state.tool_activity = nil
    render_activity()
  end
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

  local sprite_width = 10
  local sprite_height = 12
  local sprite = {}
  for row = 1, sprite_height do
    sprite[row] = {}
    for column = 1, sprite_width do
      sprite[row][column] = " "
    end
  end

  local function fill_rect(left, top, right, bottom, color)
    for row = top, bottom do
      for column = left, right do
        local shifted_row = row - state.mascot_hop
        if shifted_row >= 1 and shifted_row <= sprite_height then
          sprite[shifted_row][column] = color
        end
      end
    end
  end

  -- Keep the full robot close to the reference's tall 5:6 silhouette.
  fill_rect(5 + state.mascot_antenna_offset, 1, 6 + state.mascot_antenna_offset, 1, "mint")
  fill_rect(5, 2, 6, 2, "coral")
  fill_rect(3, 3, 8, 3, "coral")
  fill_rect(2, 4, 9, 7, "coral")
  fill_rect(1, 5, 1, 6, "mint")
  fill_rect(10, 5, 10, 6, "mint")
  local eye_offset = state.mascot_gaze == "left" and -1 or state.mascot_gaze == "right" and 1 or 0
  if state.mascot_eye_height > 0 then
    local eye_top = 7 - state.mascot_eye_height + state.mascot_vertical_gaze
    local eye_bottom = 6 + state.mascot_vertical_gaze
    fill_rect(4 + eye_offset, eye_top, 4 + eye_offset, eye_bottom, " ")
    fill_rect(7 + eye_offset, eye_top, 7 + eye_offset, eye_bottom, " ")
  end
  fill_rect(3, 8, 8, 8, "coral")
  fill_rect(3, 10, 8, 11, "coral")
  fill_rect(2, state.mascot_arm_frame == 1 and 10 or 11, 2, state.mascot_arm_frame == 1 and 10 or 11, "coral")
  fill_rect(9, state.mascot_arm_frame == 2 and 10 or 11, 9, state.mascot_arm_frame == 2 and 10 or 11, "coral")
  fill_rect(5, 10, 6, 11, "mint")
  fill_rect(4, state.mascot_walk_frame == 1 and 11 or 12, 4, state.mascot_walk_frame == 1 and 11 or 12, "coral")
  fill_rect(7, state.mascot_walk_frame == 2 and 11 or 12, 7, state.mascot_walk_frame == 2 and 11 or 12, "coral")

  local function pixel_glyph(top, bottom)
    if top == " " and bottom == " " then
      return " ", nil
    end
    if top == bottom then
      return "█", top == "mint" and "OmniacGraphicShade" or nil
    end
    if top == " " then
      return "▄", bottom == "mint" and "OmniacGraphicShade" or nil
    end
    if bottom == " " then
      return "▀", top == "mint" and "OmniacGraphicShade" or nil
    end
    return "▀", top == "mint" and "OmniacGraphicMintOverCoral" or "OmniacGraphicCoralOverMint"
  end

  state.mascot_first_line = #lines + 1
  for row = 1, sprite_height, 2 do
    local glyphs = {}
    local groups = {}
    for column = 1, sprite_width do
      glyphs[column], groups[column] = pixel_glyph(sprite[row][column], sprite[row + 1][column])
    end

    local line = table.concat(glyphs)
    local inner_width = box_width - 2
    local left_padding = math.floor((inner_width - vim.fn.strdisplaywidth(line)) / 2) + state.mascot_x
    add_line(
      lines,
      marks,
      "│"
        .. string.rep(" ", left_padding)
        .. line
        .. string.rep(" ", inner_width - left_padding - sprite_width)
        .. "│",
      "OmniacGraphic"
    )
    local byte_offset = #"│" + left_padding
    local run_group
    local run_start
    for column = 1, sprite_width do
      local group = groups[column]
      if group ~= run_group then
        if run_group then
          add_mark(marks, #lines, run_start, byte_offset, run_group)
        end
        run_group = group
        run_start = group and byte_offset or nil
      end
      byte_offset = byte_offset + #glyphs[column]
    end
    if run_group then
      add_mark(marks, #lines, run_start, byte_offset, run_group)
    end
  end
  state.mascot_last_line = #lines

  add_boxed_line(lines, marks, "O M N I A C", box_width, "OmniacWordmark")

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

local function pin_card_view()
  if valid_win(state.card_win) then
    pcall(vim.api.nvim_win_call, state.card_win, function()
      vim.fn.winrestview({ topline = 1, leftcol = 0 })
    end)
  end
end

local function render_card()
  if not state.card_pinned or not valid_buf(state.card_buf) then
    return
  end
  local lines = {}
  local marks = {}
  local card_width = valid_win(state.card_win) and vim.api.nvim_win_get_width(state.card_win) or target_width()
  header(lines, marks, card_width)
  vim.bo[state.card_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.card_buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.card_buf, 0, -1, false, lines)
  vim.bo[state.card_buf].modifiable = false
  vim.bo[state.card_buf].modified = false
  for _, mark in ipairs(marks) do
    add_hl(state.card_buf, mark.line, mark.from, mark.to, mark.group)
  end
  pin_card_view()
end

local function render_mascot()
  if state.card_pinned then
    render_card()
  else
    render_chat(state.config, { skip_markdown = true })
  end
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

local function mascot_visible()
  if state.card_pinned then
    if
      not valid_win(state.card_win)
      or not valid_buf(state.card_buf)
      or vim.api.nvim_win_get_buf(state.card_win) ~= state.card_buf
      or vim.api.nvim_win_get_tabpage(state.card_win) ~= vim.api.nvim_get_current_tabpage()
    then
      return false
    end
    local top = vim.fn.line("w0", state.card_win)
    return top <= state.mascot_last_line
      and top + vim.api.nvim_win_get_height(state.card_win) - 1 >= state.mascot_first_line
  end
  if
    not valid_win(state.chat_win)
    or not valid_buf(state.chat_buf)
    or vim.api.nvim_win_get_buf(state.chat_win) ~= state.chat_buf
    or not state.mascot_first_line
  then
    return false
  end
  local top = vim.fn.line("w0", state.chat_win)
  return top <= state.mascot_last_line
    and top + vim.api.nvim_win_get_height(state.chat_win) - 1 >= state.mascot_first_line
end

local function restart_mascot_actions()
  state.mascot_action_generation = state.mascot_action_generation + 1
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  state.mascot_interacting = false
  local generation = state.mascot_action_generation
  state.mascot_arm_frame = 0
  state.mascot_antenna_offset = 0
  state.mascot_x = 0
  state.mascot_hop = 0
  state.mascot_walk_frame = 0
  if mascot_visible() then
    render_mascot()
  end
  if ((state.config or {}).ui or {}).mascot_motion == false then
    return
  end
  if not valid_win(state.chat_win) then
    return
  end

  if state.status == "working" then
    local frames = { 1, 2, 1, 2, 0, 0 }
    local sway = { 0, 1, 0, -1, 0, 0 }
    local frame = 0
    local function tick()
      vim.defer_fn(function()
        if generation ~= state.mascot_action_generation then
          return
        end
        frame = frame % #frames + 1
        if not state.mascot_interacting then
          state.mascot_arm_frame = frames[frame]
          state.mascot_x = sway[frame]
          if mascot_visible() then
            render_mascot()
          end
        end
        tick()
      end, MASCOT_WORK_FRAME_MS)
    end
    tick()
  elseif state.status == "ready" then
    local function idle()
      vim.defer_fn(function()
        if generation ~= state.mascot_action_generation then
          return
        end
        state.mascot_antenna_offset = state.mascot_idle_direction
        state.mascot_idle_direction = -state.mascot_idle_direction
        if mascot_visible() then
          render_mascot()
        end
        vim.defer_fn(function()
          if generation ~= state.mascot_action_generation then
            return
          end
          state.mascot_antenna_offset = 0
          if mascot_visible() then
            render_mascot()
          end
          vim.defer_fn(function()
            if generation ~= state.mascot_action_generation then
              return
            end
            local direction = state.mascot_walk_direction
            state.mascot_walk_direction = -direction
            local steps = { 1, 2, 3, 2, 1, 0 }
            local function walk(index)
              if generation ~= state.mascot_action_generation then
                return
              end
              if state.mascot_interacting or vim.uv.now() - state.mascot_last_pet_at < MASCOT_PET_WINDOW_MS then
                state.mascot_walk_frame = 0
                idle()
                return
              end
              state.mascot_x = steps[index] * direction
              state.mascot_walk_frame = index == #steps and 0 or index % 2 + 1
              if mascot_visible() then
                render_mascot()
              end
              if index == #steps then
                idle()
              else
                vim.defer_fn(function()
                  walk(index + 1)
                end, MASCOT_WALK_STEP_MS)
              end
            end
            walk(1)
          end, 1800)
        end, MASCOT_IDLE_GESTURE_MS)
      end, MASCOT_IDLE_DELAY_MS)
    end
    idle()
  end
end

local function advance_mascot_gaze()
  if state.mascot_gaze_pending or state.mascot_reacting then
    return
  end
  state.mascot_gaze_pending = true
  local generation = state.mascot_generation
  vim.defer_fn(function()
    if generation ~= state.mascot_generation then
      return
    end
    state.mascot_gaze_pending = false
    if state.mascot_reacting or not mascot_visible() or state.mascot_gaze == state.mascot_target then
      return
    end

    local target = state.mascot_target
    if state.mascot_gaze ~= "center" and target ~= "center" then
      state.mascot_gaze = "center"
    else
      state.mascot_gaze = target
    end
    render_mascot()
    if state.mascot_gaze ~= state.mascot_target then
      advance_mascot_gaze()
    end
  end, MASCOT_GAZE_DELAY_MS)
end

local schedule_mascot_gaze

local function react_to_omniac_focus()
  if not mascot_visible() then
    return
  end
  state.mascot_reaction_id = state.mascot_reaction_id + 1
  local reaction_id = state.mascot_reaction_id
  local generation = state.mascot_generation
  state.mascot_reacting = true
  state.mascot_eye_height = 1
  vim.schedule(function()
    if generation == state.mascot_generation and reaction_id == state.mascot_reaction_id and mascot_visible() then
      render_mascot()
    end
  end)
  for frame = 2, 4 do
    vim.defer_fn(function()
      if generation == state.mascot_generation and reaction_id == state.mascot_reaction_id then
        state.mascot_eye_height = frame == 2 and 0 or frame == 3 and 1 or 2
        if frame == 4 then
          state.mascot_reacting = false
        end
        if mascot_visible() then
          render_mascot()
        end
        if frame == 4 then
          schedule_mascot_gaze({ event = "CursorMoved" })
          if not state.mascot_in_omniac then
            advance_mascot_gaze()
          end
        end
      end
    end, (frame - 1) * MASCOT_BLINK_FRAME_MS)
  end
end

local function finish_mascot_interaction()
  state.mascot_interacting = false
  state.mascot_arm_frame = state.status == "working" and 1 or 0
  if mascot_visible() then
    render_mascot()
  end
end

local function react_to_card_pet(direction)
  if ((state.config or {}).ui or {}).mascot_motion == false then
    return
  end
  local now = vim.uv.now()
  state.mascot_pet_count = now - state.mascot_last_pet_at <= MASCOT_PET_WINDOW_MS and state.mascot_pet_count + 1 or 1
  state.mascot_last_pet_at = now
  local flee = state.mascot_pet_count >= 3
  if flee then
    state.mascot_pet_count = 0
    local target = direction > 0 and 3 or -3
    state.mascot_x = state.mascot_x == target and -target or target
  end
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  local generation = state.mascot_interaction_generation
  state.mascot_interacting = true
  state.mascot_hop = 1
  state.mascot_walk_frame = 0
  state.mascot_arm_frame = direction > 0 and 1 or 2
  render_mascot()
  vim.defer_fn(function()
    if generation ~= state.mascot_interaction_generation then
      return
    end
    state.mascot_hop = 0
    if not flee then
      state.mascot_x = 0
      finish_mascot_interaction()
    else
      state.mascot_arm_frame = 0
      if mascot_visible() then
        render_mascot()
      end
    end
    if flee then
      vim.defer_fn(function()
        if generation ~= state.mascot_interaction_generation then
          return
        end
        state.mascot_x = 0
        finish_mascot_interaction()
      end, 800)
    end
  end, MASCOT_PET_DURATION_MS)
end

local function react_to_card_vertical(direction)
  if ((state.config or {}).ui or {}).mascot_motion == false then
    return
  end
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  local generation = state.mascot_interaction_generation
  state.mascot_interacting = true
  state.mascot_hop = 1
  state.mascot_arm_frame = direction > 0 and 2 or 1
  render_mascot()
  vim.defer_fn(function()
    if generation ~= state.mascot_interaction_generation then
      return
    end
    state.mascot_hop = 0
    finish_mascot_interaction()
  end, 180)
end

local function track_card_cursor(event)
  if not state.card_pinned or not valid_win(state.card_win) or vim.api.nvim_get_current_win() ~= state.card_win then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.card_win)[1]
  local column = vim.fn.virtcol(".")
  local previous = state.mascot_card_cursor
  state.mascot_card_cursor = { row = row, column = column }
  if event ~= "WinEnter" and previous then
    local width = vim.api.nvim_win_get_width(state.card_win)
    local sprite_left = math.floor((width - 2 - 10) / 2) + state.mascot_x + 2
    if
      row >= state.mascot_first_line
      and row <= state.mascot_last_line
      and column >= sprite_left - 1
      and column <= sprite_left + 10
    then
      if previous.row == row and previous.column ~= column then
        react_to_card_pet(column - previous.column)
      elseif previous.row ~= row then
        react_to_card_vertical(row - previous.row)
      end
    end
  end
  return row, column
end

schedule_mascot_gaze = function(args)
  local win = vim.api.nvim_get_current_win()
  local card_row, card_column = track_card_cursor(args.event)
  if win ~= state.card_win then
    state.mascot_card_cursor = nil
    if state.mascot_vertical_gaze ~= 0 then
      state.mascot_vertical_gaze = 0
      if mascot_visible() then
        render_mascot()
      end
    end
  end
  if ((state.config or {}).ui or {}).mascot_follow_cursor == false then
    return
  end
  local in_omniac = win == state.card_win
    or win == state.chat_win
    or win == state.input_win
    or win == state.activity_win
    or win == state.status_win
  if args.event == "WinEnter" then
    if in_omniac and not state.mascot_in_omniac then
      react_to_omniac_focus()
    end
    state.mascot_in_omniac = in_omniac
  end
  if not in_omniac then
    if args.event == "WinEnter" and mascot_visible() then
      state.mascot_target = "center"
      advance_mascot_gaze()
    end
    return
  end
  if not mascot_visible() then
    return
  end

  if win == state.card_win and card_row then
    local vertical = card_row < state.mascot_first_line + 2 and -1 or card_row > state.mascot_last_line - 2 and 1 or 0
    if vertical ~= state.mascot_vertical_gaze then
      state.mascot_vertical_gaze = vertical
      render_mascot()
    end
    local center = math.floor(vim.api.nvim_win_get_width(state.card_win) / 2) + state.mascot_x
    state.mascot_target = card_column < center - 2 and "left" or card_column > center + 2 and "right" or "center"
    advance_mascot_gaze()
    return
  end
  if win ~= state.chat_win and win ~= state.input_win then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local ok, position = pcall(vim.fn.screenpos, win, cursor[1], cursor[2] + 1)
  if not ok or not position or position.col == 0 then
    return
  end
  local window_left = vim.fn.win_screenpos(state.chat_win)[2]
  local fraction = (position.col - window_left) / math.max(1, vim.api.nvim_win_get_width(state.chat_win) - 1)
  local target = fraction < 1 / 3 and "left" or fraction > 2 / 3 and "right" or "center"
  if target == state.mascot_gaze and not state.mascot_gaze_pending then
    return
  end

  state.mascot_target = target
  advance_mascot_gaze()
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
  stop_tool_activity_timer()
  state.mascot_action_generation = state.mascot_action_generation + 1
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  state.mascot_interacting = false
  state.mascot_arm_frame = 0
  state.mascot_antenna_offset = 0
  state.mascot_x = 0
  state.mascot_hop = 0
  state.mascot_walk_frame = 0
  state.mascot_vertical_gaze = 0
  state.mascot_card_cursor = nil
  state.mascot_pet_count = 0
  state.mascot_generation = state.mascot_generation + 1
  state.mascot_gaze_pending = false
  state.mascot_gaze = "center"
  state.mascot_target = "center"
  state.mascot_in_omniac = false
  state.mascot_reacting = false
  state.mascot_eye_height = 2
  state.mascot_reaction_id = state.mascot_reaction_id + 1
  vim.api.nvim_clear_autocmds({ group = mascot_augroup })
  vim.on_key(nil, mascot_key_ns)
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
  restart_mascot_actions()
  state.mascot_in_omniac = true
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter" }, {
    group = mascot_augroup,
    callback = schedule_mascot_gaze,
  })
  vim.on_key(function()
    if vim.api.nvim_get_current_win() == state.card_win then
      vim.schedule(function()
        if valid_win(state.card_win) and vim.api.nvim_get_current_win() == state.card_win then
          schedule_mascot_gaze({ event = "CursorMoved" })
        end
      end)
    end
  end, mascot_key_ns)
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
    stop_tool_activity_timer()
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
  if type(mode) == "table" then
    state.session_mode = mode
  else
    state.session_mode = nil
  end
  render_status()
end

function M.set_session_model(model)
  if type(model) == "table" then
    state.session_model = model
  else
    state.session_model = nil
  end
  render_status()
end

function M.set_session_config(options)
  local config = {}
  for _, option in ipairs(options or {}) do
    if type(option) == "table" and type(option.id) == "string" then
      config[option.id] = option.currentValue or option.current_value
    end
  end
  state.session_config = config
  render_status()
end

function M.set_session_usage(usage)
  local used = type(usage) == "table" and tonumber(usage.used) or nil
  local size = type(usage) == "table" and tonumber(usage.size) or nil
  if used and size and used >= 0 and size > 0 then
    state.session_usage = {
      used = used,
      size = size,
      cost = usage.cost,
    }
  else
    state.session_usage = nil
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
  if status == "completed" or status == "failed" then
    schedule_tool_activity_clear()
  else
    stop_tool_activity_timer()
  end
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
  request_chat_render(config, { immediate = true, follow = true })
  focus_input_if_active()
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
  local method = message and message.method
  local params = message and message.params or {}
  local turn_id = notification_turn_id(params)
  local current_turn_id = state.active_turn_id

  if turn_id and current_turn_id and turn_id ~= current_turn_id then
    if
      method == "omniac/response"
      or method == "omniac/response_chunk"
      or method == "omniac/response_completed"
      or method == "omniac/thought_activity"
      or method == "omniac/prompt_cancelled"
    then
      return
    end
  end

  if method == "omniac/session_started" then
    if params.clearChat then
      M.clear_conversation(config)
    end
    M.set_status("ready", config)
    return
  end

  if method == "omniac/prompt_started" then
    state.streaming_message_index = nil
    state.tool_activity = nil
    state.thought_activity = nil
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

  if
    state.suppress_current_turn
    and (
      method == "omniac/response"
      or method == "omniac/response_chunk"
      or method == "omniac/tool_activity"
      or method == "omniac/thought_activity"
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

  if method == "omniac/thought_activity" then
    if state.status == "working" and type(params.text) == "string" and params.text ~= "" then
      state.thought_activity = params.text
      render_activity()
    end
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

  if method == "omniac/session_model_update" then
    M.set_session_model(params)
    return
  end

  if method == "omniac/session_config_update" then
    M.set_session_config(params.configOptions or params.config_options)
    return
  end

  if method == "omniac/usage_update" then
    M.set_session_usage(params)
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

  if method == "omniac/error" then
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
    and (not state.card_pinned or valid_win(state.card_win))
end

function M.statusline()
  local text = string.format(" %s | %s | %s ", "Omniac", state.status, agent_name(state.config))
  return "%#OmniacStatusMode#" .. text .. "%#OmniacStatus#%="
end

return M
