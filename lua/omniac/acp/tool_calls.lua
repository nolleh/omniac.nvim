local normalize = require("omniac.acp.normalize")

local M = {}

-- Only text-bearing fields are output. Terminal IDs, resource URIs and diff
-- paths are references, even though their values happen to be strings.
local function output_text(value)
  if type(value) == "string" then
    return value ~= "" and value or nil
  end
  if type(value) ~= "table" then
    return nil
  end
  if value.type == "text" then
    return output_text(value.text)
  end
  if value.type == "content" then
    return output_text(value.content)
  end
  if value.type ~= nil then
    return nil
  end
  for _, key in ipairs({ "output", "stdout", "stderr", "text", "message", "content" }) do
    local found = output_text(value[key])
    if found then
      return found
    end
  end
  local parts = {}
  for _, item in ipairs(value) do
    local found = output_text(item)
    if found then
      table.insert(parts, found)
    end
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

function M.update(client, update)
  local id = update.toolCallId
  local call = id and client.tool_calls[id] or nil
  if not call then
    call = { chunks = {}, turn_id = client.active_turn_id }
    if id then
      client.tool_calls[id] = call
    end
  end
  for _, key in ipairs({ "kind", "title", "status" }) do
    if type(update[key]) == "string" then
      call[key] = update[key]
    end
  end
  local input = type(update.rawInput) == "table" and update.rawInput or {}
  call.command = input.command or input.cmd or call.command
  call.cwd = input.cwd or call.cwd

  local raw_output = normalize.raw_output(update)
  local meta = type(update._meta) == "table" and update._meta or {}
  local terminal_exit = type(meta.terminal_exit) == "table" and meta.terminal_exit or nil
  if type(raw_output) == "table" then
    call.exitCode = raw_output.exit_code or raw_output.exitCode or call.exitCode
  end
  if terminal_exit then
    call.terminal_finished = true
    call.exitCode = terminal_exit.exit_code or terminal_exit.exitCode or call.exitCode
    if call.status ~= "completed" and call.status ~= "failed" then
      call.status = call.exitCode and call.exitCode ~= 0 and "failed" or "completed"
    end
  end

  local activity = {
    toolCallId = id,
    kind = call.kind,
    status = call.status,
    title = call.title or call.command or call.kind or id,
    exitCode = call.exitCode,
  }
  if call.emitted then
    return activity
  end

  for _, item in ipairs(type(update.content) == "table" and update.content or {}) do
    if type(item) == "table" and item.type == "terminal" then
      call.terminal = true
    end
  end
  call.output = output_text(raw_output) or output_text(update.content) or call.output
  local delta = type(meta.terminal_output_delta) == "table" and meta.terminal_output_delta.data or nil
  if type(delta) == "string" and delta ~= "" then
    table.insert(call.chunks, delta)
  end

  if call.status ~= "completed" and call.status ~= "failed" then
    return activity
  end
  -- History may announce completion before terminal output arrives. Wait for
  -- terminal_exit, unless the completion already supplies a text snapshot.
  if call.terminal and not call.terminal_finished and not call.output then
    return activity
  end
  local output = call.output or table.concat(call.chunks)
  if output == "" and not call.terminal_finished then
    return activity
  end
  call.emitted = true
  call.output = nil
  call.chunks = nil
  if output == "" then
    return activity
  end
  return activity,
    {
      toolCallId = id,
      turnId = call.turn_id,
      kind = call.kind,
      status = call.status,
      title = activity.title,
      command = call.command or call.title,
      cwd = call.cwd,
      output = output,
      exitCode = call.exitCode,
    }
end

return M
