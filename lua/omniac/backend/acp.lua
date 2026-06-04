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

local function is_json_null(value)
  return vim.NIL ~= nil and value == vim.NIL
end

local function log_path(config)
  config = config or {}
  config.logs = config.logs or {}
  local log_config = config.logs
  if log_config.enabled == false then
    return nil
  end
  if log_config._path then
    return log_config._path
  end

  local dir = log_config.dir or "logs"
  if not dir:match("^/") then
    dir = (vim.loop.cwd() or ".") .. "/" .. dir
  end
  pcall(vim.fn.mkdir, dir, "p")
  log_config._path = string.format("%s/acp-%s.jsonl", dir, os.date("%Y%m%d-%H%M%S"))
  return log_config._path
end

local function append_protocol_log(config, event, payload)
  local path = log_path(config)
  if not path then
    return
  end

  local entry = {
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event = event,
    payload = payload,
  }
  local ok, encoded = pcall(vim.json.encode, entry)
  if ok then
    pcall(vim.fn.writefile, { encoded }, path, "a")
  end
end

local function echomsg(text)
  vim.schedule(function()
    vim.api.nvim_echo({ { text, "Comment" } }, true, {})
  end)
end

local function inspect_short(value)
  local text = vim.inspect(value)
  text = text:gsub("%s+", " ")
  if #text > 900 then
    return text:sub(1, 900) .. "..."
  end
  return text
end

local function sorted_keys(value)
  if type(value) ~= "table" then
    return {}
  end

  local keys = {}
  for key, _ in pairs(value) do
    table.insert(keys, tostring(key))
  end
  table.sort(keys)
  return keys
end

local function agent_capabilities(result)
  return (result and (result.agentCapabilities or result.agent_capabilities)) or {}
end

local function has_load_session(capabilities)
  return capabilities.loadSession == true or capabilities.load_session == true
end

local function session_capability(capabilities, name)
  local session_capabilities = capabilities.sessionCapabilities or capabilities.session_capabilities or {}
  return session_capabilities[name] ~= nil
end

local function session_id_from_result(result)
  if type(result) ~= "table" then
    return nil
  end

  return result.sessionId
    or result.session_id
    or (result.session and (result.session.id or result.session.sessionId or result.session.session_id))
    or result.id
end

local function result_table(result)
  if type(result) == "table" then
    return result
  end

  return {}
end

local function mode_state_from_config_options(config_options)
  if type(config_options) ~= "table" then
    return nil
  end

  local function looks_like_planning_modes(options)
    for _, option in ipairs(options or {}) do
      local value = type(option) == "table" and (option.value or option.id) or option
      value = type(value) == "string" and value:lower() or ""
      if value == "plan" or value == "planning" then
        return true
      end
    end
    return false
  end

  for _, option in ipairs(config_options) do
    if
      type(option) == "table"
      and (option.category == "mode" or option.id == "mode")
      and option.type == "select"
      and type(option.options) == "table"
      and looks_like_planning_modes(option.options)
    then
      local modes = {}
      for _, value in ipairs(option.options) do
        local id = type(value) == "table" and (value.value or value.id) or nil
        if type(value) == "table" and type(id) == "string" and id ~= "" then
          table.insert(modes, {
            id = id,
            name = value.name or id,
            description = value.description,
          })
        end
      end

      return {
        source = "config",
        configId = option.id,
        currentModeId = option.currentValue or option.current_value,
        availableModes = modes,
      }
    end
  end

  return nil
end

local function mode_state_from_modes(modes)
  if type(modes) ~= "table" then
    return nil
  end

  local available = modes.availableModes or modes.available_modes or {}
  if type(available) ~= "table" then
    available = {}
  end

  local result = {}
  local has_planning_mode = false
  for _, mode in ipairs(available) do
    if type(mode) == "table" and type(mode.id) == "string" and mode.id ~= "" then
      local id = mode.id:lower()
      if id == "plan" or id == "planning" then
        has_planning_mode = true
      end
      table.insert(result, {
        id = mode.id,
        name = mode.name or mode.id,
        description = mode.description,
      })
    end
  end
  if not has_planning_mode then
    return nil
  end

  return {
    source = "modes",
    currentModeId = modes.currentModeId or modes.current_mode_id,
    availableModes = result,
  }
