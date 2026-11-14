local M = {}
local plan = require("omniac.ui.plan")
local ansi = require("omniac.ui.ansi")

local frames = { "Working", "Working.", "Working..", "Working..." }
local groups = { "OmniacWorking1", "OmniacWorking2", "OmniacWorking3", "OmniacWorking4" }

local function activity_text(state)
  if state.failure_action then
    return "Prompt failed. Agent may have processed it.\n[r] Resend  [e] Restore input  [d] Dismiss"
  end
  if state.transient_activity then
    return state.transient_activity
  end
  if state.status == "working" then
    local summary = plan.activity(state)
    if summary then
      return summary .. (state.tool_activity and ("\n" .. state.tool_activity) or "")
    end
  end
  if state.status == "working" and state.tool_activity then
    return state.tool_activity
  end
  if state.status == "working" and state.thought_activity then
    return state.thought_activity
  end
  if state.status == "working" then
    return frames[state.activity_frame]
  end
  if state.status == "connecting" then
    return "Connecting..."
  end
  return ""
end

function M.render(opts)
  local state = opts.state
  if not opts.valid_buf(state.activity_buf) then
    return false
  end

  local win_width = opts.valid_win(state.activity_win) and vim.api.nvim_win_get_width(state.activity_win)
    or opts.width()
  local value = activity_text(state)
  local plain, colors = ansi.parse(value)
  local lines = { "" }
  local color_marks = {}
  if value ~= "" then
    local inner_width = math.max(1, win_width - 4)
    local source_lines = opts.split_lines(plain)
    local truncated = #source_lines > opts.max_lines
    lines = {}
    local offset = 0
    for index = 1, math.min(#source_lines, opts.max_lines) do
      local source = source_lines[index]
      if truncated and index == opts.max_lines then
        source = source .. "…"
      end
      local fitted = opts.fit(source, inner_width)
      table.insert(lines, "  " .. fitted .. "  ")
      local retained = ansi.retained(source_lines[index], fitted)
      vim.list_extend(color_marks, ansi.marks(colors, offset, retained, index, 2))
      offset = offset + #source_lines[index] + 1
    end
  end

  local activity_height = math.max(1, #lines)
  local height_changed = state.activity_height ~= activity_height
  state.activity_height = activity_height

  vim.bo[state.activity_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.activity_buf, opts.namespace, 0, -1)
  vim.api.nvim_buf_set_lines(state.activity_buf, 0, -1, false, lines)
  vim.bo[state.activity_buf].modifiable = false
  vim.bo[state.activity_buf].modified = false

  if value ~= "" then
    for index = 1, #lines do
      opts.add_hl(state.activity_buf, index, 0, -1, groups[state.activity_frame])
    end
    for _, mark in ipairs(color_marks) do
      opts.add_hl(state.activity_buf, mark.line, mark.from, mark.to, mark.group)
    end
    if state.failure_action or state.change_summary then
      for index, line in ipairs(lines) do
        local from = 1
        while true do
          local shortcut_start, shortcut_end = line:find("%[[%a]%]", from)
          if not shortcut_start then
            break
          end
          opts.add_hl(state.activity_buf, index, shortcut_start - 1, shortcut_end, "OmniacShortcut")
          from = shortcut_end + 1
        end
      end
    end
  end
  return height_changed
end

return M
