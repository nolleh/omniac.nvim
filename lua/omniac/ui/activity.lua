local M = {}
local plan = require("omniac.ui.plan")
local ansi = require("omniac.ui.ansi")

local frames = { "Working", "Working.", "Working..", "Working..." }
local groups = { "OmniacWorking1", "OmniacWorking2", "OmniacWorking3", "OmniacWorking4" }

local function activity_text(state, width)
  state.activity_plan_visible = false
  if state.failure_action then
    return "Prompt failed. Agent may have processed it.\n[r] Resend  [e] Restore input  [d] Dismiss"
  end
  if state.transient_activity then
    return state.transient_activity
  end
  if state.status == "working" then
    local summary = plan.activity(state)
    if summary then
      state.activity_plan_visible = true
      local lines = { summary }
      if state.plan_expanded then
        vim.list_extend(lines, plan.details(state, width))
      end
      local detail_end = #lines
      if state.tool_activity then
        table.insert(lines, (state.tool_activity:gsub("[\r\n]+", " ")))
      end
      table.insert(lines, state.plan_expanded and "[Ctrl-P] Collapse plan" or "[Ctrl-P] Expand plan")
      return table.concat(lines, "\n"), detail_end
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
  local value, detail_end = activity_text(state, math.max(1, win_width - 4))
  local expanded = state.activity_plan_visible and state.plan_expanded
  local plain, colors = ansi.parse(value)
  local lines = { "" }
  local color_marks = {}
  if value ~= "" then
    local inner_width = math.max(1, win_width - 4)
    local source_lines = opts.split_lines(plain)
    local max_lines = expanded and #source_lines or opts.max_lines
    local truncated = #source_lines > max_lines
    lines = {}
    local offset = 0
    for index = 1, math.min(#source_lines, max_lines) do
      local source = source_lines[index]
      if truncated and index == max_lines then
        source = source .. "…"
      end
      local fitted = opts.fit(source, inner_width)
      table.insert(lines, "  " .. fitted .. "  ")
      local retained = ansi.retained(source_lines[index], fitted)
      vim.list_extend(color_marks, ansi.marks(colors, offset, retained, index, 2))
      offset = offset + #source_lines[index] + 1
    end
  end

  local max_height = expanded and math.max(3, math.floor(vim.o.lines / 3)) or opts.max_lines
  local activity_height = math.max(1, math.min(#lines, max_height))
  local height_changed = state.activity_height ~= activity_height
  state.activity_height = activity_height

  local view
  if expanded and opts.valid_win(state.activity_win) then
    view = vim.api.nvim_win_call(state.activity_win, vim.fn.winsaveview)
  end
  vim.bo[state.activity_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.activity_buf, opts.namespace, 0, -1)
  vim.api.nvim_buf_set_lines(state.activity_buf, 0, -1, false, lines)
  vim.bo[state.activity_buf].modifiable = false
  vim.bo[state.activity_buf].modified = false
  if view then
    vim.api.nvim_win_call(state.activity_win, function()
      vim.fn.winrestview(view)
    end)
  end

  if value ~= "" then
    for index = 1, #lines do
      local group = groups[state.activity_frame]
      if expanded and index <= detail_end then
        group = index == 1 and "OmniacPlanSummary" or "OmniacPlanDetail"
        vim.api.nvim_buf_set_extmark(state.activity_buf, opts.namespace, index - 1, 0, {
          line_hl_group = group,
        })
      end
      opts.add_hl(state.activity_buf, index, 0, -1, group)
    end
    for _, mark in ipairs(color_marks) do
      opts.add_hl(state.activity_buf, mark.line, mark.from, mark.to, mark.group)
    end
    if state.failure_action or state.change_summary or state.activity_plan_visible then
      for index, line in ipairs(lines) do
        local from = 1
        while true do
          local shortcut_start, shortcut_end = line:find("%[[%w%-]+%]", from)
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
