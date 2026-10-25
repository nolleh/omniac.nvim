local config = require("omniac.config")
local selection = require("omniac.editor.selection")
local mentions = require("omniac.editor.mentions")
local acp_backend = require("omniac.backend.acp")
local ui = require("omniac.ui")
local approval = require("omniac.approval")
local session_dialog = require("omniac.session.dialog")
local model_dialog = require("omniac.session.model_dialog")
local mode_dialog = require("omniac.session.mode_dialog")
local filesystem = require("omniac.editor.filesystem")
local tree = require("omniac.editor.tree")
local changes = require("omniac.changes")
local modified_approval = require("omniac.approval.followup")

local M = {
  config = config.defaults,
  backend = nil,
  failed_submission = nil,
  active_submission = nil,
  queued_submissions = {},
  permission_approval = nil,
}

local submission_failure

local function send_next_queued()
  if M.active_submission or M.failed_submission or #M.queued_submissions == 0 then
    return
  end
  local item = table.remove(M.queued_submissions, 1)
  M.active_submission = item
  ui.submit(item.text, M.config, item.attachments)
  local ok, err = pcall(M.ask, item.text, item.attachments, item)
  if not ok then
    submission_failure(item, err)
  end
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

local default_keymaps = {
  { name = "open", mode = "n", command = "Omniac", desc = "Toggle Omniac" },
  { name = "focus", mode = "n", command = "OmniacFocus", desc = "Focus Omniac" },
  { name = "session", mode = "n", command = "OmniacSession", desc = "Resume Omniac session" },
  { name = "buffer", mode = "n", command = "OmniacReferenceBuffer", desc = "Add current buffer to Omniac" },
  { name = "reference", mode = "x", command = "OmniacReference", desc = "Send selection to Omniac" },
  { name = "diff_accept", mode = "n", command = "OmniacDiffAccept", desc = "Accept Omniac diff" },
  { name = "diff_deny", mode = "n", command = "OmniacDiffDeny", desc = "Deny Omniac diff" },
}

local installed_keymaps = {}
local tree_keymap_group

local function clear_installed_keymaps()
  if tree_keymap_group then
    pcall(vim.api.nvim_del_augroup_by_id, tree_keymap_group)
    tree_keymap_group = nil
  end
  for _, mapping in ipairs(installed_keymaps) do
    local current = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if type(current) == "table" and current.desc == mapping.desc then
      pcall(vim.keymap.del, mapping.mode, mapping.lhs)
    end
  end
  installed_keymaps = {}
end

local function setup_keymaps()
  clear_installed_keymaps()

  local configured = M.config.keymaps
  if configured == false or type(configured) ~= "table" then
    return
  end

  for _, mapping in ipairs(default_keymaps) do
    local lhs = configured[mapping.name]
    if type(lhs) == "string" and lhs ~= "" and vim.fn.maparg(lhs, mapping.mode) == "" then
      local desc = "Omniac: " .. mapping.desc
      local rhs = mapping.mode == "x" and (":" .. mapping.command .. "<CR>") or ("<cmd>" .. mapping.command .. "<cr>")
      vim.keymap.set(mapping.mode, lhs, rhs, {
        desc = desc,
        silent = true,
      })
      table.insert(installed_keymaps, {
        lhs = lhs,
        mode = mapping.mode,
        desc = desc,
      })
    end
  end

  local tree_lhs = configured.tree_add
  if type(tree_lhs) == "string" and tree_lhs ~= "" and vim.fn.maparg(tree_lhs, "n") == "" then
    tree_keymap_group = vim.api.nvim_create_augroup("OmniacTreeKeymaps", { clear = true })
    local function map_tree_buffer(bufnr)
      vim.api.nvim_buf_call(bufnr, function()
        if vim.fn.maparg(tree_lhs, "n", false, true).buffer ~= 1 then
          vim.keymap.set("n", tree_lhs, "<cmd>OmniacTreeAdd<cr>", {
            buffer = bufnr,
            desc = "Omniac: Add selected tree path",
            silent = true,
          })
        end
      end)
    end
    vim.api.nvim_create_autocmd("FileType", {
      group = tree_keymap_group,
      pattern = { "NvimTree", "neo-tree", "oil", "minifiles" },
      callback = function(event)
        map_tree_buffer(event.buf)
      end,
    })
    local supported_tree_filetypes = { "NvimTree", "neo-tree", "oil", "minifiles" }
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains(supported_tree_filetypes, vim.bo[bufnr].filetype) then
        map_tree_buffer(bufnr)
      end
    end
  end
