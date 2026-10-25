local transport = require("omniac.transport")
local filesystem = require("omniac.filesystem")

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

local function extract_response_result_text(result)
  if type(result) ~= "table" then
    return nil
  end

  for _, key in ipairs({ "text", "delta", "message", "content", "value" }) do
    local found = extract_text(result[key])
    if found and found ~= "" then
      return found
    end
  end

  local content_items = result.contentItems or result.content_items
  if type(content_items) == "table" then
    for _, item in ipairs(content_items) do
      local found = extract_text(item)
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

local function log_path(config)
  config = config or {}
  if not config.debug then
    return nil
  end

  config.logs = config.logs or {}
  local log_config = config.logs
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

local protocol_log_queues = {}
local protocol_log_scheduled = {}

local function flush_protocol_log(path)
  local lines = protocol_log_queues[path]
  protocol_log_queues[path] = nil
  protocol_log_scheduled[path] = nil
  if lines and #lines > 0 then
    pcall(vim.fn.writefile, lines, path, "a")
  end
end

local function flush_pending_protocol_log(config)
  local path = config and config.logs and config.logs._path
  if path and protocol_log_queues[path] then
    flush_protocol_log(path)
  end
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
    protocol_log_queues[path] = protocol_log_queues[path] or {}
    table.insert(protocol_log_queues[path], encoded)
    if not protocol_log_scheduled[path] then
      protocol_log_scheduled[path] = true
      vim.schedule(function()
        flush_protocol_log(path)
      end)
    end
  end
end

local function debug_payload_summary(event, payload)
  if type(payload) ~= "table" then
    return payload
  end

  if event == "notification" or event == "request" or event == "response" then
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

local function prompt_capability(capabilities, name)
  local prompt_capabilities = capabilities.promptCapabilities or capabilities.prompt_capabilities or {}
  return prompt_capabilities[name] == true
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

  for _, option in ipairs(config_options) do
    if
      type(option) == "table"
      and (option.category == "mode" or option.id == "mode")
      and option.type == "select"
      and type(option.options) == "table"
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

