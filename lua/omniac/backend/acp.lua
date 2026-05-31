local transport = require("omniac.transport")

local M = {}

local function deepcopy(value)
  if vim.deepcopy then
    return vim.deepcopy(value)
  end

  return value
end

local function extract_text(value, seen)
  if type(value) == "string" then
    return value
  end

  if type(value) ~= "table" then
    return nil
  end

  seen = seen or {}
  if seen[value] then
    return nil
  end
  seen[value] = true

  local preferred_keys = {
    "text",
    "delta",
    "message",
    "content",
    "value",
  }

  for _, key in ipairs(preferred_keys) do
    local found = extract_text(value[key], seen)
    if found and found ~= "" then
      return found
    end
  end

  local content_items = value.contentItems or value.content_items
  if type(content_items) == "table" then
    for _, item in ipairs(content_items) do
      local found = extract_text(item, seen)
      if found and found ~= "" then
        return found
      end
    end
  end

  for _, item in pairs(value) do
    if type(item) == "table" or type(item) == "string" then
      local found = extract_text(item, seen)
      if found and found ~= "" then
        return found
      end
    end
  end

  return nil
end

local function first_option_id(request)
  local options = request and request.options or {}
  if type(options) ~= "table" then
    return nil
  end

  local first = options[1]
  if type(first) == "table" then
    return first.id or first.optionId or first.value or first.label
  end

  return nil
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
    transport = nil,
    running = false,
    request_handler = nil,
    notification_handler = nil,
    response_handler = nil,
    exit_handler = nil,
    session_id = nil,
    response_buffer = "",
    response_emitted = false,
    pending_prompt = nil,
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

  function state:_notify(message)
    self:_emit(self.notification_handler, message)
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
      self:_notify({
        method = "_transport/debug",
        params = entry,
      })
    end
  end

  function state:get_debug_log()
    return deepcopy(self.debug_log)
  end

  function state:_transport_config()
    local cfg = deepcopy(self.config)
    cfg.agent = deepcopy(cfg.agent or {})
    cfg.agent.auto_initialize = false
    return cfg
  end

  function state:_handle_server_request(message)
    local method = message and message.method
    local params = message and message.params or {}
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
      self.transport:respond(response.id, response.result, response.error)
    end

    if method == "session/request_permission" then
      local option_id = first_option_id(params)
      reply({
        outcome = option_id and {
          outcome = "selected",
          optionId = option_id,
        } or {
          outcome = "cancelled",
        },
      })
      return
    end

    if self.request_handler then
      self:_emit(self.request_handler, message, reply)
      return
    end

    reply({})
  end

  function state:_handle_notification(message)
    local method = message and message.method
    local params = message and message.params or {}

    if method == "session/update" then
      local update = params.update or params
      local update_type = update and (update.sessionUpdate or update.type)

      if update_type == "agent_message_chunk" or update_type == "agentMessageChunk" then
        local text = extract_text(update.content or update.delta or update)
        if text and text ~= "" then
          self.response_buffer = self.response_buffer .. text
        end
        return
      end

      if update_type == "agent_message_final" or update_type == "agentMessageFinal" then
        local text = extract_text(update.content or update.delta or update)
        if text and text ~= "" then
          self.response_buffer = self.response_buffer .. text
        end
        return
      end
    end

    if method == "session/started" then
      self.session_id = params.sessionId or params.session_id or params.id or self.session_id
      return
    end

    if method == "session/completed" then
      self:_emit_response(params)
      return
    end

    if method == "session/error" then
      self:_notify({
        method = "omniac/error",
        params = params,
      })
      return
    end

    if self.config.debug then
      self:_notify(message)
    end
  end

  function state:_initialize(callback)
    local client = self.config.client or {}
    local capabilities = deepcopy(client.capabilities or {})
    if vim.tbl_isempty(capabilities) then
      capabilities = {
        fs = {
          readTextFile = false,
          writeTextFile = false,
        },
        terminal = false,
      }
    end

    self.transport:request("initialize", {
      protocolVersion = client.protocol_version or 1,
      clientInfo = {
        name = client.name or "omniac.nvim",
        title = client.title or "omniac.nvim",
        version = client.version or "0.1.0",
      },
      clientCapabilities = capabilities,
    }, callback)
  end

  function state:_create_session(callback)
    local agent = self.config.agent or {}
    self.transport:request("session/new", {
      cwd = agent.cwd or vim.loop.cwd(),
      mcpServers = self.config.mcpServers or {},
    }, callback)
  end

  function state:_flush_pending_prompt()
    if not self.pending_prompt then
      return
    end

    local pending = self.pending_prompt
    self.pending_prompt = nil
    self:prompt(pending.text, pending.params, pending.callback)
  end

  function state:_emit_response(result)
    if self.response_emitted then
      return
    end

    self.response_emitted = true

    local text = self.response_buffer
    self.response_buffer = ""

    if (not text or text == "") and result then
      text = extract_text(result)
    end

    if text and text ~= "" then
      self:_notify({
        method = "omniac/response",
        params = {
          text = text,
          sessionId = self.session_id,
          result = result,
        },
      })
    end
  end

  function state:start()
    if self.running then
      return self
    end

    self.transport = transport.new(self:_transport_config())
    self.transport
      :on_notification(function(message)
        self:_debug("notification", message)
        self:_handle_notification(message)
      end)
      :on_request(function(message, reply)
        self:_debug("request", message)
        self:_handle_server_request(message)
      end)
      :on_exit(function(code, signal)
        self:_debug("exit", {
          code = code,
          signal = signal,
        })
        self.running = false
        self.transport = nil
        self.session_id = nil
        self.response_buffer = ""
        self.pending_prompt = nil
        self:_emit(self.exit_handler, code, signal)
      end)

    self.transport:start()
    self.running = true
    self:_debug("start", {
      cmd = (self.config.agent or {}).cmd,
      cwd = (self.config.agent or {}).cwd,
    })

    self:_initialize(function(err, result)
      if err then
        self:_notify({
          method = "omniac/error",
          params = {
            message = "initialize failed",
            error = err,
          },
        })
        return
      end

      if self.config.debug then
        self:_notify({
          method = "omniac/initialize",
          params = result,
        })
      end

      self.transport:notify("initialized", {})

      self:_create_session(function(session_err, session_result)
        if session_err then
          self:_notify({
            method = "omniac/error",
            params = {
              message = "session/new failed",
              error = session_err,
            },
          })
          return
        end

        self.session_id = session_result and (
          session_result.sessionId
          or (session_result.session and (session_result.session.id or session_result.session.sessionId))
          or session_result.id
        ) or self.session_id

        if self.config.debug then
          self:_notify({
            method = "omniac/session_started",
            params = session_result,
          })
        end

        self:_flush_pending_prompt()
      end)
    end)

    return self
  end

  function state:prompt(text, params, callback)
    local request_params = deepcopy(params or {})
    request_params.sessionId = request_params.sessionId or self.session_id
    request_params.prompt = request_params.prompt or {
      {
        type = "text",
        text = text,
      },
    }

    local function send_prompt()
      self.response_buffer = ""
      self.response_emitted = false
      self.transport:request("session/prompt", request_params, function(err, result)
        if err then
          if callback then
            callback(err, nil, result)
          end
          return
        end

        self:_emit_response(result)

        if callback then
          callback(nil, result, nil)
        end
      end)
    end

    if not self.transport or not self.running then
      error("omniac: ACP transport is not running")
    end

    if self.session_id then
      send_prompt()
      return
    end

    self.pending_prompt = {
      text = text,
      params = request_params,
      callback = callback,
    }
  end

  function state:close()
    if self.transport then
      self.transport:close()
    end
    self.running = false
    self.transport = nil
    self.session_id = nil
    self.response_buffer = ""
    self.response_emitted = false
    self.pending_prompt = nil
  end

  return state
end

return M
