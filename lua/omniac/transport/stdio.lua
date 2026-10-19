local M = {}

local DEFAULT_REQUEST_TIMEOUT_MS = 30000
local DEFAULT_PROMPT_TIMEOUT_MS = 600000

local function encode_json(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end

  return vim.fn.json_encode(value)
end

local function decode_json(text)
  if vim.json and vim.json.decode then
    return vim.json.decode(text)
  end

  return vim.fn.json_decode(text)
end

local function deepcopy(value)
  if vim.deepcopy then
    return vim.deepcopy(value)
  end

  return value
end

local function line_summary(lines)
  local bytes = 0
  for _, line in ipairs(lines or {}) do
    bytes = bytes + #tostring(line or "")
  end
  return {
    line_count = #(lines or {}),
    bytes = bytes,
  }
end

local function debug_payload_summary(event, payload)
  if event == "stdout_chunk" or event == "stderr_chunk" then
    return line_summary(type(payload) == "table" and payload.lines or {})
  end
  if event == "ignored_echo" then
    return { bytes = #tostring(payload or "") }
  end
  if event == "recv" and type(payload) == "table" then
    local params = type(payload.params) == "table" and payload.params or {}
    local update = type(params.update) == "table" and params.update or params
    return {
      id = payload.id,
      method = payload.method,
      sessionUpdate = update.sessionUpdate or update.type,
      toolCallId = update.toolCallId,
      hasResult = payload.result ~= nil,
      hasError = payload.error ~= nil,
    }
  end
  return payload
end

function M.new(config)
  local state = {
    config = config or {},
    running = false,
    jobid = nil,
    buffer = "",
    next_id = 1,
    pending = {},
    sent_echoes = {},
    request_handler = nil,
    notification_handler = nil,
    response_handler = nil,
    protocol_handler = nil,
    exit_handler = nil,
    debug_log = {},
  }

  function state:on_request(handler)
    self.request_handler = handler
    return self
  end

  function state:on_notification(handler)
    self.notification_handler = handler
    return self
  end

  function state:on_response(handler)
    self.response_handler = handler
    return self
  end

  function state:on_protocol(handler)
    self.protocol_handler = handler
    return self
  end

  function state:_record_protocol(direction, payload)
    if self.protocol_handler then
      pcall(self.protocol_handler, direction, payload)
    end
  end

  function state:on_exit(handler)
    self.exit_handler = handler
    return self
  end

  function state:_emit(handler, ...)
    if not handler then
      return
    end

    local args = { ... }
    vim.schedule(function()
      handler(unpack(args))
    end)
  end

  function state:_debug(event, payload)
    local entry = {
      event = event,
      payload = debug_payload_summary(event, payload),
      time = vim.loop.now(),
    }
    table.insert(self.debug_log, entry)
    if #self.debug_log > 200 then
      table.remove(self.debug_log, 1)
    end
  end

  function state:get_debug_log()
    return deepcopy(self.debug_log)
  end

  function state:_send_raw(payload)
    if not self.running or not self.jobid then
      error("omniac: transport is not running")
    end

    local line = type(payload) == "string" and payload or encode_json(payload)
    self:_debug("send", payload)
    table.insert(self.sent_echoes, line)
    vim.fn.chansend(self.jobid, line .. "\n")
    self:_record_protocol("send", payload)
  end

  function state:_clear_pending(id)
    local pending = self.pending[id]
    self.pending[id] = nil
    if pending and pending.timer then
      pending.timer:stop()
      pending.timer:close()
    end
    return pending
  end

  function state:_start_pending_timer(id, pending)
    if pending.pause_count > 0 or type(pending.remaining_ms) ~= "number" or pending.remaining_ms <= 0 then
      return
    end

    pending.started_at = vim.loop.now()
    pending.timer = vim.loop.new_timer()
    pending.timer:start(
      pending.remaining_ms,
      0,
      vim.schedule_wrap(function()
        if self.pending[id] ~= pending then
          return
        end
        self:_clear_pending(id)
        self:_emit(pending.callback, {
          code = -32000,
          message = string.format("ACP %s timed out after %d ms", pending.method, pending.timeout_ms),
        })
      end)
    )
  end

  function state:_pause_prompt_timeouts()
    for _, pending in pairs(self.pending) do
      if pending.method == "session/prompt" then
        pending.pause_count = pending.pause_count + 1
        if pending.pause_count == 1 and pending.timer then
          pending.remaining_ms = math.max(1, pending.remaining_ms - (vim.loop.now() - pending.started_at))
          pending.timer:stop()
          pending.timer:close()
          pending.timer = nil
        end
      end
    end
  end

  function state:_resume_prompt_timeouts()
    for id, pending in pairs(self.pending) do
      if pending.method == "session/prompt" and pending.pause_count > 0 then
        pending.pause_count = pending.pause_count - 1
        if pending.pause_count == 0 then
          self:_start_pending_timer(id, pending)
        end
      end
    end
  end

  function state:_fail_pending(message)
    for id in pairs(self.pending) do
      local pending = self:_clear_pending(id)
      if pending then
        self:_emit(pending.callback, { code = -32000, message = message })
      end
    end
  end

  function state:_handle_server_request(message)
    local replied = false
    local pauses_prompt_timeout = message.method == "session/request_permission"
    if pauses_prompt_timeout then
      self:_pause_prompt_timeouts()
    end

    local function reply(result, err)
      if replied then
        return
      end
      replied = true

      local response = {
        jsonrpc = "2.0",
        id = message.id,
      }
      if err then
        response.error = err
      else
        response.result = result
      end
      if pauses_prompt_timeout then
        self:_resume_prompt_timeouts()
      end
      self:_send_raw(response)
    end

    if self.request_handler then
      self:_emit(self.request_handler, message, reply)
      return
    end

    reply(nil, {
      code = -32601,
      message = "method not handled: " .. tostring(message.method),
    })
  end

  function state:_dispatch_message(message)
    if type(message) ~= "table" then
      return
    end

    self:_record_protocol("recv", message)
    self:_debug("recv", message)

    if message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
      local pending = self:_clear_pending(message.id)

      if pending then
        self:_emit(pending.callback, message.error, message.result, message)
      end
      self:_emit(self.response_handler, message)
      return
    end

    if message.id ~= nil and message.method then
      self:_handle_server_request(message)
      return
    end

    self:_emit(self.notification_handler, message)
  end

  function state:_handle_output(lines)
    self:_debug("stdout_chunk", {
      lines = deepcopy(lines),
    })

    local data = lines or {}
    if #data == 0 then
      return
    end

    local function handle_line(line)
      line = (line or ""):gsub("\r$", "")
      if line == "" then
        return
      end

      if #self.sent_echoes > 0 and line == self.sent_echoes[1] then
        table.remove(self.sent_echoes, 1)
        self:_debug("ignored_echo", line)
        return
      end

      local ok, message = pcall(decode_json, line)
      if ok and type(message) == "table" then
        self:_dispatch_message(message)
      else
        self:_emit(self.notification_handler, {
          method = "_transport/error",
          params = {
            message = "Failed to decode JSONL frame",
            line = line,
          },
        })
      end
    end

    self.buffer = self.buffer .. (data[1] or "")
    for index = 2, #data do
      handle_line(self.buffer)
      self.buffer = data[index] or ""
    end
  end

  function state:start()
    if self.running then
      return self
    end

    local agent = self.config.agent or {}
    if not agent.cmd then
      error("omniac: agent.cmd is not configured")
    end

    local cmd = agent.cmd
    if type(cmd) == "string" and type(agent.args) == "table" and #agent.args > 0 then
      local parts = { cmd }
      for _, arg in ipairs(agent.args) do
        table.insert(parts, arg)
      end
      cmd = parts
    elseif type(cmd) == "table" and type(agent.args) == "table" and #agent.args > 0 then
      for _, arg in ipairs(agent.args) do
        table.insert(cmd, arg)
      end
    end

    local env_prefix = {}
    if type(agent.env) == "table" then
      for key, value in pairs(agent.env) do
        table.insert(env_prefix, key .. "=" .. tostring(value))
      end
    end

    if #env_prefix > 0 then
      local prefixed_cmd = { "env" }
      for _, item in ipairs(env_prefix) do
        table.insert(prefixed_cmd, item)
      end
      if type(cmd) == "table" then
        for _, item in ipairs(cmd) do
          table.insert(prefixed_cmd, item)
        end
      else
        table.insert(prefixed_cmd, cmd)
      end
      cmd = prefixed_cmd
    end

    self.jobid = vim.fn.jobstart(cmd, {
      cwd = agent.cwd,
      pty = agent.pty ~= false,
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(_, data)
        self:_handle_output(data)
      end,
      on_stderr = function(_, data)
        self:_debug("stderr_chunk", {
          lines = deepcopy(data),
        })
        if data and #data > 0 then
          self:_emit(self.notification_handler, {
            method = "_transport/stderr",
            params = { lines = deepcopy(data) },
          })
        end
      end,
      on_exit = function(_, code, signal)
        self:_debug("exit", {
          code = code,
          signal = signal,
        })
        self.running = false
        self.jobid = nil
        self:_fail_pending("ACP agent exited before responding")
        self:_emit(self.exit_handler, code, signal)
      end,
    })

    if not self.jobid or self.jobid <= 0 then
      self.jobid = nil
      error("omniac: failed to start agent subprocess")
    end

    self.running = true
    self:_debug("start", {
      cmd = cmd,
      cwd = agent.cwd,
    })

    return self
  end

  function state:request(method, params, callback)
    local id = tostring(self.next_id)
    self.next_id = self.next_id + 1

    if callback then
      local client = self.config.client or {}
      local timeout = method == "session/prompt" and client.prompt_timeout_ms or client.request_timeout_ms
      if timeout == nil then
        timeout = method == "session/prompt" and DEFAULT_PROMPT_TIMEOUT_MS or DEFAULT_REQUEST_TIMEOUT_MS
      end
      local pending = {
        callback = callback,
        method = method,
        timeout_ms = timeout,
        remaining_ms = timeout,
        pause_count = 0,
      }
      self.pending[id] = pending
      if type(timeout) == "number" and timeout > 0 then
        self:_start_pending_timer(id, pending)
      end
    end

    local ok, err = pcall(self._send_raw, self, {
      jsonrpc = "2.0",
      id = id,
      method = method,
      params = params or {},
    })
    if not ok then
      self:_clear_pending(id)
      error(err)
    end

    return id
  end

  function state:notify(method, params)
    self:_send_raw({
      jsonrpc = "2.0",
      method = method,
      params = params or {},
    })
  end

  function state:respond(id, result, err)
    local response = {
      jsonrpc = "2.0",
      id = id,
    }
    if err then
      response.error = err
    else
      response.result = result
    end
    self:_send_raw(response)
  end

  function state:close()
    self:_debug("close", { jobid = self.jobid })
    if self.jobid then
      pcall(vim.fn.jobstop, self.jobid)
    end
    self.running = false
    self.jobid = nil
    for id in pairs(self.pending) do
      self:_clear_pending(id)
    end
  end

  return state
end

return M