end

local function build_prompt(extra)
  local prompt = {}

  if extra and extra ~= "" then
    table.insert(prompt, extra)
  end

  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname ~= "" and bufname ~= "omniac" and not bufname:match("^omniac://") then
    table.insert(prompt, "Current file: " .. bufname)
  end

  return table.concat(prompt, "\n\n")
end

local function reference_label(reference)
  local path = reference.path
  if not path or path == "" then
    path = "[No Name]"
  else
    path = vim.fn.fnamemodify(path, ":.")
  end
  if reference.startLine and reference.endLine then
    return string.format("%s:%d-%d", path, reference.startLine, reference.endLine)
  end
  return path
end

local function append_attachment_items(items, attachment)
  if type(attachment) ~= "table" then
    return
  end

  if attachment.type == "image" then
    table.insert(items, {
      type = "image",
      mimeType = attachment.mimeType,
      data = attachment.data,
    })
  elseif attachment.type == "reference" then
    if attachment.pathOnly then
      local filename = vim.fn.fnamemodify(attachment.path, ":t")
      local instruction
      local description = "Source file reference."
      if attachment.startLine and attachment.endLine then
        instruction = string.format(
          "Please inspect lines %d-%d in %s.",
          attachment.startLine,
          attachment.endLine,
          reference_label(attachment)
        )
        description = string.format("Source file reference, lines %d-%d.", attachment.startLine, attachment.endLine)
      else
        instruction = string.format("Please inspect the referenced file: %s.", reference_label(attachment))
      end
      table.insert(items, {
        type = "text",
        text = instruction,
      })
      table.insert(items, {
        type = "resource_link",
        uri = attachment.uri,
        name = filename ~= "" and filename or "[No Name]",
        title = reference_label(attachment),
        mimeType = "text/plain",
        description = description,
      })
    else
      table.insert(items, {
        type = "text",
        text = string.format(
          "Please inspect this selected buffer content from %s (unsaved buffer contents are included below).",
          reference_label(attachment)
        ),
      })
      local supports_embedded_context = M.backend
        and M.backend.supports_prompt_capability
        and M.backend:supports_prompt_capability("embeddedContext")
      if supports_embedded_context then
        table.insert(items, {
          type = "resource",
          resource = {
            uri = attachment.uri,
            mimeType = "text/plain",
            text = attachment.text,
          },
        })
      else
        table.insert(items, {
          type = "text",
          text = string.format("Referenced code from %s:\n%s", reference_label(attachment), attachment.text or ""),
        })
      end
    end
  end
end