local function model_state_from_config_options(config_options)
  if type(config_options) ~= "table" then
    return nil
  end

  for _, option in ipairs(config_options) do
    if
      type(option) == "table"
      and (option.category == "model" or option.id == "model")
      and option.type == "select"
      and type(option.options) == "table"
    then
      local models = {}
      for _, value in ipairs(option.options) do
        local id = type(value) == "table" and (value.value or value.id) or value
        if type(id) == "string" and id ~= "" then
          table.insert(models, {
            id = id,
            name = type(value) == "table" and (value.name or id) or id,
            description = type(value) == "table" and value.description or nil,
          })
        end
      end

      return {
        configId = option.id,
        currentModelId = option.currentValue or option.current_value,
        availableModels = models,
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
  for _, mode in ipairs(available) do
    if type(mode) == "table" and type(mode.id) == "string" and mode.id ~= "" then
      table.insert(result, {
        id = mode.id,
        name = mode.name or mode.id,
        description = mode.description,
      })
    end
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

local function model_name(model_state)
  if type(model_state) ~= "table" then
    return nil
  end

  local current = model_state.currentModelId
  for _, model in ipairs(model_state.availableModels or {}) do
    if model.id == current then
      return model.name or model.id
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

local function raw_output_text(raw_output)
  if type(raw_output) == "string" then
    return raw_output
  end
  if type(raw_output) ~= "table" then
    return nil
  end

  for _, key in ipairs({ "output", "stdout", "stderr", "text", "message", "content" }) do
    local value = raw_output[key]
    if type(value) == "string" and value ~= "" then
      return value
    end
  end

  return extract_text(raw_output)
end

local function tool_result(update)
  if type(update) ~= "table" then
    return nil
  end

  local raw_input = type(update.rawInput) == "table" and update.rawInput or {}
  local raw_output = update.rawOutput or update.raw_output
  local output = raw_output_text(raw_output) or extract_text(update.content)
  if type(output) ~= "string" or output == "" then
    return nil
  end

  local raw_output_table = type(raw_output) == "table" and raw_output or {}
  local meta = type(update._meta) == "table" and update._meta or {}
  local terminal_exit = type(meta.terminal_exit) == "table" and meta.terminal_exit or {}

  return {
    toolCallId = update.toolCallId,
    kind = update.kind,
    status = update.status,
    title = update.title or raw_input.command or update.kind or update.toolCallId,
    command = raw_input.command or raw_input.cmd or update.title,
    cwd = raw_input.cwd,
    output = output,
    exitCode = raw_output_table.exit_code
      or raw_output_table.exitCode
      or terminal_exit.exit_code
      or terminal_exit.exitCode,
  }
end

local function update_content_items(update)
  if type(update) ~= "table" or type(update.content) ~= "table" then
    return {}
  end

  return update.content
end

local function is_file_update_item(item)
  local meta_kind = type(item) == "table" and type(item._meta) == "table" and item._meta.kind or nil
  return type(item) == "table"
    and (item.type == "diff" or meta_kind == "update" or meta_kind == "add")
    and type(item.path) == "string"
    and type(item.newText) == "string"
end

local function update_old_text(item)
  return type(item.oldText) == "string" and item.oldText or ""
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
    append_protocol_log(self.config, event, payload)
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

  function state:supports_session_capability(name)
    return session_capability(self.agent_capabilities, name)
  end

  function state:supports_prompt_capability(name)
    return prompt_capability(self.agent_capabilities, name)
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
      append_protocol_log(self.config, "response", response)
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
      local update_type = update and (update.sessionUpdate or update.type)

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

      if update_type == "usage_update" or update_type == "usageUpdate" then
        self:_emit_notification({
          method = "omniac/usage_update",
          params = {
            sessionId = self.session_id,
            used = update.used,
            size = update.size,
            cost = update.cost,
          },
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

      local edit_call = update and update.toolCallId and self.edit_tool_calls[update.toolCallId] or nil
      if update and update.kind == "edit" and update.toolCallId and type(edit_call) ~= "table" then
        edit_call = {
          turn_id = self.active_turn_id,
          files = {},
          order = {},
          title = update.title,
        }
        self.edit_tool_calls[update.toolCallId] = edit_call
      end

      local is_edit_update = type(edit_call) == "table"

      if
        (update_type == "tool_call" or update_type == "tool_call_update")
        and not is_edit_update
        and (update.status == "completed" or update.status == "failed")
      then
        local result = tool_result(update)
        if result then
          self:_emit_notification({
            method = "omniac/tool_result",
            params = result,
          })
        end
      end

      if (update_type == "tool_call" or update_type == "tool_call_update") and is_edit_update then
        edit_call.title = update.title or edit_call.title
        for _, item in ipairs(update_content_items(update)) do
          if is_file_update_item(item) then
            local file = edit_call.files[item.path]
            if not file then
              local completed_without_snapshot = update.status == "completed"
              file = {
                path = item.path,
                oldText = completed_without_snapshot and update_old_text(item) or filesystem.read_disk_content(
                  item.path
                ) or update_old_text(item),
                newText = item.newText,
                operation = type(item._meta) == "table" and item._meta.kind or nil,
                captured_before = not completed_without_snapshot,
              }
              edit_call.files[item.path] = file
              table.insert(edit_call.order, item.path)
            else
              file.newText = item.newText
              file.operation = (type(item._meta) == "table" and item._meta.kind) or file.operation
            end

            if update.status ~= "completed" and update.status ~= "failed" then
              self:_emit_notification({
                method = "omniac/permission_diff",
                params = {
                  sessionId = self.session_id,
                  turnId = edit_call.turn_id,
                  path = item.path,
                  oldText = update_old_text(item),
                  newText = item.newText,
                  toolCallId = update.toolCallId,
                  title = update.title,
                  status = update.status,
                },
              })
            end
          end
        end

        if update.status == "completed" then
          for _, path in ipairs(edit_call.order) do
            local file = edit_call.files[path]
            local new_text = file.newText
            if file.captured_before then
              new_text = filesystem.read_disk_content(path)
              if new_text == nil and file.operation == "delete" then
                new_text = ""
              end
              new_text = new_text or file.newText
            end
            self:_emit_notification({
              method = "omniac/file_update",
              params = {
                sessionId = self.session_id,
                turnId = edit_call.turn_id,
                path = path,
                oldText = file.oldText,
                newText = new_text,
                operation = file.operation,
                toolCallId = update.toolCallId,
                title = edit_call.title,
                status = update.status,
                error = update.error or update.rawOutput,
              },
            })
          end
        elseif update.status == "failed" then
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

      if update_type == "agent_thought_chunk" or update_type == "agentThoughtChunk" then
        local text = extract_text(update.content or update.delta or update)
        local title = type(text) == "string" and text:match("^%s*%*%*(.-)%*%*%s*$") or nil
        if title and title ~= "" and self.active_turn_id ~= nil then
          self:_emit_notification({
            method = "omniac/thought_activity",
            params = {
              text = title,
              sessionId = self.session_id,
              turnId = self.active_turn_id,
            },
          })
        end
        return
      end

      if update_type == "agent_message_chunk" or update_type == "agentMessageChunk" then
        local text = extract_text(update.content or update.delta or update)
        if text and text ~= "" then
          if self.active_turn_id ~= nil then
            table.insert(self.response_chunks, text)
            self.response_streamed = true
          end
          self:_emit_notification({
            method = "omniac/response_chunk",
            params = {
              text = text,
              sessionId = self.session_id,
              turnId = self.active_turn_id,
            },
          })
        end
        return
      end

      if update_type == "agent_message_final" or update_type == "agentMessageFinal" then
        local text = extract_text(update.content or update.delta or update)
        if text and text ~= "" then
          if self.active_turn_id ~= nil then
            table.insert(self.response_chunks, text)
            self.response_streamed = true
          end
          self:_emit_notification({
            method = "omniac/response_chunk",
            params = {
              text = text,
              sessionId = self.session_id,
              turnId = self.active_turn_id,
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

      local session_id = session_id_from_result(result)
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
        currentModelName = model_name(self.session_model),
        availableModels = self.session_model.availableModels or {},
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
    if type(config_options) == "table" then
      self.config_options = config_options
      self:_emit_notification({
        method = "omniac/session_config_update",
        params = { configOptions = deepcopy(config_options) },
      })
    end

    local model_state = model_state_from_config_options(config_options)
    if model_state then
      self.session_model = model_state
      self:_emit_session_model_update()
    end

    local mode_state = mode_state_from_config_options(config_options)
    if mode_state then
      self.session_mode = mode_state
      self:_emit_session_mode_update()
    else
      mode_state = mode_state_from_modes(result.modes or session.modes)
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

    local current = collaboration.currentValue or collaboration.current_value
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
    self.last_stop_reason = result and (result.stopReason or result.stop_reason) or nil

    local text = table.concat(self.response_chunks)
    self.response_chunks = {}

    if (not text or text == "") and result then
      text = extract_response_result_text(result)
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
          append_protocol_log(self.config, message.id ~= nil and "client_request" or "client_notification", message)
        elseif direction == "recv" and message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
          append_protocol_log(self.config, "agent_response", message)
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
        flush_pending_protocol_log(self.config)
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

      self.agent_capabilities = agent_capabilities(result)

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

        self.session_id = session_id_from_result(session_result) or self.session_id
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
    flush_pending_protocol_log(self.config)
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
