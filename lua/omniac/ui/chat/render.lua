local text = require("omniac.ui.text")
local tool_result = require("omniac.ui.chat.tool_result")
local ansi = require("omniac.ui.ansi")

local M = {}

function M.invalidate(state, index)
  state.chat_dirty_from = math.min(state.chat_dirty_from or index, index)
end

local function add_line(lines, marks, value, group)
  table.insert(lines, value)
  if group then
    table.insert(marks, { line = #lines, from = 0, to = -1, group = group })
  end
end

local function add_mark(marks, line, from, to, group)
  table.insert(marks, { line = line, from = from, to = to, group = group })
end

local function add_boxed_line(lines, marks, value, size, group)
  local line = text.boxed_text(value, size)
  table.insert(lines, line)
  local lnum = #lines
  local border_width = #"│"
  add_mark(marks, lnum, 0, border_width, "OmniacBorder")
  add_mark(marks, lnum, #line - border_width, -1, "OmniacBorder")
  if group then
    add_mark(marks, lnum, border_width, #line - border_width, group)
  end
end

local function materialize_message_text(message)
  if message.pending_chunks and #message.pending_chunks > 0 then
    message.text = (message.text or "") .. table.concat(message.pending_chunks)
    message.pending_chunks = {}
  end
  return message.text or ""
end

local function unwrap_markdown_fences(value)
  local result = {}
  local in_markdown_fence = false
  for line in (tostring(value or "") .. "\n"):gmatch("(.-)\n") do
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

local function chat_message_lines(line, width)
  local value = tostring(line or "")
  if
    value == ""
    or value:match("^%s*|")
    or value:match("^%s*```")
    or value:match("^%s*~~~")
    or value:match("^%s*%-%-%-+%s*$")
  then
    return { line }, 0
  end

  local result = {}
  for _, wrapped_line in ipairs(text.wrapped(line, math.max(1, width - 4))) do
    table.insert(result, "  " .. text.fit(wrapped_line, math.max(1, width - 4)) .. "  ")
  end
  return result, 2
end

function M.build(opts)
  local state = opts.state
  local width = opts.width
  local text_width = math.max(28, width - 6)
  local lines = {}
  local marks = {}
  local permission_marks = {}
  local markdown_excluded_ranges = {}
  local message_ranges = {}

  local function add_message_separator()
    add_line(
      lines,
      marks,
      "  " .. text.fit(string.rep("─", math.max(0, width - 4)), width - 4) .. "  ",
      "OmniacMuted"
    )
  end

  if not state.card_pinned and #state.messages == 0 then
    opts.header(lines, marks, width)
    add_line(lines, marks, "", nil)
  elseif not state.card_pinned then
    state.mascot_first_line = nil
    state.mascot_last_line = nil
  end

  if #state.messages == 0 then
    add_line(lines, marks, text.box_line("╭", "─", "╮", width), "OmniacBorder")
    add_boxed_line(
      lines,
      marks,
      "Agent: " .. opts.agent_name(state.config) .. "  •  Status: " .. state.status,
      width,
      "OmniacAccent"
    )
    add_boxed_line(lines, marks, "cwd: " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"), width, "OmniacMuted")
    add_line(lines, marks, text.box_line("╰", "─", "╯", width), "OmniacBorder")
  else
    for index = opts.start_index or 1, #state.messages do
      local message = state.messages[index]
      local value = materialize_message_text(message)
      local message_start = #lines + 1
      local group = message.role == "You" and "OmniacUserBubble" or nil
      if message.role == "Error" then
        group = "OmniacError"
      end

      if message.role == "You" then
        local range_start = #lines
        for _, line in ipairs(text.wrapped(value, text_width)) do
          add_line(lines, marks, "  " .. text.fit(line, width - 4) .. "  ", group)
        end
        if #lines > range_start then
          table.insert(markdown_excluded_ranges, { from = range_start, to = #lines })
        end
        add_message_separator()
      elseif message.type == "tool_result" then
        local offset = #lines
        local rendered = tool_result.render(message, width)
        vim.list_extend(lines, rendered.lines)
        for _, mark in ipairs(rendered.marks) do
          add_mark(marks, offset + mark.line, mark.from, mark.to, mark.group)
        end
        -- Commands and output are literal text, not chat Markdown. In
        -- particular, heredocs and fences must not hide or restyle the preview.
        table.insert(markdown_excluded_ranges, { from = offset, to = #lines })
      else
        local message_text, colors = ansi.parse(unwrap_markdown_fences(value))
        local source_offset = 0
        for _, line in ipairs(text.split_lines(message_text)) do
          local display_lines, padding = chat_message_lines(line, width)
          local consumed = 0
          for _, display_line in ipairs(display_lines) do
            add_line(lines, marks, display_line, group)
            local length = math.min(#line - consumed, #display_line - padding * 2)
            vim.list_extend(marks, ansi.marks(colors, source_offset + consumed, length, #lines, padding))
            consumed = consumed + length
          end
          source_offset = source_offset + #line + 1
        end
        if message.stop_footer and message.stop_footer ~= "" then
          add_line(lines, marks, "  " .. text.fit(message.stop_footer, width - 4) .. "  ", "OmniacMuted")
        end
        local complete = message.complete or (message.complete == nil and message.role == "Omniac" and not message.type)
        if complete then
          add_message_separator()
        end
      end

      if message.role == "Permission" then
        local decision = value:match("\n(Decision: [^\n]+)")
        local label = "● Pending"
        local permission_group = "OmniacPermissionPending"
        if message.permission_status == "rejected" then
          label = "✕ Rejected"
          permission_group = "OmniacPermissionRejected"
        elseif message.permission_status == "adjusted" then
          label = "◆ Adjusted"
          permission_group = "OmniacPermissionApproved"
        elseif message.permission_status == "approved" then
          label = "✓ Approved"
          permission_group = "OmniacPermissionApproved"
        end
        if decision then
          for row = message_start, #lines do
            if lines[row]:find(decision, 1, true) then
              add_mark(marks, row, 0, -1, permission_group)
              break
            end
          end
        end
        table.insert(permission_marks, { line = message_start, label = label, group = permission_group })
        add_mark(marks, message_start, 0, -1, "OmniacAccent")
      end
      add_line(lines, marks, "", nil)
      message_ranges[index] = { from = message_start - 1, to = #lines }
    end
  end

  return {
    lines = lines,
    marks = marks,
    permission_marks = permission_marks,
    markdown_excluded_ranges = markdown_excluded_ranges,
    message_ranges = message_ranges,
  }
end

return M
