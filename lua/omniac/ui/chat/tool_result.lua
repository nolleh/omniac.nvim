local text = require("omniac.ui.text")

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
  local title = normalized(message.title)
  local command = normalized(message.command)
  -- Some agents use the entire command as their title, including a shell
  -- wrapper. That is command content, not a separate task description.
  if title ~= "" and not title:match("^call_[%w_%-]+$") and not title:match("^exec%-[%w%-]+$") then
    if command == "" or not command:find(title, 1, true) then
      return title
    end
  end
  return labels[message.kind] or "Tool execution"
end

local function layout(message, width)
  local inner_width = math.max(1, width - 4)
  local command = text.wrapped(message.command or "", inner_width)
  local output = text.wrapped(message.output or "", inner_width)
  local output_limit = math.max(0, math.floor(tonumber(message.output_preview_lines) or 4))
  return {
    width = inner_width,
    command = command,
    output = output,
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
  local function add(value, group)
    table.insert(lines, "  " .. text.fit(value, info.width) .. "  ")
    table.insert(marks, { line = #lines, from = 0, to = -1, group = group })
  end

  local failed = message.status == "failed"
  local suffix = message.exitCode ~= nil and (" (exit " .. tostring(message.exitCode) .. ")") or ""
  local heading = (failed and "✗ " or "✓ ") .. summary(message) .. suffix
  local heading_lines = text.wrapped(heading, info.width)
  for index = 1, math.min(2, #heading_lines) do
    local line = heading_lines[index]
    if index == 2 and #heading_lines > 2 then
      line = text.fit(line, math.max(1, info.width - 1)) .. "…"
    end
    add(line, failed and "OmniacError" or "OmniacToolSummary")
  end

  local function section(label, content, limit, group)
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
      add(content[row], group)
    end
    if not message.expanded and #content > visible and (label ~= "Output" or visible < 2) then
      add("… +" .. (#content - visible) .. " lines", "OmniacMuted")
    end
  end

  section("Command", info.command, COMMAND_PREVIEW_LINES, "OmniacToolCommand")
  section("Output", info.output, info.output_limit, "OmniacToolOutput")
  if info.hidden > 0 or message.expanded then
    add(message.expanded and "Ctrl-T to collapse" or "Ctrl-T to expand", "OmniacMuted")
  end
  return { lines = lines, marks = marks }
end

return M