end

local function mode_name(mode_state)
  if type(mode_state) ~= "table" then
    return nil
  end

  local current = mode_state.currentModeId
  for _, mode in ipairs(mode_state.availableModes or {}) do
    if mode.id == current then
      return mode.name or mode.id
    end
  end
  return current
end

local function value_brief(value)
  if type(value) == "string" then
    local text = value:gsub("%s+", " ")
    if #text > 80 then
      return string.format("<string len=%d %q...>", #value, text:sub(1, 80))
    end
    return string.format("%q", text)
  end

  if type(value) == "table" then
    return "{" .. table.concat(sorted_keys(value), ",") .. "}"
  end

  return tostring(value)
end

local function update_summary(update)
  if type(update) ~= "table" then
    return value_brief(update)
  end

  local parts = {
    "type=" .. tostring(update.sessionUpdate or update.type),
    "kind=" .. tostring(update.kind),
    "status=" .. tostring(update.status),
    "title=" .. value_brief(update.title),
    "toolCallId=" .. tostring(update.toolCallId),
    "keys=" .. table.concat(sorted_keys(update), ","),
  }

  local content = update.content
  if type(content) == "table" then
    for index, item in ipairs(content) do
      local item_parts = {
        string.format("content[%d].keys=%s", index, table.concat(sorted_keys(item), ",")),
      }

      if type(item._meta) == "table" then
        table.insert(item_parts, "meta.keys=" .. table.concat(sorted_keys(item._meta), ","))
        table.insert(item_parts, "meta.kind=" .. tostring(item._meta.kind))
      end

      for _, key in ipairs({
        "path",
        "filePath",
        "file_path",
        "uri",
        "oldText",
        "newText",
        "old_text",
        "new_text",
      }) do
        if item[key] ~= nil then
          table.insert(item_parts, key .. "=" .. value_brief(item[key]))
        end
      end

      table.insert(parts, table.concat(item_parts, " "))
    end
  end

  for _, key in ipairs({
    "locations",
    "rawInput",
    "rawOutput",
    "_meta",
  }) do
    if update[key] ~= nil then
      table.insert(parts, key .. "=" .. value_brief(update[key]))
    end
  end

  return table.concat(parts, " | ")
end

local function tool_activity(update)
  if type(update) ~= "table" then
    return nil
  end

  local raw_input = type(update.rawInput) == "table" and update.rawInput or {}
  local raw_output = type(update.rawOutput) == "table" and update.rawOutput or {}
  local meta = type(update._meta) == "table" and update._meta or {}
  local terminal_exit = type(meta.terminal_exit) == "table" and meta.terminal_exit or {}
  local title = update.title or raw_input.command or update.kind or update.toolCallId

  return {
    toolCallId = update.toolCallId,
    kind = update.kind,
    status = update.status,
    title = title,
    exitCode = raw_output.exit_code or raw_output.exitCode or terminal_exit.exit_code or terminal_exit.exitCode,
  }
end

local function update_content_items(update)
  if type(update) ~= "table" or type(update.content) ~= "table" then
    return {}
  end

  return update.content
end

local function is_file_update_item(item)
  return type(item) == "table"
    and type(item._meta) == "table"
    and item._meta.kind == "update"
    and type(item.path) == "string"
    and type(item.oldText) == "string"
    and type(item.newText) == "string"
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
    response_streamed = false,
    pending_prompt = nil,
    edit_tool_calls = {},
    debug_log = {},
    agent_capabilities = {},
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
    append_protocol_log(self.config, event, payload)
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
      self:_emit_notification({
        method = "_transport/debug",
        params = entry,
      })
    end

    if self.config.protocol_trace ~= false and (event == "request" or event == "notification") then
      local method = payload and payload.method or "?"
      local params = payload and payload.params or {}
      if method ~= "session/update" then
        echomsg(string.format("[omniac acp %s] %s %s", event, tostring(method), inspect_short(params)))
      end
    end
  end

  function state:get_debug_log()
    return deepcopy(self.debug_log)
  end

  function state:supports_session_capability(name)
    return session_capability(self.agent_capabilities, name)
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
      append_protocol_log(self.config, "response", response)
      self.transport:respond(response.id, response.result, response.error)
    end

    if self.request_handler then
      self:_emit(self.request_handler, message, reply)
      return
    end

    if method == "session/request_permission" then
      echomsg("[omniac acp fallback] session/request_permission cancelled by backend fallback")
      reply({
        outcome = {
          outcome = "cancelled",
        },
      })
      return
    end

    echomsg("[omniac acp fallback] unhandled request " .. tostring(method) .. " -> {}")
    reply({})
  end

  function state:_handle_notification(message)
    local method = message and message.method
    local params = message and message.params or {}

    if method == "session/update" then
      local update = params.update or params
      local update_type = update and (update.sessionUpdate or update.type)
      if
        self.config.protocol_trace ~= false
        and update_type ~= "agent_message_chunk"
        and update_type ~= "agentMessageChunk"
      then
        echomsg("[omniac acp session/update] " .. update_summary(update))
      end

      if update_type == "tool_call" or update_type == "tool_call_update" then
        self:_emit_notification({
          method = "omniac/tool_activity",
          params = tool_activity(update),
        })
      end

      if update_type == "available_commands_update" or update_type == "availableCommandsUpdate" then
        self:_emit_notification({
          method = "omniac/available_commands_update",
          params = {
            sessionId = self.session_id,
            availableCommands = update.availableCommands or update.available_commands or {},
          },
        })
        return
      end

      if update_type == "config_option_update" or update_type == "configOptionUpdate" then
        self:_apply_session_state({
          configOptions = update.configOptions or update.config_options,
        })
        return
      end

      if update_type == "current_mode_update" or update_type == "currentModeUpdate" then
        if self.session_mode then
          self.session_mode.currentModeId = update.modeId or update.mode_id or self.session_mode.currentModeId
        else
          self.session_mode = {
            source = "modes",
            currentModeId = update.modeId or update.mode_id,
            availableModes = {},
          }
        end
        self:_emit_session_mode_update()
        return
      end

      if update_type == "tool_call" and update and update.kind == "edit" and update.toolCallId then
        self.edit_tool_calls[update.toolCallId] = true
      end

      local is_edit_update = update
        and update.toolCallId
        and (update.kind == "edit" or self.edit_tool_calls[update.toolCallId])

      if (update_type == "tool_call" or update_type == "tool_call_update") and is_edit_update then
        local emitted_file_update = false
        for _, item in ipairs(update_content_items(update)) do
          if is_file_update_item(item) then
            emitted_file_update = true
            if update.status == "completed" then
              echomsg("[omniac acp edit] file update completed " .. item.path)
              self:_emit_notification({
                method = "omniac/file_update",
                params = {
                  path = item.path,
                  oldText = item.oldText,
                  newText = item.newText,
                  toolCallId = update.toolCallId,
                  title = update.title,
                  status = update.status,
                  error = update.error or update.rawOutput,
                },
              })
            elseif update.status ~= "failed" then
              self:_emit_notification({
                method = "omniac/permission_diff",
                params = {
                  path = item.path,
                  oldText = item.oldText,
                  newText = item.newText,
                  toolCallId = update.toolCallId,
                  title = update.title,
                  status = update.status,
                },
              })
            end
          end
        end
        if update.status == "failed" and not emitted_file_update then
          echomsg("[omniac acp edit] edit failed " .. tostring(update.toolCallId))
          self:_emit_notification({
            method = "omniac/edit_failed",
            params = {
              toolCallId = update.toolCallId,
              title = update.title,
              error = update.error or update.rawOutput,
            },
          })
        end
        if update.status == "completed" or update.status == "failed" then
          self.edit_tool_calls[update.toolCallId] = nil
        end
        return
      end

      if update_type == "agent_message_chunk" or update_type == "agentMessageChunk" then
        local text = extract_text(update.content or update.delta or update)
        if text and text ~= "" then
          self.response_buffer = self.response_buffer .. text
          self.response_streamed = true
          self:_emit_notification({
            method = "omniac/response_chunk",
            params = {
              text = text,
              sessionId = self.session_id,
            },
          })
        end
        return
      end

      if update_type == "agent_message_final" or update_type == "agentMessageFinal" then
        local text = extract_text(update.content or update.delta or update)
        if text and text ~= "" then
          self.response_buffer = self.response_buffer .. text
          self.response_streamed = true
          self:_emit_notification({
            method = "omniac/response_chunk",
            params = {
              text = text,
              sessionId = self.session_id,
            },
          })
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

    if self.config.additionalDirectories and session_capability(self.agent_capabilities, "additionalDirectories") then
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

  function state:_list_sessions(callback, cursor, collected)
    collected = collected or {}
    local params = {
      cwd = ((self.config.agent or {}).cwd or vim.loop.cwd()),
    }
    if cursor then
      params.cursor = cursor
    end

    self.transport:request("session/list", params, function(err, result)
      if err then
        callback(err, nil)
        return
      end

      for _, session in ipairs((result and result.sessions) or {}) do
        table.insert(collected, session)
      end

      local next_cursor = result and (result.nextCursor or result.next_cursor)
      if next_cursor and not is_json_null(next_cursor) and next_cursor ~= "" then
        self:_list_sessions(callback, next_cursor, collected)
        return
      end

      callback(nil, collected)
    end)
  end

  function state:list_sessions(callback)
    self:_list_sessions(callback)
  end

  function state:_create_session(callback)
    self.transport:request("session/new", self:_session_params(), callback)
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
          self.session_id = session_id_from_result(result) or self.session_id
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
      if not has_load_session(self.agent_capabilities) then
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

    if not session_capability(self.agent_capabilities, "resume") then
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
        currentModeName = mode_name(self.session_mode),
        availableModes = self.session_mode.availableModes or {},
      },
    })
  end

  function state:_apply_session_state(result)
    if type(result) ~= "table" then
      return
    end

    local session = type(result.session) == "table" and result.session or {}
    local config_options = result.configOptions
      or result.config_options
      or session.configOptions
      or session.config_options
    local mode_state = mode_state_from_config_options(config_options)
    if mode_state then
      self.config_options = config_options
      self.session_mode = mode_state
      self:_emit_session_mode_update()
      return
    end

    mode_state = mode_state_from_modes(result.modes or session.modes)
    if mode_state then
      self.session_mode = mode_state
      self:_emit_session_mode_update()
    end
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
        message = "agent did not advertise planning modes",
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

    self.transport:request("session/cancel", {
      sessionId = self.session_id,
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
      if self.response_streamed then
        self:_emit_notification({
          method = "omniac/response_completed",
          params = {
            sessionId = self.session_id,
            result = result,
          },
        })
      else
        self:_emit_notification({
          method = "omniac/response",
          params = {
            text = text,
            sessionId = self.session_id,
            result = result,
          },
        })
      end
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
        self:_emit_notification({
          method = "omniac/error",
          params = {
            message = "initialize failed",
            error = err,
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

      self.agent_capabilities = agent_capabilities(result)

      self:_setup_session(function(session_err, session_result, session_method)
        if session_err then
          self:_emit_notification({
            method = "omniac/error",
            params = {
              message = (session_method or "session setup") .. " failed",
              error = session_err,
            },
          })
          return
        end

        self.session_id = session_id_from_result(session_result) or self.session_id
        self:_apply_session_state(session_result)

        self:_set_session_mode(function(mode_err)
          if mode_err then
            self:_emit_notification({
              method = "omniac/error",
              params = {
                message = "session/set_mode failed",
                error = mode_err,
              },
            })
            return
          end

          self:_emit_notification({
            method = "omniac/session_started",
            params = vim.tbl_extend("force", result_table(session_result), {
              sessionId = self.session_id,
              method = session_method,
            }),
          })

          self:_flush_pending_prompt()
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

    local function send_prompt()
      self.response_buffer = ""
      self.response_emitted = false
      self.response_streamed = false
      self:_emit_notification({
        method = "omniac/prompt_started",
        params = {
          sessionId = self.session_id,
        },
      })
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
    self.response_streamed = false
    self.edit_tool_calls = {}
    self.pending_prompt = nil
  end

  return state
end

return M
