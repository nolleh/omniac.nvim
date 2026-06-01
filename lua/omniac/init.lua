local config = require("omniac.config")
local selection = require("omniac.selection")
local mentions = require("omniac.mentions")
local transport = require("omniac.transport")
local acp_backend = require("omniac.backend.acp")
local ui = require("omniac.ui")
local approval = require("omniac.approval")

local M = {
  config = config.defaults,
  transport = nil,
  backend = nil,
  response_buffer = "",
}

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

  for _, key in ipairs({ "text", "delta", "message", "content", "value" }) do
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

local function build_prompt(extra)
  local ctx = selection.get_context()
  local prompt = {}

  if extra and extra ~= "" then
    table.insert(prompt, extra)
  end

  if ctx.selection and ctx.selection ~= "" then
    table.insert(prompt, "Selected code:\n" .. ctx.selection)
  end

  if ctx.bufname and ctx.bufname ~= "" then
    table.insert(prompt, "Current file: " .. ctx.bufname)
  end

  return table.concat(prompt, "\n\n")
end

local function build_granted_permissions(profile)
  if not profile then
    return {
      fileSystem = nil,
      network = nil,
    }
  end

  return {
    fileSystem = profile.fileSystem,
    network = profile.network,
  }
end

local function first_tool_answer(question)
  if not question or not question.options or #question.options == 0 then
    return { answers = {} }
  end

  local option = question.options[1]
  if option and option.label then
    return { answers = { option.label } }
  end

  return { answers = {} }
end

local function is_default_codex_command(cmd)
  return vim.deep_equal(cmd, { "codex", "app-server" })
end

local function resolve_backend_kind(kind)
  if kind and kind ~= "auto" then
    return kind
  end

  if vim.fn.executable("codex-acp") == 1 then
    return "acp"
  end

  return "codex"
end