local function build_prompt_items(text, attachments)
  local items = {}
  local positioned = {}
  local trailing = {}
  for index, attachment in ipairs(attachments or {}) do
    if type(attachment) == "table" and type(attachment._position) == "number" then
      attachment._order = attachment._order or index
      table.insert(positioned, attachment)
    else
      table.insert(trailing, attachment)
    end
  end
  table.sort(positioned, function(left, right)
    if left._position == right._position then
      return (left._order or 0) < (right._order or 0)
    end
    return left._position < right._position
  end)

  local cursor = 1
  for _, attachment in ipairs(positioned) do
    local position = math.min(math.max(attachment._position, 0), #text)
    local segment = text:sub(cursor, position)
    if segment ~= "" then
      table.insert(items, { type = "text", text = segment })
    end
    append_attachment_items(items, attachment)
    cursor = position + 1
  end
  local remainder = text:sub(cursor)
  if remainder ~= "" then
    table.insert(items, { type = "text", text = remainder })
  end
  for _, attachment in ipairs(trailing) do
    append_attachment_items(items, attachment)
  end

  if #items == 0 then
    table.insert(items, {
      type = "text",
      text = text,
    })
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
  setup_keymaps()

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

  local function attach_reference(reference_item)
    M.open_chat()
    ui.attach_reference(reference_item, M.config)
  end

  local function reference(cmd)
    if not cmd.range or cmd.range == 0 then
      vim.notify("OmniacReference requires a visual selection", vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local reference_item, err = selection.reference_from_range(vim.api.nvim_get_current_buf(), cmd.line1, cmd.line2)
    if not reference_item then
      vim.notify(tostring(err or "Unable to capture selection"), vim.log.levels.WARN, { title = "omniac" })
      return
    end

    attach_reference(reference_item)
  end

  local function reference_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if bufname == "omniac" or bufname:match("^omniac://") then
      vim.notify("OmniacReferenceBuffer requires a source buffer", vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local reference_item, err = selection.reference_from_range(bufnr, 1, vim.api.nvim_buf_line_count(bufnr))
    if not reference_item then
      vim.notify(tostring(err or "Unable to capture buffer"), vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local has_disk_file = reference_item.path ~= "" and vim.fn.filereadable(reference_item.path) == 1
    local include_modified_buffer = M.config.references and M.config.references.include_modified_buffer == true

    if not has_disk_file and not include_modified_buffer then
      return
    end

    reference_item.pathOnly = has_disk_file and not (reference_item.modified and include_modified_buffer)
    attach_reference(reference_item)
  end

  local function tree_add()
    local paths, err = tree.get_selected_paths()
    if not paths or #paths == 0 then
      vim.notify(tostring(err or "No file selected in tree"), vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local references = {}
    for _, path in ipairs(paths) do
      local uri = vim.uri_from_fname(path)
      table.insert(references, {
        type = "reference",
        path = path,
        uri = uri,
        filetype = "",
        pathOnly = true,
      })
    end
    M.open_chat()
    for _, reference_item in ipairs(references) do
      ui.attach_reference(reference_item, M.config)
    end
  end

  local function diff(cmd)
    local path = vim.fn.expand(cmd.args)
    if path == "" then
      error("OmniacDiff requires a file path")
    end

    M.open_file_diff(path, nil, { title = M.config.ui.diff_title })
  end

  local function toggle_chat()
    M.toggle_chat()
  end

  local function open_chat()
    M.open_chat()
  end

  local function choose_session()
    if M.backend then
      M.select_session()
    elseif ui.is_open() then
      M.connect({
        session = { action = "select" },
      })
    else
      M.open_chat({
        session = { action = "select" },
      })
    end
  end

  local function resize(cmd)
    M.resize(cmd.args)
  end

  local function review_changes(cmd)
    M.review_changes(cmd.args)
  end

  register_command("Omniac", toggle_chat, {})
  register_command("OmniacFocus", open_chat, {})
  register_command("OmniacConnect", connect, {})
  register_command("OmniacDisconnect", disconnect, {})
  register_command("OmniacExit", exit, {})
  register_command("OmniacSession", choose_session, {})
  register_command("OmniacAsk", ask, { nargs = "?" })
  register_command("OmniacResize", resize, { nargs = 1 })
  register_command("OmniacDebug", debug, {})
  register_command("OmniacAskFiles", ask_files, { nargs = "?" })
  register_command("OmniacReference", reference, { range = true })
  register_command("OmniacReferenceBuffer", reference_buffer, {})
  register_command("OmniacTreeAdd", tree_add, {})
  register_command("OmniacChanges", review_changes, {
    nargs = "?",
    complete = function()
      return { "turn", "session" }
    end,
  })
  register_command("OmniacDiff", diff, { nargs = 1, complete = "file" })
  register_command("OmniacDiffAccept", function()
    require("omniac.changes.review").accept_current_review()
  end, {})
  register_command("OmniacDiffDeny", function()
    require("omniac.changes.review").deny_current_review()
  end, {})
end

function M.toggle_chat(connect_opts)
  if ui.is_open() then
    ui.close()
    return
  end
  M.open_chat(connect_opts)
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
      if M.active_submission or M.backend.active_turn_id ~= nil then
        ui.set_activity("Finish or cancel the current turn before starting a new session.", M.config)
        return
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
      if M.active_submission or (M.backend and M.backend.active_turn_id ~= nil) then
        ui.set_activity("Finish or cancel the current turn before switching sessions.", M.config)
        return
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
    if command == "mode" and #(attachments or {}) == 0 then
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

    if M.active_submission then
      ui.set_activity("Wait for the current prompt before sending another.", M.config)
      return false
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
    if not M.active_submission or M.failed_submission then
      return false
    end
    table.insert(M.queued_submissions, { text = text, attachments = vim.deepcopy(attachments or {}) })
    ui.set_activity("Queued prompt (" .. #M.queued_submissions .. ").", M.config)
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

function M.ask(extra, attachments, item)
  local prompt = item and item.prompt or build_prompt(extra)
  if item then
    item.prompt = prompt
  end
  if M.backend then
    local client = M.backend
    local params = item and item.params or nil
    if not params and attachments and #attachments > 0 then
      params = {
        prompt = build_prompt_items(prompt, attachments),
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
  local prompt = build_prompt(extra)
  local file_mentions = mentions.collect(paths)

  if #file_mentions > 0 then
    prompt = prompt .. "\n\nFiles:\n" .. table.concat(file_mentions, "\n")
  end

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
  opts = opts or {}
  ui.set_session_usage(nil)
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
  local function new_modified_approval()
    return modified_approval.new(client, cfg, function()
      return M.backend == client
    end)
  end
  local followup = new_modified_approval()
  local permission_approval = approval.new()
  M.modified_approval = followup
  M.permission_approval = permission_approval
  client
    :on_request(function(message, reply)
      local method = message and message.method
      local params = message and message.params or {}

      local function logged_reply(result, err)
        return reply(result, err)
      end

      if method == "session/request_permission" then
        permission_approval:review_acp_permission(params, logged_reply, cfg, function(item)
          return followup:queue(item)
        end, function(request, payload)
          return followup:matches_followup(request, payload)
        end)
        return
      end

      if method == "fs/read_text_file" or method == "fs/write_text_file" then
        local before
        if method == "fs/write_text_file" then
          local current = filesystem.read_text_file({ path = params.path })
          before = current and current.content or ""
        end
        local result, err = filesystem.handle_request(method, params)
        if method == "fs/write_text_file" and not err then
          changes.record({
            sessionId = params.sessionId or client.session_id,
            turnId = client.active_turn_id,
            path = params.path,
            oldText = before,
            newText = params.content,
            source = "filesystem",
          })
        end
        logged_reply(result, err)
        return
      end

      logged_reply({})
    end)
    :on_notification(function(message)
      if M.backend ~= client then
        return
      end
      local method = message and message.method
      local params = message and message.params or {}

      if method == "omniac/session_started" then
        changes.reset(params.sessionId)
        followup:close()
        followup = new_modified_approval()
        M.modified_approval = followup
        permission_approval:close()
        permission_approval = approval.new()
        M.permission_approval = permission_approval
      elseif method == "omniac/prompt_started" then
        changes.start_turn(params)
      end

      ui.handle_notification(message, cfg)

      if method == "omniac/permission_diff" then
        permission_approval:attach_acp_permission_diff(params)
        return
      end

      if method == "omniac/file_update" then
        changes.record(params)
        return
      end

      if method == "omniac/prompt_failed" then
        followup:finish_turn(params)
        return
      end

      if method == "omniac/response" or method == "omniac/response_completed" then
        local count = changes.finish_turn(params)
        local review_mode = cfg.ui and cfg.ui.change_review or "summary"
        if count > 0 and review_mode == "open" then
          vim.schedule(function()
            changes.open("turn", cfg)
          end)
        elseif count > 0 and review_mode == "summary" then
          ui.set_activity(
            string.format("Changed %d file%s this turn\n[t] turn · [s] session", count, count == 1 and "" or "s"),
            cfg,
            { change_summary = true }
          )
        end
        followup:finish_turn(params)
        return
      end

      if method == "omniac/edit_failed" then
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

      if M.active_submission and M.active_submission.client == client then
        submission_failure(M.active_submission, "ACP agent exited before the prompt completed")
      end
      ui.set_status("closed", cfg)
      vim.notify(
        string.format("agent exited (code=%s, signal=%s)", tostring(code), tostring(signal)),
        vim.log.levels.WARN,
        { title = "omniac exit" }
      )
      M.backend = nil
      followup:close()
      permission_approval:close()
      M.modified_approval = nil
      M.permission_approval = nil
    end)

  M.backend = client:start()
  return M.backend
end

function M.disconnect()
  if M.permission_approval then
    M.permission_approval:close()
    M.permission_approval = nil
  end
  if M.modified_approval then
    M.modified_approval:close()
    M.modified_approval = nil
  end
  if M.backend then
    M.backend:close()
    M.backend = nil
  end
end

function M.exit()
  ui.close()
end

return M
