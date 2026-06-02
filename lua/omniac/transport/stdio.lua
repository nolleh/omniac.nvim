local M = {}

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

local function json_null()
  if vim.NIL ~= nil then
    return vim.NIL
  end
  return nil
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
    thread_id = nil,
    permission_profile = nil,
    request_handler = nil,
    notification_handler = nil,
    response_handler = nil,
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
      payload = payload,
      time = vim.loop.now(),
    }
    table.insert(self.debug_log, entry)
    if #self.debug_log > 200 then
      table.remove(self.debug_log, 1)
    end
    if self.config.debug then
      self:_emit(self.notification_handler, {
        method = "_transport/debug",
        params = entry,
      })
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
  end

  function state:_handle_server_request(message)
    local replied = false

    local function reply(result, err)
      if replied then
        return
      end
      replied = true

      local response = { id = message.id }
      if err then
        response.error = err
      else
        response.result = result
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

    self:_debug("recv", message)

    if message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
      local callback = self.pending[message.id]
      self.pending[message.id] = nil

      if callback then
        self:_emit(callback, message.error, message.result, message)
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

    if self.config.agent.auto_initialize ~= false then
      self:initialize(function(err, result)
        if err then
          self:_emit(self.notification_handler, {
            method = "_transport/error",
            params = {
              message = "initialize failed",
              error = err,
            },
          })
          return
        end

        if result and result.capabilities ~= nil then
          self:_emit(self.notification_handler, {
            method = "_transport/initialize",
            params = result,
          })
        end

        self:notify("initialized", {})

        self:thread_start({}, function(thread_err, thread_result)
          if thread_err then
            self:_emit(self.notification_handler, {
              method = "_transport/error",
              params = {
                message = "thread/start failed",
                error = thread_err,
              },
            })
            return
          end

          if thread_result and thread_result.thread then
            self.thread_id = thread_result.thread.id or thread_result.thread.threadId or thread_result.threadId
          end
          if thread_result and thread_result.permissionProfile then
            self.permission_profile = thread_result.permissionProfile
          end

          self:_emit(self.notification_handler, {
            method = "_transport/thread_started",
            params = thread_result,
          })
        end)
      end)
    end

    return self
  end

  function state:request(method, params, callback)
    local id = tostring(self.next_id)
    self.next_id = self.next_id + 1

    if callback then
      self.pending[id] = callback
    end

    self:_send_raw({
      id = id,
      method = method,
      params = params or {},
    })

    return id
  end

  function state:notify(method, params)
    self:_send_raw({
      method = method,
      params = params or {},
    })
  end

  function state:initialize(callback)
    local client = self.config.client or {}
    local params = {
      clientInfo = {
        name = client.name or "omniac.nvim",
        title = client.title or "omniac.nvim",
        version = client.version or "0.1.0",
      },
      capabilities = vim.tbl_deep_extend("force", {
        experimentalApi = true,
      }, client.capabilities or {}),
    }

    return self:request("initialize", params, callback)
  end

  function state:thread_start(params, callback)
    local payload = deepcopy(params or {})
    payload.model = payload.model ~= nil and payload.model or json_null()
    payload.modelProvider = payload.modelProvider ~= nil and payload.modelProvider or json_null()
    payload.cwd = payload.cwd ~= nil and payload.cwd or (self.config.agent.cwd or json_null())
    payload.approvalPolicy = payload.approvalPolicy ~= nil and payload.approvalPolicy or json_null()
    payload.approvalsReviewer = payload.approvalsReviewer ~= nil and payload.approvalsReviewer or json_null()
    payload.sandbox = payload.sandbox ~= nil and payload.sandbox or json_null()
    payload.permissions = payload.permissions ~= nil and payload.permissions or json_null()
    payload.config = payload.config ~= nil and payload.config or json_null()
    payload.serviceName = payload.serviceName ~= nil and payload.serviceName or json_null()
    payload.baseInstructions = payload.baseInstructions ~= nil and payload.baseInstructions or json_null()
    payload.developerInstructions = payload.developerInstructions ~= nil and payload.developerInstructions
      or json_null()
    payload.personality = payload.personality ~= nil and payload.personality or json_null()
    payload.ephemeral = payload.ephemeral ~= nil and payload.ephemeral or json_null()
    payload.sessionStartSource = payload.sessionStartSource ~= nil and payload.sessionStartSource or json_null()
    payload.threadSource = payload.threadSource ~= nil and payload.threadSource or json_null()
    payload.environments = payload.environments ~= nil and payload.environments or json_null()
    payload.dynamicTools = payload.dynamicTools ~= nil and payload.dynamicTools or json_null()
    payload.mockExperimentalField = payload.mockExperimentalField ~= nil and payload.mockExperimentalField
      or json_null()
    payload.experimentalRawEvents = payload.experimentalRawEvents ~= nil and payload.experimentalRawEvents or false
    payload.persistExtendedHistory = payload.persistExtendedHistory ~= nil and payload.persistExtendedHistory or false
    payload.serviceTier = payload.serviceTier ~= nil and payload.serviceTier or json_null()
    payload.clientInfo = payload.clientInfo or json_null()

    return self:request("thread/start", payload, callback)
  end

  function state:turn_start(text, params, callback)
    local thread_id = params and params.threadId or self.thread_id
    local payload = deepcopy(params or {})

    local function send_turn()
      local active_thread_id = payload.threadId or self.thread_id
      if not active_thread_id then
        error("omniac: no thread id available; thread/start must complete first")
      end

      payload.threadId = active_thread_id
      payload.input = payload.input
        or {
          {
            type = "text",
            text = text,
            text_elements = {},
          },
        }
      payload.responsesapiClientMetadata = payload.responsesapiClientMetadata ~= nil
          and payload.responsesapiClientMetadata
        or json_null()
      payload.environments = payload.environments ~= nil and payload.environments or json_null()
      payload.cwd = payload.cwd ~= nil and payload.cwd or json_null()
      payload.approvalPolicy = payload.approvalPolicy ~= nil and payload.approvalPolicy or json_null()
      payload.approvalsReviewer = payload.approvalsReviewer ~= nil and payload.approvalsReviewer or json_null()
      payload.sandboxPolicy = payload.sandboxPolicy ~= nil and payload.sandboxPolicy or json_null()
      payload.permissions = payload.permissions ~= nil and payload.permissions or json_null()
      payload.model = payload.model ~= nil and payload.model or json_null()
      payload.effort = payload.effort ~= nil and payload.effort or json_null()
      payload.summary = payload.summary ~= nil and payload.summary or json_null()
      payload.personality = payload.personality ~= nil and payload.personality or json_null()
      payload.outputSchema = payload.outputSchema ~= nil and payload.outputSchema or json_null()
      payload.collaborationMode = payload.collaborationMode ~= nil and payload.collaborationMode or json_null()
      return self:request("turn/start", payload, callback)
    end

    if thread_id then
      return send_turn()
    end

    return self:thread_start({}, function(err, result)
      if err then
        if callback then
          callback(err, nil, result)
        end
        return
      end

      if result and result.thread then
        self.thread_id = result.thread.id or result.thread.threadId or result.threadId
      end

      send_turn()
    end)
  end

  function state:prompt(text, params, callback)
    return self:turn_start(text, params, callback)
  end

  function state:respond(id, result, err)
    local response = { id = id }
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
  end

  return state
end

return M
