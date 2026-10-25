local normalize = require("omniac.acp.normalize")

local M = {}
local queues = {}
local scheduled = {}

local function path(config)
  config = config or {}
  if not config.debug then
    return nil
  end

  config.logs = config.logs or {}
  if config.logs._path then
    return config.logs._path
  end

  local dir = config.logs.dir or "logs"
  if not dir:match("^/") then
    dir = (vim.loop.cwd() or ".") .. "/" .. dir
  end
  pcall(vim.fn.mkdir, dir, "p")
  config.logs._path = string.format("%s/acp-%s.jsonl", dir, os.date("%Y%m%d-%H%M%S"))
  return config.logs._path
end

local function flush_path(log_path)
  local lines = queues[log_path]
  queues[log_path] = nil
  scheduled[log_path] = nil
  if lines and #lines > 0 then
    pcall(vim.fn.writefile, lines, log_path, "a")
  end
end

function M.flush(config)
  local log_path = config and config.logs and config.logs._path
  if log_path and queues[log_path] then
    flush_path(log_path)
  end
end

function M.append(config, event, payload)
  local log_path = path(config)
  if not log_path then
    return
  end

  local ok, encoded = pcall(vim.json.encode, {
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event = event,
    payload = payload,
  })
  if not ok then
    return
  end

  queues[log_path] = queues[log_path] or {}
  table.insert(queues[log_path], encoded)
  if not scheduled[log_path] then
    scheduled[log_path] = true
    vim.schedule(function()
      flush_path(log_path)
    end)
  end
end

local function summary(event, payload)
  if type(payload) ~= "table" then
    return payload
  end
  if event ~= "notification" and event ~= "request" and event ~= "response" then
    return payload
  end

  local params = type(payload.params) == "table" and payload.params or {}
  local update = type(params.update) == "table" and params.update or params
  return {
    id = payload.id,
    method = payload.method,
    sessionUpdate = normalize.update_type(update),
    toolCallId = update.toolCallId,
    hasResult = payload.result ~= nil,
    hasError = payload.error ~= nil,
  }
end

function M.record(client, event, payload)
  M.append(client.config, event, payload)
  table.insert(client.debug_log, {
    event = event,
    payload = summary(event, payload),
    time = vim.loop.now(),
  })
  if #client.debug_log > 200 then
    table.remove(client.debug_log, 1)
  end
end

return M