local function register_command(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

local function echomsg(text)
  vim.api.nvim_echo({ { text, "Comment" } }, true, {})
end

local function inspect_short(value)
  local text = vim.inspect(value)
  text = text:gsub("%s+", " ")
  if #text > 900 then
    return text:sub(1, 900) .. "..."
  end
  return text
end

function M.setup(opts)
  M.config = config.merge(opts)
  M.config.backend = M.config.backend or {}
  M.config.backend.kind = resolve_backend_kind(M.config.backend.kind)
  if M.config.backend.kind == "acp" and is_default_codex_command(M.config.agent and M.config.agent.cmd or {}) then
    M.config.agent.cmd = { "codex-acp" }
  end
  if M.config.backend.kind == "acp" then
    M.config.agent.auto_initialize = false
    M.config.agent.env = M.config.agent.env or {}
    M.config.agent.env.INITIAL_AGENT_MODE = M.config.agent.env.INITIAL_AGENT_MODE or M.config.agent.mode_id or "read-only"
  end
  M.response_buffer = ""

  local function connect()
    M.connect()
  end

  local function disconnect()
    M.disconnect()
  end

  local function ask(cmd)
    M.ask(cmd.args)
  end

  local function debug()
    if not M.config.debug then
      vim.notify("debug is disabled", vim.log.levels.WARN, { title = "omniac debug" })
      return
    end

    local active = M.backend or M.transport
    if active and active.get_debug_log then
      vim.notify(vim.inspect(active:get_debug_log()), vim.log.levels.INFO, { title = "omniac debug" })
    else
      vim.notify("no active transport", vim.log.levels.WARN, { title = "omniac debug" })
    end
  end

  local function ask_files(cmd)
    local paths = {}
    for path in string.gmatch(cmd.args, "[^,%s]+") do
      table.insert(paths, path)
    end
    M.ask_with_files("", paths)
  end

  local function diff(cmd)
    local path = vim.fn.expand(cmd.args)
    if path == "" then
      error("OmniacDiff requires a file path")
    end

    M.open_file_diff(path, nil, { title = M.config.ui.diff_title })
  end

  local function open_chat()
    M.open_chat()
  end

  register_command("Omniac", open_chat, {})
  register_command("OmniacConnect", connect, {})
  register_command("OmniacDisconnect", disconnect, {})
  register_command("OmniacAsk", ask, { nargs = "?" })
  register_command("OmniacDebug", debug, {})
  register_command("OmniacAskFiles", ask_files, { nargs = "?" })
  register_command("OmniacDiff", diff, { nargs = 1, complete = "file" })
  register_command("OmniacDiffAccept", function()
    require("omniac.diff").accept_current_review()
  end, {})
  register_command("OmniacDiffDeny", function()
    require("omniac.diff").deny_current_review()
  end, {})
end

function M.open_chat()
  ui.open(M.config, function(text)
    ui.submit(text, M.config)
    if not M.backend and not M.transport then
      ui.set_status("connecting", M.config)
      local ok, err = pcall(M.connect)
      if not ok then
        ui.add_message("Error", err, M.config)
        ui.set_status("error", M.config)
        return
      end
    end
    local ok, err = pcall(M.ask, text)
    if not ok then
      ui.add_message("Error", err, M.config)
      ui.set_status("error", M.config)
    end
  end)
end

function M.ask(extra)
  local prompt = build_prompt(extra)
  if M.config.backend and M.config.backend.kind == "acp" and M.backend then
    M.backend:prompt(prompt, nil, function(err, result)
      if err then
        vim.notify(vim.inspect(err), vim.log.levels.ERROR, { title = "omniac response" })
        return
      end

      if result and M.config.debug then
        vim.notify(vim.inspect(result), vim.log.levels.INFO, { title = "omniac response" })
      end
    end)
    return prompt
  end

  if M.transport then
    M.transport:prompt(prompt, nil, function(err, result)
      if err then
        vim.notify(vim.inspect(err), vim.log.levels.ERROR, { title = "omniac response" })
        return
      end

      if result and M.config.debug then
        vim.notify(vim.inspect(result), vim.log.levels.INFO, { title = "omniac response" })
      end
    end)
    return prompt
  end

  vim.notify(prompt, vim.log.levels.INFO, { title = "omniac prompt" })
  return prompt
end

function M.ask_with_files(extra, paths)
  local prompt = build_prompt(extra)
  local file_mentions = mentions.collect(paths)

  if #file_mentions > 0 then
    prompt = prompt .. "\n\nFiles:\n" .. table.concat(file_mentions, "\n")
  end

  vim.notify(prompt, vim.log.levels.INFO, { title = "omniac prompt" })
  return prompt
end

function M.open_diff(before_lines, after_lines, opts)
  local diff = require("omniac.diff")
  return diff.open(before_lines, after_lines, opts)
end

function M.open_file_diff(path, proposed_lines, opts)
  local diff = require("omniac.diff")
  return diff.open_file(path, proposed_lines, opts)
end

function M.connect()
  if M.config.backend and M.config.backend.kind == "acp" then
    local client = acp_backend.new(M.config)
    client
      :on_request(function(message, reply)
        local method = message and message.method
        local params = message and message.params or {}
        echomsg("[omniac acp request handler] " .. tostring(method) .. " " .. inspect_short(params))

        local function logged_reply(result, err)
          local payload = err or result or {}
          echomsg("[omniac acp reply] " .. tostring(method) .. " " .. inspect_short(payload))
          return reply(result, err)
        end

        if method == "session/request_permission" then
          approval.review_acp_permission(params, logged_reply, M.config)
          return
        end

        echomsg("[omniac acp request handler] unhandled " .. tostring(method) .. " -> {}")
        logged_reply({})
      end)
      :on_notification(function(message)
        local method = message and message.method
        local params = message and message.params or {}
        if method == "omniac/file_update" then
          echomsg("[omniac acp notification] omniac/file_update " .. tostring(params.path))
        elseif method == "omniac/permission_diff" then
          echomsg("[omniac acp notification] omniac/permission_diff " .. tostring(params.path))
        elseif method == "omniac/edit_failed" then
          echomsg("[omniac acp notification] omniac/edit_failed " .. tostring(params.toolCallId))
        elseif method ~= "session/update" and method ~= "omniac/response_chunk" then
          echomsg("[omniac acp notification] " .. tostring(method) .. " " .. inspect_short(params))
        end

        ui.handle_notification(message, M.config)

        if method == "omniac/permission_diff" then
          approval.attach_acp_permission_diff(params)
          return
        end

        if method == "omniac/file_update" then
          approval.apply_file_update(params)
          return
        end

        if method == "omniac/edit_failed" then
          return
        end

        if method == "omniac/response" then
          return
        end

        if method == "omniac/error" then
          vim.notify(tostring(params.message or params.error or "omniac error"), vim.log.levels.ERROR, { title = "omniac error" })
        end
      end)
      :on_exit(function(code, signal)
        ui.set_status("closed", M.config)
        vim.notify(string.format("agent exited (code=%s, signal=%s)", tostring(code), tostring(signal)), vim.log.levels.WARN, { title = "omniac exit" })
        if M.backend == client then
          M.backend = nil
        end
      end)

    M.backend = client:start()
    return M.backend
  end

  local client = transport.new(M.config)
  client
    :on_notification(function(message)
      local method = message and message.method
      local params = message and message.params or {}

      ui.handle_notification(message, M.config)

      if method == "thread/started" or method == "turn/started" then
        M.response_buffer = ""
        return
      end

      if method == "item/agentMessage/delta" or method == "item/agentMessage/final" or method == "item/agentMessage/completed" then
        local text = extract_text(params)
        if text and text ~= "" then
          M.response_buffer = M.response_buffer .. text
        end
        return
      end

      if method == "turn/completed" then
        local text = M.response_buffer
        M.response_buffer = ""

        if text and text ~= "" then
          ui.add_message("Omniac", text, M.config)
          return
        end

        local summary = extract_text(params)
        if summary and summary ~= "" then
          ui.add_message("Omniac", summary, M.config)
        end
        return
      end

      if method == "turn/error" or method == "_transport/error" then
        vim.notify(tostring(params.message or params.error or "omniac error"), vim.log.levels.ERROR, { title = "omniac error" })
      end
    end)
    :on_request(function(message, reply)
      local method = message and message.method
      local params = message and message.params or {}

      if M.config.debug then
        vim.notify("server request: " .. tostring(method), vim.log.levels.WARN, { title = "omniac request" })
      end

      if method == "item/fileChange/requestApproval" or method == "applyPatchApproval" then
        approval.review_request(method, params, reply, nil, M.config)
        return
      end

      if method == "item/commandExecution/requestApproval" then
        approval.review_request(method, params, reply, nil, M.config)
        return
      end

      if method == "item/permissions/requestApproval" then
        reply({
          permissions = build_granted_permissions(M.transport and M.transport.permission_profile or nil),
          scope = "turn",
          strictAutoReview = false,
        })
        return
      end

      if method == "item/tool/requestUserInput" then
        local answers = {}
        for _, question in ipairs(params.questions or {}) do
          answers[question.id] = first_tool_answer(question)
        end
        reply({
          answers = answers,
        })
        return
      end

      if method == "item/tool/call" then
        reply({
          success = false,
          contentItems = {
            {
              type = "inputText",
              text = "tool call not implemented by omniac.nvim yet",
            },
          },
        })
        return
      end

      if method == "mcpServer/elicitation/request" then
        reply({
          answers = {},
        })
        return
      end

      if M.config.debug then
        vim.notify("Unhandled server request method: " .. tostring(method), vim.log.levels.WARN, { title = "omniac request" })
      end
      reply({
        decision = "acceptForSession",
      })
    end)
    :on_exit(function(code, signal)
      ui.set_status("closed", M.config)
      vim.notify(string.format("agent exited (code=%s, signal=%s)", tostring(code), tostring(signal)), vim.log.levels.WARN, { title = "omniac exit" })
      if M.transport == client then
        M.transport = nil
      end
    end)

  M.transport = client:start()
  return M.transport
end

function M.disconnect()
  if M.backend then
    M.backend:close()
    M.backend = nil
  end

  if M.transport then
    M.transport:close()
    M.transport = nil
  end
end

return M
