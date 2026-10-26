local transport = require("omniac.transport")
local content = require("omniac.acp.content")
local logging = require("omniac.acp.logging")
local normalize = require("omniac.acp.normalize")
local session_state = require("omniac.acp.session_state")
local updates = require("omniac.acp.updates")

local M = {}

local function deepcopy(value)
  if vim.deepcopy then
    return vim.deepcopy(value)
  end

  return value
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

local function result_table(result)
  if type(result) == "table" then
    return result
  end

  return {}
end

function M.new(config)
  local state = {
    config = config or {},
    transport = nil,
    running = false,
    closing = false,
    request_handler = nil,
    notification_handler = nil,
    response_handler = nil,
    exit_handler = nil,
    session_id = nil,
    response_chunks = {},
    response_emitted = false,
    response_streamed = false,
    pending_prompt = nil,
    edit_tool_calls = {},
    debug_log = {},
    agent_capabilities = {},
    turn_sequence = 0,
    active_turn_id = nil,
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

  function state:_emit_notification(message)
    self:_emit(self.notification_handler, message)
  end

  function state:_debug(event, payload)
    logging.record(self, event, payload)
  end

  function state:get_debug_log()
    return deepcopy(self.debug_log)
  end

  function state:supports_session_capability(name)
    return normalize.session_capability(self.agent_capabilities, name)
  end

  function state:supports_prompt_capability(name)
    return normalize.prompt_capability(self.agent_capabilities, name)
  end

  function state:_transport_config()
    local cfg = deepcopy(self.config)
    cfg.agent = deepcopy(cfg.agent or {})
    return cfg
  end

  function state:_handle_server_request(message, transport_reply)
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
      logging.append(self.config, "response", response)
      if transport_reply then
        transport_reply(response.result, response.error)
      else
        self.transport:respond(response.id, response.result, response.error)
      end
    end

    if self.request_handler then
      self:_emit(self.request_handler, message, reply)
      return
    end

    if method == "session/request_permission" then
      reply({
        outcome = {
          outcome = "cancelled",
        },
      })
      return
    end

    reply({})
  end

  function state:_handle_notification(message)
    local method = message and message.method
    local params = message and message.params or {}

    if method == "session/update" then
      local update = params.update or params
      if updates.handle(self, update) then
        return
      end
    end

    if method == "session/started" then
      self.session_id = normalize.session_id(params) or self.session_id
      return
    end

    if method == "session/completed" then
      self:_emit_response(params)
      return
    end

    if method == "session/error" then
      self:_emit_notification({
        method = "omniac/error",
        params = params,
      })
      return
    end

    if method == "_transport/error" then
      self:_emit_notification({
        method = "omniac/error",
        params = params,
      })
      return
    end

    if self.config.debug then
      self:_emit_notification(message)
    end
  end

  function state:_initialize(callback)
    local client = self.config.client or {}
    local capabilities = deepcopy(client.capabilities or {})
    if vim.tbl_isempty(capabilities) then
      capabilities = {
        fs = {
          readTextFile = true,
          writeTextFile = true,
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

  function state:_session_params()
    local agent = self.config.agent or {}
    local params = {
      cwd = agent.cwd or vim.loop.cwd(),
      mcpServers = self.config.mcpServers or {},
    }

    if
      self.config.additionalDirectories
      and normalize.session_capability(self.agent_capabilities, "additionalDirectories")
    then
      params.additionalDirectories = self.config.additionalDirectories
    end

    return params
  end

  function state:_session_selection()
    local agent = self.config.agent or {}
    local session = agent.session or {}
    local action = session.action or agent.session_action or "new"
    local session_id = session.id or agent.session_id

    if action ~= "new" and action ~= "load" and action ~= "resume" and action ~= "select" then
      action = "new"
    end

    return action, session_id
  end

  function state:_list_sessions(callback)
    local params = {
      cwd = ((self.config.agent or {}).cwd or vim.loop.cwd()),
    }

    self.transport:request("session/list", params, function(err, result)
      if err then
        callback(err, nil)
        return
      end

      callback(nil, (result and result.sessions) or {})
    end)
  end

  function state:list_sessions(callback)
    self:_list_sessions(callback)
  end

  function state:_create_session(callback)
    self.transport:request("session/new", self:_session_params(), callback)
  end

  function state:new_session(callback)
    callback = callback or function() end
    if not self.transport or not self.running then
      callback({ message = "ACP transport is not running" })
      return
    end
    if self.active_turn_id ~= nil then
      callback({ message = "Cannot start a new session while a turn is active" })
      return
    end

    self:_create_session(function(err, result)
      if err then
        callback(err)
        return
      end

      local session_id = normalize.session_id(result)
      if not session_id then
        callback({ message = "session/new did not return a session id" })
        return
      end

      self.session_id = session_id
      self.response_chunks = {}
      self.response_emitted = false
      self.response_streamed = false
      self.edit_tool_calls = {}
      self.active_turn_id = nil
      self.pending_prompt = nil
      self.config_options = nil
      self.session_mode = nil
      self.session_model = nil
      self:_apply_session_state(result)

      self:_set_session_mode(function(mode_err)
        self:_emit_notification({
          method = "omniac/session_started",
          params = vim.tbl_extend("force", result_table(result), {
            sessionId = self.session_id,
            method = "session/new",
            clearChat = true,
          }),
        })
        callback(mode_err)
      end)
    end)
  end

  function state:_load_session(session_id, callback)
    local params = self:_session_params()
    params.sessionId = session_id
    self.transport:request("session/load", params, callback)
  end

  function state:_resume_session(session_id, callback)
    local params = self:_session_params()
    params.sessionId = session_id
    self.transport:request("session/resume", params, callback)
  end

  function state:_setup_session(callback)
    local action, session_id = self:_session_selection()
    if action == "select" then
      local selector = self.config.session_selector
      if not selector then
        action = "new"
      else
        self:_list_sessions(function(list_err, sessions)
          selector(sessions or {}, {
            list_supported = list_err == nil,
            message = list_err and tostring(list_err.message or list_err.error or "session/list is not available")
              or nil,
          }, function(selection)
            if not selection then
              callback({
                message = "session selection cancelled",
              }, nil, "session/select")
              return
            end
            self.config.agent.session = selection
            self:_setup_session(callback)
          end)
        end)
        return
      end
    end

    if action == "new" then
      self:_create_session(function(err, result)
        if not err then
          self.session_id = normalize.session_id(result) or self.session_id
        end
        callback(err, result, "session/new")
      end)
      return
    end

    if not session_id or session_id == "" then
      callback({
        message = "session id is required for " .. action,
      }, nil, "session/" .. action)
      return
    end

    if action == "load" then
      if not normalize.has_load_session(self.agent_capabilities) then
        callback({
          message = "agent does not advertise loadSession",
        }, nil, "session/load")
        return
      end
      self.session_id = session_id
      self:_load_session(session_id, function(err, result)
        callback(err, result, "session/load")
      end)
      return
    end

    if not normalize.session_capability(self.agent_capabilities, "resume") then
      callback({
        message = "agent does not advertise sessionCapabilities.resume",
      }, nil, "session/resume")
      return
    end
    self.session_id = session_id
    self:_resume_session(session_id, function(err, result)
      callback(err, result, "session/resume")
    end)
  end

  function state:_set_session_mode(callback)
    local agent = self.config.agent or {}
    local mode_id = agent.mode_id
    if not mode_id or mode_id == "" or not self.session_id then
      callback(nil, nil)
      return
    end

    local mode_state = self.session_mode
    local available_modes = mode_state and mode_state.availableModes or {}
    local supported = false
    for _, mode in ipairs(available_modes) do
      if mode.id == mode_id then
        supported = true
        break
      end
    end

    if not supported then
      local choices = {}
      for _, mode in ipairs(available_modes) do
        table.insert(choices, string.format("%s (%s)", mode.name or mode.id, mode.id))
      end

      local current_mode_id = mode_state and mode_state.currentModeId
      local current_mode_name = mode_state and session_state.mode_name(mode_state)
      local current_mode = current_mode_id and string.format("%s (%s)", current_mode_name, current_mode_id)
        or "the agent's default mode"
      local available = #choices > 0 and table.concat(choices, ", ") or "none advertised"
      self:_emit_notification({
        method = "omniac/warning",
        params = {
          message = string.format(
            "Configured agent.mode_id %q is not supported by this agent. Available modes: %s. Continuing with %s.",
            mode_id,
            available,
            current_mode
          ),
        },
      })
      callback(nil, nil)
      return
    end

    self:set_session_mode(mode_id, callback)
  end

  function state:_emit_session_mode_update()
    if not self.session_mode then
      return
    end

    self:_emit_notification({
      method = "omniac/session_mode_update",
      params = {
        sessionId = self.session_id,
        source = self.session_mode.source,
        configId = self.session_mode.configId,
        currentModeId = self.session_mode.currentModeId,
        currentModeName = session_state.mode_name(self.session_mode),
        availableModes = self.session_mode.availableModes or {},
      },
    })
  end

  function state:_emit_session_model_update()
    if not self.session_model then
      return
    end

    self:_emit_notification({
      method = "omniac/session_model_update",
      params = {
        sessionId = self.session_id,
        configId = self.session_model.configId,
        currentModelId = self.session_model.currentModelId,
        currentModelName = session_state.model_name(self.session_model),
        availableModels = self.session_model.availableModels or {},
      },
    })
  end

  function state:_apply_session_state(result)
    if type(result) ~= "table" then
      return
    end

    local session = type(result.session) == "table" and result.session or {}
    local config_options = normalize.config_options(result) or normalize.config_options(session)
    if type(config_options) == "table" then
      self.config_options = config_options
      self:_emit_notification({
        method = "omniac/session_config_update",
        params = { configOptions = deepcopy(config_options) },
      })
    end

    local model_state = session_state.model_from_config(config_options)
    if model_state then
      self.session_model = model_state
      self:_emit_session_model_update()
    end

    local mode_state = session_state.mode_from_config(config_options)
    if mode_state then
      self.session_mode = mode_state
      self:_emit_session_mode_update()
    else
      mode_state = session_state.mode_from_modes(result.modes or session.modes)
      if mode_state then
        self.session_mode = mode_state
        self:_emit_session_mode_update()
      end
    end
  end

  function state:get_session_model()
    return deepcopy(self.session_model)
  end

  function state:get_session_mode()
    return deepcopy(self.session_mode)
  end

  function state:set_session_model(model_id, callback)
    callback = callback or function() end
    local model_state = self.session_model
    if not self.transport or not self.running then
      callback({ message = "ACP transport is not running" })
      return
    end
    if not self.session_id then
      callback({ message = "ACP session is not ready" })
      return
    end
    if not model_state or not model_state.configId then
      callback({ message = "agent did not advertise a model config option" })
      return
    end

    local selected
    for _, model in ipairs(model_state.availableModels or {}) do
      if model.id == model_id or model.name == model_id then
        selected = model.id
        break
      end
      if model.id:lower() == model_id:lower() or model.name:lower() == model_id:lower() then
        selected = model.id
        break
      end
    end
    if not selected then
      callback({ message = "unknown model: " .. tostring(model_id) })
      return
    end

    self.transport:request("session/set_config_option", {
      sessionId = self.session_id,
      configId = model_state.configId,
      value = selected,
    }, function(err, result)
      if not err then
        model_state.currentModelId = selected
        self:_apply_session_state(result)
        if self.session_model == model_state then
          self:_emit_session_model_update()
        end
      end
      callback(err, result, selected)
    end)
  end

  function state:set_session_mode(mode_id, callback)
    callback = callback or function() end
    if not self.transport or not self.running then
      callback({
        message = "ACP transport is not running",
      })
      return
    end
    if not self.session_id then
      callback({
        message = "ACP session is not ready",
      })
      return
    end
    if not mode_id or mode_id == "" then
      callback({
        message = "mode id is required",
      })
      return
    end

    if self.session_mode and self.session_mode.source == "config" and self.session_mode.configId then
      self.transport:request("session/set_config_option", {
        sessionId = self.session_id,
        configId = self.session_mode.configId,
        value = mode_id,
      }, function(err, result)
        if not err then
          self:_apply_session_state(result)
        end
        callback(err, result)
      end)
      return
    end

    self.transport:request("session/set_mode", {
      sessionId = self.session_id,
      modeId = mode_id,
    }, function(err, result)
      if not err then
        if self.session_mode then
          self.session_mode.currentModeId = mode_id
        end
        self:_apply_session_state(result)
        self:_emit_session_mode_update()
      end
      callback(err, result)
    end)
  end

  function state:cycle_session_mode(callback)
    callback = callback or function() end
    local mode_state = self.session_mode
    local modes = mode_state and mode_state.availableModes or {}
    if #modes == 0 then
      callback({
        message = "agent did not advertise session modes",
      })
      return
    end

    local current = mode_state.currentModeId
    local index = 0
    for mode_index, mode in ipairs(modes) do
      if mode.id == current then
        index = mode_index
        break
      end
    end

    local next_mode = modes[(index % #modes) + 1]
    self:set_session_mode(next_mode.id, callback)
  end

  function state:toggle_collaboration_mode(callback)
    callback = callback or function() end
    if not self.transport or not self.running then
      callback({ message = "ACP transport is not running" })
      return
    end
    if not self.session_id then
      callback({ message = "ACP session is not ready" })
      return
    end

    local collaboration
    for _, option in ipairs(self.config_options or {}) do
      if option.id == "collaboration_mode" and option.type == "select" then
        collaboration = option
        break
      end
    end
    if not collaboration then
      callback({ message = "agent did not advertise a collaboration mode option" })
      return
    end

    local current = normalize.current_value(collaboration)
    local next_mode = current == "plan" and "default" or "plan"
    local available = false
    for _, option in ipairs(collaboration.options or {}) do
      if (option.value or option.id) == next_mode then
        available = true
        break
      end
    end
    if not available then
      callback({ message = "agent did not advertise collaboration mode " .. next_mode })
      return
    end

    self.transport:request("session/set_config_option", {
      sessionId = self.session_id,
      configId = collaboration.id,
      value = next_mode,
    }, function(err, result)
      if not err then
        self:_apply_session_state(result)
      end
      callback(err, next_mode)
    end)
  end

  function state:cancel(callback)
    callback = callback or function() end
    if not self.transport or not self.running then
      callback({
        message = "ACP transport is not running",
      })
      return
    end
    if not self.session_id then
      callback({
        message = "ACP session is not ready",
      })
      return
    end

    self.transport:notify("session/cancel", {
      sessionId = self.session_id,
    })
    callback(nil)
  end

  function state:_flush_pending_prompt()
    if not self.pending_prompt then
      return
    end

    local pending = self.pending_prompt
    self.pending_prompt = nil
    self:prompt(pending.text, pending.params, pending.callback)
  end

  function state:_emit_response(result, turn_id)
    if self.response_emitted then
      return
    end

    self.response_emitted = true
    self.last_stop_reason = normalize.stop_reason(result)

    local text = table.concat(self.response_chunks)
    self.response_chunks = {}

    if (not text or text == "") and result then
      text = content.response_text(result)
    end

    if text and text ~= "" then
      if self.response_streamed then
        self:_emit_notification({
          method = "omniac/response_completed",
          params = {
            sessionId = self.session_id,
            turnId = turn_id,
            result = result,
            stopReason = self.last_stop_reason,
          },
        })
      else
        self:_emit_notification({
          method = "omniac/response",
          params = {
            text = text,
            sessionId = self.session_id,
            turnId = turn_id,
            result = result,
            stopReason = self.last_stop_reason,
          },
        })
      end
    else
      self:_emit_notification({
        method = "omniac/response_completed",
        params = {
          sessionId = self.session_id,
          turnId = turn_id,
          result = result,
          stopReason = self.last_stop_reason,
        },
      })
    end
    self.active_turn_id = nil
  end

  function state:start()
    if self.running then
      return self
    end

    local configured_version = (self.config.client or {}).protocol_version or 1
    if configured_version ~= 1 then
      self:_emit_notification({
        method = "omniac/error",
        params = {
          message = "initialize failed",
          error = {
            message = "unsupported ACP client protocol version: " .. tostring(configured_version) .. " (supported: 1)",
          },
        },
      })
      return self
    end

    self.closing = false
    self.transport = transport.new(self:_transport_config())
    if self.transport.on_protocol then
      self.transport:on_protocol(function(direction, message)
        if type(message) ~= "table" then
          return
        end
        if direction == "send" and message.method then
          logging.append(self.config, message.id ~= nil and "client_request" or "client_notification", message)
        elseif direction == "recv" and message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
          logging.append(self.config, "agent_response", message)
        end
      end)
    end
    self.transport
      :on_notification(function(message)
        if message and message.method == "_transport/debug" then
          return
        end
        self:_debug("notification", message)
        self:_handle_notification(message)
      end)
      :on_request(function(message, reply)
        self:_debug("request", message)
        self:_handle_server_request(message, reply)
      end)
      :on_exit(function(code, signal)
        self:_debug("exit", {
          code = code,
          signal = signal,
        })
        logging.flush(self.config)
        self.running = false
        self.transport = nil
        self.session_id = nil
        self.response_chunks = {}
        self.response_streamed = false
        self.pending_prompt = nil
        self.edit_tool_calls = {}
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
        local pending = self.pending_prompt
        self.pending_prompt = nil
        self:close()
        if pending and pending.callback then
          pending.callback(err)
        end
        self:_emit_notification({
          method = "omniac/error",
          params = {
            message = "initialize failed",
            error = err,
          },
        })
        return
      end

      local agent_version = type(result) == "table" and result.protocolVersion or nil
      if agent_version ~= configured_version then
        local pending = self.pending_prompt
        self.pending_prompt = nil
        local version_error = {
          message = "incompatible ACP protocol version: agent returned "
            .. tostring(agent_version)
            .. " (supported: "
            .. tostring(configured_version)
            .. ")",
        }
        self:close()
        if pending and pending.callback then
          pending.callback(version_error)
        end
        self:_emit_notification({
          method = "omniac/error",
          params = {
            message = "initialize failed",
            error = version_error,
          },
        })
        return
      end

      if self.config.debug then
        self:_emit_notification({
          method = "omniac/initialize",
          params = result,
        })
      end

      self.agent_capabilities = normalize.agent_capabilities(result)

      self:_setup_session(function(session_err, session_result, session_method)
        if session_err then
          local pending = self.pending_prompt
          self.pending_prompt = nil
          self:close()
          if pending and pending.callback then
            pending.callback(session_err)
          end
          self:_emit_notification({
            method = "omniac/error",
            params = {
              message = (session_method or "session setup") .. " failed",
              error = session_err,
            },
          })
          return
        end

        self.session_id = normalize.session_id(session_result) or self.session_id
        self:_apply_session_state(session_result)

        local function finish_session_start()
          self:_emit_notification({
            method = "omniac/session_started",
            params = vim.tbl_extend("force", result_table(session_result), {
              sessionId = self.session_id,
              method = session_method,
            }),
          })

          self:_flush_pending_prompt()
        end

        if session_method ~= "session/new" then
          finish_session_start()
          return
        end

        self:_set_session_mode(function(mode_err)
          if mode_err then
            local pending = self.pending_prompt
            self.pending_prompt = nil
            self:close()
            if pending and pending.callback then
              pending.callback(mode_err)
            end
            self:_emit_notification({
              method = "omniac/error",
              params = {
                message = "session/set_mode failed",
                error = mode_err,
              },
            })
            return
          end

          finish_session_start()
        end)
      end)
    end)

    return self
  end

  function state:prompt(text, params, callback)
    local request_params = deepcopy(params or {})
    request_params.sessionId = request_params.sessionId or self.session_id
    request_params.prompt = request_params.prompt
      or {
        {
          type = "text",
          text = text,
        },
      }

    for _, item in ipairs(request_params.prompt or {}) do
      if type(item) == "table" and item.type == "image" and not self:supports_prompt_capability("image") then
        if callback then
          callback({
            message = "agent does not support image prompts",
          })
        end
        return
      end
      if
        type(item) == "table"
        and item.type == "resource"
        and not self:supports_prompt_capability("embeddedContext")
      then
        if callback then
          callback({
            message = "agent does not support embedded context",
          })
        end
        return
      end
    end

    local function send_prompt()
      self.turn_sequence = self.turn_sequence + 1
      self.active_turn_id = self.turn_sequence
      self.response_chunks = {}
      self.response_emitted = false
      self.response_streamed = false
      self:_emit_notification({
        method = "omniac/prompt_started",
        params = {
          sessionId = self.session_id,
          turnId = self.active_turn_id,
        },
      })
      self.transport:request("session/prompt", request_params, function(err, result)
        if err then
          local turn_id = self.active_turn_id
          self.active_turn_id = nil
          self:_emit_notification({
            method = "omniac/prompt_failed",
            params = {
              sessionId = self.session_id,
              turnId = turn_id,
              error = err,
            },
          })
          if callback then
            callback(err, nil, result)
          end
          return
        end

        self:_emit_response(result, self.active_turn_id)

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
    self.closing = true
    if self.transport then
      self.transport:close()
    end
    logging.flush(self.config)
    self.running = false
    self.transport = nil
    self.session_id = nil
    self.response_chunks = {}
    self.response_emitted = false
    self.response_streamed = false
    self.edit_tool_calls = {}
    self.pending_prompt = nil
    self.active_turn_id = nil
  end

  return state
end

return M
