local config = require("acpclient.config")
local selection = require("acpclient.selection")
local mentions = require("acpclient.mentions")
local transport = require("acpclient.transport")
local acp_backend = require("acpclient.backend.acp")

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

function M.setup(opts)
  M.config = config.merge(opts)
  M.config.backend = M.config.backend or {}
  M.config.backend.kind = resolve_backend_kind(M.config.backend.kind)
  if M.config.backend.kind == "acp" and is_default_codex_command(M.config.agent and M.config.agent.cmd or {}) then
    M.config.agent.cmd = { "codex-acp" }
  end
  if M.config.backend.kind == "acp" then
    M.config.agent.auto_initialize = false
  end
  M.response_buffer = ""

  vim.api.nvim_create_user_command("AcpClientConnect", function()
    M.connect()
  end, {})

  vim.api.nvim_create_user_command("AcpClientDisconnect", function()
    M.disconnect()
  end, {})

  vim.api.nvim_create_user_command("AcpClientAsk", function(cmd)
    M.ask(cmd.args)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AcpClientDebug", function()
    if not M.config.debug then
      vim.notify("debug is disabled", vim.log.levels.WARN, { title = "acpclient debug" })
      return
    end

    local active = M.backend or M.transport
    if active and active.get_debug_log then
      vim.notify(vim.inspect(active:get_debug_log()), vim.log.levels.INFO, { title = "acpclient debug" })
    else
      vim.notify("no active transport", vim.log.levels.WARN, { title = "acpclient debug" })
    end
  end, {})

  vim.api.nvim_create_user_command("AcpClientAskFiles", function(cmd)
    local paths = {}
    for path in string.gmatch(cmd.args, "[^,%s]+") do
      table.insert(paths, path)
    end
    M.ask_with_files("", paths)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AcpClientDiff", function(cmd)
    local path = vim.fn.expand(cmd.args)
    if path == "" then
      error("AcpClientDiff requires a file path")
    end

    M.open_file_diff(path, nil, { title = M.config.ui.diff_title })
  end, { nargs = 1, complete = "file" })
end

function M.ask(extra)
  local prompt = build_prompt(extra)
  if M.config.backend and M.config.backend.kind == "acp" and M.backend then
    M.backend:prompt(prompt, nil, function(err, result)
      if err then
        vim.notify(vim.inspect(err), vim.log.levels.ERROR, { title = "acpclient response" })
        return
      end

      if result and M.config.debug then
        vim.notify(vim.inspect(result), vim.log.levels.INFO, { title = "acpclient response" })
      end
    end)
    return prompt
  end

  if M.transport then
    M.transport:prompt(prompt, nil, function(err, result)
      if err then
        vim.notify(vim.inspect(err), vim.log.levels.ERROR, { title = "acpclient response" })
        return
      end

      if result and M.config.debug then
        vim.notify(vim.inspect(result), vim.log.levels.INFO, { title = "acpclient response" })
      end
    end)
    return prompt
  end

  vim.notify(prompt, vim.log.levels.INFO, { title = "acpclient prompt" })
  return prompt
end

function M.ask_with_files(extra, paths)
  local prompt = build_prompt(extra)
  local file_mentions = mentions.collect(paths)

  if #file_mentions > 0 then
    prompt = prompt .. "\n\nFiles:\n" .. table.concat(file_mentions, "\n")
  end

  vim.notify(prompt, vim.log.levels.INFO, { title = "acpclient prompt" })
  return prompt
end

function M.open_diff(before_lines, after_lines, opts)
  local diff = require("acpclient.diff")
  return diff.open(before_lines, after_lines, opts)
end

function M.open_file_diff(path, proposed_lines, opts)
  local diff = require("acpclient.diff")
  return diff.open_file(path, proposed_lines, opts)
end

function M.connect()
  if M.config.backend and M.config.backend.kind == "acp" then
    local client = acp_backend.new(M.config)
    client
      :on_notification(function(message)
        local method = message and message.method
        local params = message and message.params or {}

        if M.config.debug then
          vim.notify(vim.inspect(message), vim.log.levels.INFO, { title = "acpclient event" })
          return
        end

        if method == "acpclient/response" then
          local text = params.text
          if text and text ~= "" then
            vim.notify(text, vim.log.levels.INFO, { title = "acpclient response" })
          end
          return
        end

        if method == "acpclient/error" then
          vim.notify(vim.inspect(message), vim.log.levels.ERROR, { title = "acpclient error" })
        end
      end)
      :on_exit(function(code, signal)
        vim.notify(
          string.format("agent exited (code=%s, signal=%s)", tostring(code), tostring(signal)),
          vim.log.levels.WARN,
          { title = "acpclient exit" }
        )
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

      if M.config.debug then
        vim.notify(vim.inspect(message), vim.log.levels.INFO, { title = "acpclient event" })
        return
      end

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
          vim.notify(text, vim.log.levels.INFO, { title = "acpclient response" })
          return
        end

        local summary = extract_text(params)
        if summary and summary ~= "" then
          vim.notify(summary, vim.log.levels.INFO, { title = "acpclient response" })
        end
        return
      end

      if method == "turn/error" or method == "_transport/error" then
        vim.notify(vim.inspect(message), vim.log.levels.ERROR, { title = "acpclient error" })
      end
    end)
    :on_request(function(message, reply)
      if M.config.debug then
        vim.notify(vim.inspect(message), vim.log.levels.WARN, { title = "acpclient request" })
      end

      local method = message and message.method
      local params = message and message.params or {}

      if method == "item/commandExecution/requestApproval" or method == "item/fileChange/requestApproval" then
        reply({
          decision = "acceptForSession",
        })
        return
      end

      if method == "applyPatchApproval" then
        reply({
          decision = "approved_for_session",
        })
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
              text = "tool call not implemented by acpclient.nvim yet",
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
        vim.notify(
          "Unhandled server request method: " .. tostring(method),
          vim.log.levels.WARN,
          { title = "acpclient request" }
        )
      end
      reply({
        decision = "acceptForSession",
      })
    end)
    :on_exit(function(code, signal)
      vim.notify(
        string.format("agent exited (code=%s, signal=%s)", tostring(code), tostring(signal)),
        vim.log.levels.WARN,
        { title = "acpclient exit" }
      )
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
