local config = require("omniac.config")
local selection = require("omniac.selection")
local mentions = require("omniac.mentions")
local acp_backend = require("omniac.backend.acp")
local ui = require("omniac.ui")
local approval = require("omniac.approval")
local session_dialog = require("omniac.session_dialog")
local model_dialog = require("omniac.model_dialog")
local filesystem = require("omniac.filesystem")

local M = {
  config = config.defaults,
  backend = nil,
}

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

local function build_prompt_items(text, attachments)
  local items = {
    {
      type = "text",
      text = text,
    },
  }

  for _, attachment in ipairs(attachments or {}) do
    if type(attachment) == "table" and attachment.type == "image" then
      table.insert(items, {
        type = "image",
        mimeType = attachment.mimeType,
        data = attachment.data,
      })
    end
  end

  return items
end

local function register_command(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

local function slash_command(text)
  local command, arguments = tostring(text or ""):match("^%s*/([%w_-]+)%s*(.-)%s*$")
  if not command or arguments:find("\n", 1, true) then
    return nil, nil
  end
  return command:lower(), arguments
end

local function model_activity(model_state)
  if type(model_state) ~= "table" then
    return "The agent did not advertise selectable models."
  end

  local current = model_state.currentModelId or "unknown"
  local available = {}
  for _, model in ipairs(model_state.availableModels or {}) do
    table.insert(available, model.id)
  end
  if #available == 0 then
    return "Current model: " .. current
  end
  return string.format("Current model: %s · Available: %s", current, table.concat(available, ", "))
end

local function connect_session(action, session_id)
  if M.backend then
    M.disconnect()
  end
  ui.set_status("connecting", M.config)
  vim.defer_fn(function()
    M.connect({
      session = {
        action = action,
        id = session_id,
      },
    })
  end, 80)
end

function M.setup(opts)
  M.config = config.merge(opts)

  local function connect()
    M.connect()
  end

  local function disconnect()
    M.disconnect()
  end

  local function exit()
    M.exit()
  end

  local function ask(cmd)
    M.ask(cmd.args)
  end

  local function debug()
    if not M.config.debug then
      vim.notify("debug is disabled", vim.log.levels.WARN, { title = "omniac debug" })
      return
    end

    if M.backend and M.backend.get_debug_log then
      vim.notify(vim.inspect(M.backend:get_debug_log()), vim.log.levels.INFO, { title = "omniac debug" })
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

  local function choose_session()
    M.select_session()
  end

  local function resize(cmd)
    M.resize(cmd.args)
  end

  register_command("Omniac", open_chat, {})
  register_command("OmniacConnect", connect, {})
  register_command("OmniacDisconnect", disconnect, {})
  register_command("OmniacExit", exit, {})
  register_command("OmniacSession", choose_session, {})
  register_command("OmniacSessionNew", function()
    connect_session("new", nil)
  end, {})
  register_command("OmniacSessionLoad", function(cmd)
    connect_session("load", cmd.args)
  end, { nargs = 1 })
  register_command("OmniacSessionResume", function(cmd)
    connect_session("resume", cmd.args)
  end, { nargs = 1 })
  register_command("OmniacAsk", ask, { nargs = "?" })
  register_command("OmniacResize", resize, { nargs = 1 })
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
  ui.set_cancel_handler(function()
    if not M.backend or not M.backend.cancel then
      ui.handle_notification({
        method = "omniac/prompt_cancel_failed",
        params = {
          message = "Cancel is not available.",
        },
      }, M.config)
      return
    end

    local turn_id = M.backend.active_turn_id
    M.backend:cancel(function(err)
      if err then
        ui.handle_notification({
          method = "omniac/prompt_cancel_failed",
          params = {
            message = tostring(err.message or err.error or err),
            turnId = turn_id,
          },
        }, M.config)
        return
      end
      ui.handle_notification({
        method = "omniac/prompt_cancelled",
        params = {
          turnId = turn_id,
        },
      }, M.config)
    end)
  end)

  ui.set_mode_cycle_handler(function()
    if not M.backend or not M.backend.cycle_session_mode then
      ui.set_activity("Session modes are not available.", M.config)
      return
    end

    M.backend:cycle_session_mode(function(err)
      if err then
        ui.set_activity(tostring(err.message or err.error or err), M.config)
        return
      end
      ui.set_activity("Session mode changed.", M.config)
    end)
  end)

  ui.open(M.config, function(text, attachments)
    local command, arguments = slash_command(text)
    if command == "exit" and #(attachments or {}) == 0 then
      M.exit()
      return
    end
    if command == "resume" and #(attachments or {}) == 0 then
      ui.set_activity("Opening session list.", M.config)
      ui.set_status("connecting", M.config)
      local ok, err = pcall(M.select_session)
      if not ok then
        ui.add_message("Error", err, M.config)
        ui.set_status("error", M.config)
      end
      return
    end
    if command == "model" and #(attachments or {}) == 0 then
      if not M.backend or not M.backend.get_session_model then
        ui.set_activity("Model selection is not available until the ACP session is ready.", M.config)
        return
      end
      if arguments == "" then
        local model_state = M.backend:get_session_model()
        if
          not model_dialog.open(model_state, function(choice)
            if not choice then
              return
            end
            M.backend:set_session_model(choice.id, function(err, _, selected)
              if err then
                ui.set_activity(tostring(err.message or err.error or err), M.config)
                return
              end
              M.config.agent.model = selected
              ui.set_session_model({
                currentModelId = selected,
                currentModelName = selected,
              })
              ui.set_activity("Model changed to " .. selected .. ".", M.config)
            end)
          end)
        then
          ui.set_activity(model_activity(model_state), M.config)
        end
        return
      end
      M.backend:set_session_model(arguments, function(err, _, selected)
        if err then
          ui.set_activity(tostring(err.message or err.error or err), M.config)
          return
        end
        M.config.agent.model = selected
        ui.set_session_model({
          currentModelId = selected,
          currentModelName = selected,
        })
        ui.set_activity("Model changed to " .. selected .. ".", M.config)
      end)
      return
    end

    ui.submit(text, M.config, attachments)
    if not M.backend then
      ui.set_status("connecting", M.config)
      local ok, err = pcall(M.connect)
      if not ok then
        ui.add_message("Error", err, M.config)
        ui.set_status("error", M.config)
        return
      end
    end
    local ok, err = pcall(M.ask, text, attachments)
    if not ok then
      ui.add_message("Error", err, M.config)
      ui.set_status("error", M.config)
    end
  end)

  if not M.backend then
    ui.set_status("connecting", M.config)
    local ok, err = pcall(M.connect)
    if not ok then
      ui.add_message("Error", err, M.config)
      ui.set_status("error", M.config)
    end
  end
end

function M.select_session()
  local function continue_with(selection)
    if not selection then
      ui.set_status("ready", M.config)
      return
    end

    connect_session(selection.action or "new", selection.id)
  end

  if M.backend then
    local completed = false
    local timer = vim.loop.new_timer()
    timer:start(5000, 0, function()
      vim.schedule(function()
        if completed then
          return
        end
        completed = true
        timer:close()
        ui.set_status("ready", M.config)
        ui.set_activity("session/list did not respond within 5 seconds.", M.config)
        session_dialog.open({}, {
          list_supported = false,
          message = "session/list timed out; choose a fresh session or quit",
        }, continue_with)
      end)
    end)

    M.backend:list_sessions(function(err, sessions)
      if completed then
        return
      end
      completed = true
      timer:stop()
      timer:close()

      if err then
        ui.set_status("ready", M.config)
        ui.set_activity("session/list is not available.", M.config)
        session_dialog.open({}, {
          list_supported = false,
          message = tostring(err.message or err.error or "session/list is not available"),
        }, continue_with)
        return
      end

      session_dialog.open(sessions or {}, {
        list_supported = true,
      }, continue_with)
    end)
    return
  end

  ui.set_status("ready", M.config)
  session_dialog.open({}, {
    list_supported = false,
    message = "no active ACP session; choose new or enter a session id",
  }, continue_with)
end

function M.resize(width)
  return ui.resize(width)
end

function M.ask(extra, attachments)
  local prompt = build_prompt(extra)
  if M.backend then
    local params = nil
    if attachments and #attachments > 0 then
      params = {
        prompt = build_prompt_items(prompt, attachments),
      }
    end
    M.backend:prompt(prompt, params, function(err, result)
      if err then
        vim.notify(vim.inspect(err), vim.log.levels.ERROR, { title = "omniac response" })
        ui.add_message("Error", tostring(err.message or err.error or err), M.config)
        ui.set_status("error", M.config)
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

function M.connect(opts)
  opts = opts or {}
  local cfg = M.config
  if opts.session then
    cfg = vim.deepcopy(M.config)
    cfg.agent = cfg.agent or {}
    cfg.agent.session = vim.tbl_extend("force", cfg.agent.session or {}, opts.session)
  end
  cfg.session_selector = function(sessions, selector_opts, callback)
    session_dialog.open(sessions, selector_opts, callback)
  end

  local client = acp_backend.new(cfg)
  client
    :on_request(function(message, reply)
      local method = message and message.method
      local params = message and message.params or {}

      local function logged_reply(result, err)
        return reply(result, err)
      end

      if method == "session/request_permission" then
        approval.review_acp_permission(params, logged_reply, cfg)
        return
      end

      if method == "fs/read_text_file" or method == "fs/write_text_file" then
        local result, err = filesystem.handle_request(method, params)
        logged_reply(result, err)
        return
      end

      logged_reply({})
    end)
    :on_notification(function(message)
      local method = message and message.method
      local params = message and message.params or {}

      ui.handle_notification(message, cfg)

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
        vim.notify(
          tostring(params.message or params.error or "omniac error"),
          vim.log.levels.ERROR,
          { title = "omniac error" }
        )
      end
    end)
    :on_exit(function(code, signal)
      if client.closing or M.backend ~= client then
        return
      end

      ui.set_status("closed", cfg)
      vim.notify(
        string.format("agent exited (code=%s, signal=%s)", tostring(code), tostring(signal)),
        vim.log.levels.WARN,
        { title = "omniac exit" }
      )
      M.backend = nil
    end)

  M.backend = client:start()
  return M.backend
end

function M.disconnect()
  if M.backend then
    M.backend:close()
    M.backend = nil
  end
end

function M.exit()
  ui.close()
end

return M
