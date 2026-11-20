local config = require("omniac.config")
local command_keymaps = require("omniac.commands.keymaps")
local commands = require("omniac.commands")
local connection = require("omniac.connection")
local ui = require("omniac.ui")
local session_dialog = require("omniac.session.dialog")
local model_dialog = require("omniac.session.model_dialog")
local mode_dialog = require("omniac.session.mode_dialog")
local changes = require("omniac.changes")
local prompt_builder = require("omniac.prompt.build")
local steering = require("omniac.acp.steering")

local M = {
  config = config.defaults,
  backend = nil,
  failed_submission = nil,
  active_submission = nil,
  queued_submissions = {},
  permission_approval = nil,
}

local submission_failure

local function turn_is_active()
  return M.active_submission ~= nil or (M.backend and (M.backend.active_turn_id ~= nil or steering.busy(M.backend)))
end

local function send_next_queued()
  vim.schedule(function()
    if turn_is_active() or M.failed_submission or #M.queued_submissions == 0 then
      return
    end
    local item = table.remove(M.queued_submissions, 1)
    M.active_submission = item
    item.message = item.message or ui.queue_prompt(item.text, M.config, item.attachments)
    item.queued = false
    ui.submit(item.text, M.config, item.attachments, item.message)
    local ok, err = pcall(M.ask, item.text, item.attachments, item)
    if not ok then
      submission_failure(item, err)
    end
  end)
end

submission_failure = function(item, err)
  if M.active_submission ~= item then
    return
  end
  M.active_submission = nil
  M.failed_submission = item
  ui.set_status("error", M.config)
  ui.set_activity("Prompt failed or its outcome is unknown. Check the session before resending.", M.config)
  ui.add_message("Error", tostring(type(err) == "table" and (err.message or err.error) or err), M.config)
  vim.schedule(function()
    if M.failed_submission ~= item then
      return
    end
    ui.show_failure_action(function(choice)
      if M.failed_submission ~= item then
        return
      end
      if choice == "resend" then
        M.retry_failed_submission()
      elseif choice == "restore" then
        if ui.restore_input(item.text, item.attachments) then
          M.failed_submission = nil
          send_next_queued()
        else
          ui.set_activity("Clear the current input before restoring the failed prompt.", M.config)
          ui.show_failure_action(function(action)
            if M.failed_submission == item and action == "dismiss" then
              M.failed_submission = nil
              send_next_queued()
            end
          end)
        end
      else
        M.failed_submission = nil
        send_next_queued()
      end
    end)
  end)
end

local function slash_command(text)
  local command, arguments = tostring(text or ""):match("^%s*/([%w_-]+)%s*(.-)%s*$")
  if not command or arguments:find("\n", 1, true) then
    return nil, nil
  end
  return command:lower(), arguments
end

local function guard_active_command(text)
  local command = tostring(text or ""):match("^%s*/([^%s]+)")
  if not command or not command:match("^[%w_-]+$") or not turn_is_active() then
    return false
  end
  -- ACP commands share session/prompt's turn lifecycle. They must neither
  -- replace the current request nor be injected as ordinary steering text.
  ui.set_activity(
    string.format(
      "/%s cannot run during a turn through ACP. Finish or cancel the current turn, then send it again.",
      command
    ),
    M.config
  )
  return true
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
  command_keymaps.setup(M.config)
  commands.setup(M)
end

function M.toggle_chat(connect_opts)
  if ui.is_open() then
    ui.close()
    return
  end
  M.open_chat(connect_opts)
end

function M.select_model(arguments)
  arguments = arguments or ""
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

function M.select_mode(arguments)
  arguments = arguments or ""
  if not M.backend or not M.backend.get_session_mode then
    ui.set_activity("Mode selection is not available until the ACP session is ready.", M.config)
    return
  end
  local mode_state = M.backend:get_session_mode()
  local modes = mode_state and mode_state.availableModes or {}
  if #modes == 0 then
    ui.set_activity("The agent did not advertise selectable modes.", M.config)
    return
  end
  local function select_mode(mode_id)
    local selected
    for _, mode in ipairs(modes) do
      if mode.id == mode_id then
        selected = mode
        break
      end
    end
    if not selected then
      ui.set_activity("Unknown mode: " .. mode_id, M.config)
      return
    end
    M.backend:set_session_mode(mode_id, function(err)
      if err then
        ui.set_activity(tostring(err.message or err.error or err), M.config)
        return
      end
      ui.set_activity("Mode changed to " .. (selected.name or selected.id) .. ".", M.config)
    end)
  end
  if arguments == "" then
    mode_dialog.open(mode_state, function(choice)
      if choice then
        select_mode(choice.id)
      end
    end)
  else
    select_mode(arguments)
  end
  return
