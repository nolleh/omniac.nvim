local M = {}

local local_commands = {
  { name = "exit", description = "Close Omniac chat" },
  { name = "changes", description = "Review files changed by Omniac" },
  { name = "mode", description = "Choose an advertised mode for the active session" },
  { name = "model", description = "Choose the model for the active session" },
  { name = "resume", description = "Open the ACP session selector" },
}

local function normalized_commands(available)
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
    if name == "" or seen[trigger .. name] then
      return
    end
    seen[trigger .. name] = true
    table.insert(result, {
      trigger = trigger,
      name = name,
      description = type(command.description) == "string" and command.description or "",
      input = type(command.input) == "table" and command.input or nil,
      source = source,
    })
  end

  for _, command in ipairs(local_commands) do
    add(command, "omniac")
  end
  for _, command in ipairs(available or {}) do
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

function M.command_prefix(value)
  if value:find("\n", 1, true) then
    return nil, nil
  end
  return value:match("^%s*([/$])([^%s]*)$")
end

function M.mention_prefix(value)
  if value:find("\n", 1, true) then
    return nil
  end
  return value:match("^%s*@([^%s]*)$")
end

local function command_matches(available, trigger, prefix)
  if trigger == nil or prefix == nil then
    return {}
  end
  local matches = {}
  for _, command in ipairs(normalized_commands(available)) do
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
  local paths = vim.fn.globpath(cwd, prefix == "" and "*" or (prefix .. "*"), false, true)
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

function M.current(available, value)
  local trigger, prefix = M.command_prefix(value)
  if trigger ~= nil then
    return "command", command_matches(available, trigger, prefix), trigger
  end
  local mention = M.mention_prefix(value)
  if mention ~= nil then
    return "mention", file_matches(mention)
  end
  return nil, {}
end

function M.complete(available, value, selected)
  local trigger, prefix = M.command_prefix(value)
  if trigger ~= nil then
    local matches = command_matches(available, trigger, prefix)
    if #matches > 0 then
      local item = matches[selected or 1] or matches[1]
      return item.trigger .. item.name
    end
  end
  prefix = M.mention_prefix(value)
  if prefix ~= nil then
    local matches = file_matches(prefix)
    if #matches > 0 then
      local item = matches[selected or 1] or matches[1]
      return "@" .. item.name
    end
  end
  return value
end

return M
