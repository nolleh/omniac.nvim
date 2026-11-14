local text = require("omniac.ui.text")
local ansi = require("omniac.ui.ansi")

local M = {}

local COMMAND_PREVIEW_LINES = 4
local labels = {
  execute = "Command execution",
  read = "Read files",
  search = "Search",
  fetch = "Fetch",
}

local function normalized(value)
  return tostring(value or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
end

local function summary(message)
  local raw_title = normalized(message.title)
  local title = ansi.parse(raw_title)
  local command = normalized(ansi.parse(message.command))
  -- Some agents use the entire command as their title, including a shell
  -- wrapper. That is command content, not a separate task description.
  if title ~= "" and not title:match("^call_[%w_%-]+$") and not title:match("^exec%-[%w%-]+$") then
    if command == "" or not command:find(title, 1, true) then
      return raw_title
    end
  end
  return labels[message.kind] or "Tool execution"
end

local function layout(message, width)
  local inner_width = math.max(1, width - 4)
  local command = ansi.wrapped(message.command, inner_width)
  local output, output_marks = ansi.wrapped(message.output, inner_width)
  local output_limit = math.max(0, math.floor(tonumber(message.output_preview_lines) or 4))
  return {
    width = inner_width,
    command = command,
    command_source = text.split_lines(ansi.parse(message.command)),
    output = output,
    output_marks = output_marks,
    output_limit = output_limit,
    hidden = math.max(0, #command - COMMAND_PREVIEW_LINES) + math.max(0, #output - output_limit),
  }
end

function M.can_expand(message, width)
  return message.expanded or layout(message, width).hidden > 0
end

function M.render(message, width)
  local info = layout(message, width)
  local lines, marks = {}, {}
  local function add(value, group, colors, source)
    local fitted = text.fit(value, info.width)
    local retained = ansi.retained(source or value, fitted)
    table.insert(lines, "  " .. fitted .. "  ")
    table.insert(marks, { line = #lines, from = 0, to = -1, group = group })
    for _, mark in ipairs(colors or {}) do
      local last = math.min(mark.to, retained)
      if mark.from < last then
        table.insert(marks, { line = #lines, from = mark.from + 2, to = last + 2, group = mark.group })
      end
    end
  end

  local function by_line(colors)
    local rows = {}
    for _, mark in ipairs(colors) do
      rows[mark.line] = rows[mark.line] or {}
      table.insert(rows[mark.line], mark)
    end
    return rows
  end

  local failed = message.status == "failed"
  local suffix = message.exitCode ~= nil and (" (exit " .. tostring(message.exitCode) .. ")") or ""
  local heading = (failed and "✗ " or "✓ ") .. summary(message) .. suffix
  local heading_lines, heading_marks = ansi.wrapped(heading, info.width)
  local heading_colors = by_line(heading_marks)
  for index = 1, math.min(2, #heading_lines) do
    local line = heading_lines[index]
    if index == 2 and #heading_lines > 2 then
      line = text.fit(line, math.max(1, info.width - 1)) .. "…"
    end
    add(line, failed and "OmniacError" or "OmniacToolSummary", heading_colors[index], heading_lines[index])
  end

  local function section(label, content, limit, group, colors)
    if #content == 0 then
      return
    end
    add(label, "OmniacMuted")
    local visible = message.expanded and #content or math.min(limit, #content)
    -- Keep the beginning and end of output, where commands often report results.
    local head = math.ceil(visible / 2)
    for index = 1, visible do
      local row = index
      if label == "Output" and not message.expanded and #content > visible and index > head then
        if index == head + 1 then
          add("… +" .. (#content - visible) .. " lines", "OmniacMuted")
        end
        row = #content - (visible - index)
      end
      add(content[row], group, colors[row])
    end
    if not message.expanded and #content > visible and (label ~= "Output" or visible < 2) then
      add("… +" .. (#content - visible) .. " lines", "OmniacMuted")
    end
  end

  local command_markdown, command_range
  if #info.command > 0 then
    local fence_size = 3
    for _, line in ipairs(info.command_source) do
      for run in line:gmatch("`+") do
        fence_size = math.max(fence_size, #run + 1)
      end
    end
    local fence = string.rep("`", fence_size)
    command_markdown = { from = #lines }
    table.insert(lines, "  " .. fence .. "bash")
    command_range = { from = #lines }
    local remaining = COMMAND_PREVIEW_LINES
    for _, line in ipairs(info.command_source) do
      if not message.expanded and remaining <= 0 then
        break
      end
      local rows = line == "" and { "" } or text.wrapped(line, info.width)
      local value = line
      if not message.expanded and #rows > remaining then
        value = table.concat(vim.list_slice(rows, 1, remaining))
      end
      -- Keep the shell source intact. The chat window soft-wraps long lines;
      -- inserting newlines or padding here would alter strings and heredocs.
      table.insert(lines, "  " .. value)
      remaining = remaining - math.min(remaining, #rows)
    end
    command_range.to = #lines
    table.insert(lines, "  " .. fence)
    command_markdown.to = #lines
    if not message.expanded and #info.command > COMMAND_PREVIEW_LINES then
      add("… +" .. (#info.command - COMMAND_PREVIEW_LINES) .. " lines", "OmniacMuted")
    end
  end
  section("Output", info.output, info.output_limit, "OmniacToolOutput", by_line(info.output_marks))
  if info.hidden > 0 or message.expanded then
    add(message.expanded and "Ctrl-T to collapse" or "Ctrl-T to expand", "OmniacMuted")
  end
  return { lines = lines, marks = marks, command_markdown = command_markdown, command_range = command_range }
end

return M