end

function M.open_chat(connect_opts)
  ui.set_change_review_handler(function(scope)
    M.review_changes(scope)
  end)
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
      if M.modified_approval then
        M.modified_approval:cancel_turn(turn_id)
      end
    end)
  end)

  ui.set_plan_toggle_handler(function()
    if not M.backend or not M.backend.toggle_collaboration_mode then
      ui.set_activity("Plan mode is not available until the ACP session is ready.", M.config)
      return
    end

    M.backend:toggle_collaboration_mode(function(err, mode)
      if err then
        ui.set_activity(tostring(err.message or err.error or err), M.config)
        return
      end
      ui.flash_activity(mode == "plan" and "Plan mode enabled." or "Plan mode disabled.", M.config)
    end)
  end)

  ui.open(M.config, function(text, attachments)
    local command, arguments = slash_command(text)
    if command == "exit" and #(attachments or {}) == 0 then
      M.exit()
      return
    end
    if command == "clear" and #(attachments or {}) == 0 then
      if not M.backend or not M.backend.new_session then
        ui.set_activity("Cannot start a new ACP session until the current connection is ready.", M.config)
        return
      end
      if turn_is_active() then
        ui.set_activity("Finish or cancel the current turn before starting a new session.", M.config)
        return false
      end
      ui.set_status("connecting", M.config)
      M.backend:new_session(function(err)
        if err then
          ui.set_status("ready", M.config)
          ui.set_activity(tostring(err.message or err.error or err), M.config)
        end
      end)
      return
    end
    if command == "resume" and #(attachments or {}) == 0 then
      if turn_is_active() then
        ui.set_activity("Finish or cancel the current turn before switching sessions.", M.config)
        return false
      end
      ui.set_activity("Opening session list.", M.config)
      ui.set_status("connecting", M.config)
      local ok, err = pcall(M.select_session)
      if not ok then
        ui.add_message("Error", err, M.config)
        ui.set_status("error", M.config)
      end
      return
    end
    if command == "changes" and #(attachments or {}) == 0 then
      M.review_changes(arguments)
      return
    end
    if command == "model" and #(attachments or {}) == 0 then
      M.select_model(arguments)
      return
    end
    if command == "mode" and #(attachments or {}) == 0 then
      M.select_mode(arguments)
      return
    end

    if turn_is_active() then
      return M.steer(text, attachments)
    end
    if M.failed_submission then
      vim.ui.select({ "Keep failed prompt", "Discard failed prompt" }, {
        prompt = "One failed prompt is saved. Discard it before sending a new one?",
      }, function(choice)
        if choice == "Discard failed prompt" then
          M.failed_submission = nil
          ui.set_activity("Failed prompt discarded. Send the current input again.", M.config)
        end
      end)
      return false
    end

    local item = { text = text, attachments = vim.deepcopy(attachments or {}) }
    M.active_submission = item
    ui.submit(text, M.config, attachments)
    if not M.backend then
      ui.set_status("connecting", M.config)
      local ok, err = pcall(M.connect)
      if not ok then
        submission_failure(item, err)
        return true
      end
    end
    local ok, err = pcall(M.ask, text, attachments, item)
    if not ok then
      submission_failure(item, err)
    end
    return true
  end, function(text, attachments)
    if not turn_is_active() or M.failed_submission then
      return false
    end
    local item = { text = text, attachments = vim.deepcopy(attachments or {}), queued = true }
    table.insert(M.queued_submissions, item)
    vim.schedule(function()
      if item.queued then
        item.message = item.message or ui.queue_prompt(item.text, M.config, item.attachments)
        ui.set_activity("Queued prompt (" .. #M.queued_submissions .. ").", M.config)
      end
    end)
    return true
  end)

  if not M.backend then
    ui.set_status("connecting", M.config)
    local ok, err = pcall(M.connect, connect_opts)
    if not ok then
      ui.add_message("Error", err, M.config)
      ui.set_status("error", M.config)
    end
  end
end

function M.review_changes(scope)
  scope = scope == "session" and "session" or "turn"
  return changes.open(scope, M.config)
end

function M.select_session()
  local function continue_with(selection)
    if not selection then
      ui.set_status("ready", M.config)
      return
    end

    connect_session(selection.action or "new", selection.id)
  end

  if M.backend and M.backend.running then
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

  connect_session("select")
end

function M.resize(width)
  return ui.resize(width)
end

function M.ask(extra, attachments, item)
  if (not item or M.active_submission ~= item) and guard_active_command(extra) then
    return false
  end
  local prompt = item and item.prompt or prompt_builder.text(extra)
  if item then
    item.prompt = prompt
  end
  if M.backend then
    local client = M.backend
    local params = item and item.params or nil
    if not params and attachments and #attachments > 0 then
      params = {
        prompt = prompt_builder.items(prompt, attachments, M.backend:supports_prompt_capability("embeddedContext")),
      }
    end
    if item then
      item.params = vim.deepcopy(params)
      item.client = client
    end
    client:prompt(prompt, params, function(err, result)
      if item and (M.active_submission ~= item or item.client ~= client) then
        return
      end
      if err then
        if item then
          submission_failure(item, err)
          return
        end
        vim.notify(vim.inspect(err), vim.log.levels.ERROR, { title = "omniac response" })
        ui.add_message("Error", tostring(err.message or err.error or err), M.config)
        ui.set_status("error", M.config)
        return
      end

      if item then
        M.active_submission = nil
        send_next_queued()
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

function M.steer(text, attachments)
  if guard_active_command(text) then
    return false
  end
  local client = M.backend
  if not client or not client.supports_steering or not client:supports_steering() then
    ui.set_activity("This agent cannot receive messages during a turn. Use Tab to queue the input.", M.config)
    return false
  end
  if not client.running or not client.session_id then
    ui.set_activity("The ACP session is still starting. Keep the input and send it when ready.", M.config)
    return false
  end
  local session_id = client.session_id
  local prompt = prompt_builder.text(text)
  local saved_attachments = vim.deepcopy(attachments or {})
  local params
  if #saved_attachments > 0 then
    params =
      { prompt = prompt_builder.items(prompt, saved_attachments, client:supports_prompt_capability("embeddedContext")) }
  end
  ui.add_user_message(text, M.config, saved_attachments)
  local function completed(err)
    vim.schedule(function()
      if M.backend ~= client or client.session_id ~= session_id then
        return
      end
      if err then
        local reason = type(err) == "table" and (err.message or err.error) or err
        ui.add_notice("Error", "Could not deliver the additional message: " .. tostring(reason), M.config)
        if not ui.restore_input(text, saved_attachments) then
          ui.set_activity("Additional message failed. It remains in chat; resend it when ready.", M.config)
        end
      end
      send_next_queued()
    end)
  end
  local ok, err = pcall(client.steer, client, prompt, params, completed)
  if not ok then
    completed(err)
  end
  return true
end

function M.retry_failed_submission()
  local item = M.failed_submission
  if not item or M.active_submission then
    return false
  end
  M.failed_submission = nil
  M.active_submission = item
  if M.backend and not M.backend.running then
    M.backend = nil
  end
  if not M.backend then
    local ok, err = pcall(M.connect)
    if not ok then
      submission_failure(item, err)
      return false
    end
  end
  local ok, err = pcall(M.ask, item.text, item.attachments, item)
  if not ok then
    submission_failure(item, err)
    return false
  end
  return true
end

function M.ask_with_files(extra, paths)
  local prompt = prompt_builder.with_files(extra, paths)

  vim.notify(prompt, vim.log.levels.INFO, { title = "omniac prompt" })
  return prompt
end

function M.open_diff(before_lines, after_lines, opts)
  local diff = require("omniac.changes.review")
  return diff.open(before_lines, after_lines, opts)
end

function M.open_file_diff(path, proposed_lines, opts)
  local diff = require("omniac.changes.review")
  return diff.open_file(path, proposed_lines, opts)
end

function M.connect(opts)
  return connection.connect(M, opts, submission_failure)
end

function M.disconnect()
  connection.disconnect(M)
end

function M.exit()
  ui.close()
end

return M
