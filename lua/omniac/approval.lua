local diff = require("omniac.diff")
local permission_dialog = require("omniac.permission_dialog")

local M = {}
local pending_acp_permissions = {}
local pending_acp_diffs = {}
local EDIT_DIFF_WAIT_MS = 1000

local function diff_separate_tab(config)
  local ui = config and config.ui or {}
  return ui.diff_separate_tab == true
end

local function as_lines(value)
  if type(value) == "table" then
    return value
  end

  if type(value) == "string" then
    return vim.split(value, "\n", { plain = true })
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

local function allow_once_option_id(request)
  for _, option in ipairs((request and request.options) or {}) do
    if type(option) == "table" and option.kind == "allow_once" then
      return option.id or option.optionId or option.value
    end
  end
  return nil
end

local function reject_option_id(request)
  for _, option in ipairs((request and request.options) or {}) do
    if type(option) == "table" and option.kind == "reject_once" then
      return option.id or option.optionId or option.value
    end
  end
  return nil
end

local content_items
local permission_response

content_items = function(value)
  if type(value) ~= "table" then
    return {}
  end

  if type(value.content) == "table" then
    return value.content
  end
  if type(value.contentItems) == "table" then
    return value.contentItems
  end
  if type(value.content_items) == "table" then
    return value.content_items
  end

  return {}
end

local function option_id(option)
  if type(option) ~= "table" then
    return nil
  end

  return option.id or option.optionId or option.value or option.label or option.name
end

local function option_label(option)
  if type(option) ~= "table" then
    return tostring(option)
  end

  return option.name or option.label or option.kind or option_id(option) or "Select"
end

local function permission_summary(params)
  local tool_call = params and params.toolCall or {}
  local kind = tool_call.kind or params.kind or "tool"
  return "Permission requested: " .. tostring(kind)
end

local function string_list(value)
  if type(value) ~= "table" then
    return nil
  end

  local parts = {}
  for _, item in ipairs(value) do
    if type(item) == "string" and item ~= "" then
      table.insert(parts, item)
    end
  end

  if #parts == 0 then
    return nil
  end

  return table.concat(parts, " ")
end

local function content_text(value, seen)
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

  for _, key in ipairs({ "text", "message", "description", "content" }) do
    local found = content_text(value[key], seen)
    if found and found ~= "" then
      return found
    end
  end

  for _, item in ipairs(value) do
    local found = content_text(item, seen)
    if found and found ~= "" then
      return found
    end
  end

  return nil
end

local function permission_body(params)
  local tool_call = params and params.toolCall or {}
  local raw_input = type(tool_call.rawInput) == "table" and tool_call.rawInput or {}
  local lines = {}
  local description = raw_input.description
    or tool_call.description
    or params.description
    or content_text(tool_call.content)

  local title = tool_call.title or raw_input.title
  if type(title) == "string" and title ~= "" then
    table.insert(lines, "Title: " .. title)
  end

  if type(description) == "string" and description ~= "" then
    table.insert(lines, "")
    table.insert(lines, description)
  end

  local command = raw_input.command or raw_input.cmd
  if type(command) == "string" and command ~= "" then
    table.insert(lines, "")
    table.insert(lines, "Command:")
    table.insert(lines, "```sh")
    table.insert(lines, command)
    table.insert(lines, "```")
  end

  local args = string_list(raw_input.args or raw_input.argv)
  if args then
    table.insert(lines, "")
    table.insert(lines, "Args:")
    table.insert(lines, "```sh")
    table.insert(lines, args)
    table.insert(lines, "```")
  end

  local cwd = raw_input.cwd
  if type(cwd) == "string" and cwd ~= "" then
    table.insert(lines, "")
    table.insert(lines, "cwd: `" .. cwd .. "`")
  end

  local path = raw_input.path or tool_call.path
  if type(path) == "string" and path ~= "" then
    table.insert(lines, "")
    table.insert(lines, "path: `" .. path .. "`")
  end

  return table.concat(lines, "\n")
end

local function permission_details(params)
  local body = permission_body(params)
  if body == "" then
    return permission_summary(params)
  end

  return table.concat({ permission_summary(params), "", body }, "\n")
end

local function permission_result_text(option, accepted)
  if type(option) == "table" then
    return "Decision: " .. option_label(option)
  end
  return accepted and "Decision: Accepted" or "Decision: Cancelled"
end

local function permission_choice_status(option)
  if not option then
    return "rejected"
  end
  local kind = tostring(option.kind or option_id(option) or ""):lower()
  if kind:find("reject", 1, true) or kind:find("deny", 1, true) then
    return "rejected"
  end
  return "approved"
end

local function show_permission_text(params, config)
  local ok, ui = pcall(require, "omniac.ui")
  if not ok or not ui then
    return nil, nil
  end
  local notice_index = nil
  local details = permission_details(params)
  if ui.add_notice then
    notice_index = ui.add_notice("Permission", details, config)
  elseif ui.add_message then
    ui.add_message("Permission", details, config)
  end
  if ui.set_activity then
    ui.set_activity(permission_summary(params), config)
  end
  return notice_index, details
end

local function update_permission_text(notice_index, base_text, decision, config, status)
  local ok, ui = pcall(require, "omniac.ui")
  if not ok or not ui or not ui.update_notice then
    return
  end

  ui.update_notice(notice_index, table.concat({ base_text or "", "", decision }, "\n"), config, {
    permission_status = status,
  })
  if decision:match("^Decision:") and ui.set_activity then
    ui.set_activity(nil, config)
  end
end

local function selected_permission_response(option)
  if not option then
    return {
      outcome = {
        outcome = "cancelled",
      },
    }
  end

  return {
    outcome = {
      outcome = "selected",
      optionId = option_id(option),
    },
  }
end

local function select_permission_option(params, reply, config, notice_index, notice_text)
  local options = params and params.options or {}

  if type(options) ~= "table" or #options == 0 then
    update_permission_text(notice_index, notice_text, permission_result_text(nil, false), config, "rejected")
    reply(permission_response(params, false))
    return
  end

  vim.schedule(function()
    permission_dialog.open(options, {
      prompt = permission_summary(params),
      body = permission_body(params),
    }, function(choice)
      update_permission_text(
        notice_index,
        notice_text,
        permission_result_text(choice, choice ~= nil),
        config,
        permission_choice_status(choice)
      )
      reply(selected_permission_response(choice))
    end)
  end)
end

local function diff_payload(value)
  for _, item in ipairs(content_items(value)) do
    if
      type(item) == "table"
      and (item.type == "diff" or (type(item._meta) == "table" and item._meta.kind == "update"))
      and type(item.path) == "string"
      and type(item.newText) == "string"
    then
      return {
        path = item.path,
        oldText = item.oldText,
        newText = item.newText,
      }
    end
  end

  if type(value) == "table" and type(value.path) == "string" and type(value.newText) == "string" then
    return {
      path = value.path,
      oldText = value.oldText,
      newText = value.newText,
    }
  end

  return nil
end

permission_response = function(request, accepted)
  local option_id = first_option_id(request)
  return {
    outcome = accepted and option_id and {
      outcome = "selected",
      optionId = option_id,
    } or {
      outcome = "cancelled",
    },
  }
end

local function open_permission_diff(pending, payload)
  if pending.opened or pending.replied then
    return false
  end
  local allow_id = allow_once_option_id(pending.params)
  if allow_id and pending.matches_followup and pending.matches_followup(pending.params, payload) then
    pending.replied = true
    pending_acp_permissions[pending.tool_call_id] = nil
    pending_acp_diffs[pending.tool_call_id] = nil
    if pending.diff_timer then
      pending.diff_timer:stop()
      pending.diff_timer:close()
      pending.diff_timer = nil
    end
    update_permission_text(
      pending.notice_index,
      pending.notice_text,
      "Decision: User-adjusted edit matched; accepted.",
      pending.config,
      "approved"
    )
    pending.reply({ outcome = { outcome = "selected", optionId = allow_id } })
    return true
  end
  pending.opened = true
  pending.selector_open = false
  permission_dialog.dismiss()
  if pending.diff_timer then
    pending.diff_timer:stop()
    pending.diff_timer:close()
    pending.diff_timer = nil
  end

  local before = as_lines(payload.oldText) or {}
  local after = as_lines(payload.newText) or {}
  diff.open_review(payload.path, before, after, {
    title = "Omniac permission: " .. payload.path,
    origin_win = diff.select_review_window(),
    separate_tab = diff_separate_tab(pending.config),
  }, function(accepted, accepted_lines, edited)
    if pending.replied then
      return
    end
    pending.replied = true
    pending_acp_permissions[pending.tool_call_id] = nil
    pending_acp_diffs[pending.tool_call_id] = nil
    if accepted and edited then
      local reject_id = reject_option_id(pending.params)
      if reject_id and pending.on_adjusted then
        local adjusted = {
          sessionId = pending.params.sessionId,
          path = payload.path,
          proposedText = payload.newText,
          adjustedText = table.concat(accepted_lines or {}, "\n"),
        }
        local queued = pending.on_adjusted(adjusted)
        if queued then
          update_permission_text(
            pending.notice_index,
            pending.notice_text,
            "Decision: Adjusted in diff; applying after this turn finishes.",
            pending.config,
            "adjusted"
          )
          pending.reply({ outcome = { outcome = "selected", optionId = reject_id } })
          return
        end
      end
      update_permission_text(
        pending.notice_index,
        pending.notice_text,
        "Decision: Adjusted diff could not be forwarded; original edit was not approved.",
        pending.config,
        "rejected"
      )
      pending.reply({ outcome = { outcome = "cancelled" } })
      return
    end
    update_permission_text(
      pending.notice_index,
      pending.notice_text,
      accepted and "Decision: Accepted" or "Decision: Rejected",
      pending.config,
      accepted and "approved" or "rejected"
    )
    pending.reply(permission_response(pending.params, accepted))
    vim.api.nvim_echo({
      {
        accepted and "[omniac approval] edit permission accepted" or "[omniac approval] edit permission denied",
        "Comment",
      },
    }, true, {})
  end)
  return true
end

local function close_pending_timer(pending)
  if pending.diff_timer then
    pending.diff_timer:stop()
    pending.diff_timer:close()
    pending.diff_timer = nil
  end
end

local function schedule_edit_permission_fallback(pending)
  update_permission_text(pending.notice_index, pending.notice_text, "Waiting for proposed diff...", pending.config)

  pending.diff_timer = vim.loop.new_timer()
  pending.diff_timer:start(
    EDIT_DIFF_WAIT_MS,
    0,
    vim.schedule_wrap(function()
      close_pending_timer(pending)
      if pending.replied or pending.opened or pending_acp_permissions[pending.tool_call_id] ~= pending then
        return
      end

      pending.selector_open = true
      update_permission_text(
        pending.notice_index,
        pending.notice_text,
        "No proposed diff was provided. Choose a permission option.",
        pending.config
      )
      select_permission_option(pending.params, function(result)
        if pending.replied then
          return
        end
        pending.replied = true
        pending.selector_open = false
        pending_acp_permissions[pending.tool_call_id] = nil
        pending_acp_diffs[pending.tool_call_id] = nil
        pending.reply(result)
      end, pending.config, pending.notice_index, pending.notice_text)
    end)
  )
end

local function write_lines(path, lines)
  if type(path) ~= "string" or path == "" then
    return
  end

  vim.fn.writefile(lines or {}, path)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == path then
      local was_modifiable = vim.bo[buf].modifiable
      if not was_modifiable then
        vim.bo[buf].modifiable = true
      end

      local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines or {})
      if ok then
        vim.bo[buf].modified = false
      end

      if not was_modifiable and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = false
      end
    end
  end
end

function M.review_acp_permission(params, reply, config, on_adjusted, matches_followup)
  local tool_call = params and params.toolCall
  local notice_index, notice_text = show_permission_text(params, config)
  if type(tool_call) ~= "table" then
    select_permission_option(params, reply, config, notice_index, notice_text)
    return
  end

  if tool_call.kind ~= "edit" then
    select_permission_option(params, reply, config, notice_index, notice_text)
    return
  end

  local tool_call_id = tool_call.toolCallId or tostring(vim.loop.now())
  local pending = {
    tool_call_id = tool_call_id,
    params = params,
    reply = reply,
    config = config,
    notice_index = notice_index,
    notice_text = notice_text,
    on_adjusted = on_adjusted,
    matches_followup = matches_followup,
    opened = false,
    replied = false,
  }
  pending_acp_permissions[pending.tool_call_id] = pending

  local payload = diff_payload(tool_call) or pending_acp_diffs[pending.tool_call_id]
  if payload then
    open_permission_diff(pending, payload)
  else
    schedule_edit_permission_fallback(pending)
  end
end

function M.attach_acp_permission_diff(params)
  local tool_call_id = params and params.toolCallId
  local payload = diff_payload(params)
  if not payload then
    return false
  end

  if tool_call_id then
    pending_acp_diffs[tool_call_id] = payload
  end

  local pending = tool_call_id and pending_acp_permissions[tool_call_id]
  if not pending then
    return false
  end

  return open_permission_diff(pending, payload)
end

function M.review_file_update(params, config)
  local path = params and params.path
  local before = as_lines(params and params.oldText) or {}
  local after = as_lines(params and params.newText) or {}

  if type(path) ~= "string" or path == "" then
    vim.api.nvim_echo({ { "[omniac approval] file update ignored: missing path", "WarningMsg" } }, true, {})
    return false
  end

  vim.api.nvim_echo({ { "[omniac approval] opening file update review " .. path, "Comment" } }, true, {})
  write_lines(path, before)

  diff.open_review(path, before, after, {
    title = "Omniac file update: " .. path,
    origin_win = diff.select_review_window(),
    separate_tab = diff_separate_tab(config),
  }, function(accepted, accepted_lines)
    write_lines(path, accepted and (accepted_lines or after) or before)
    vim.api.nvim_echo({
      {
        accepted and ("[omniac approval] accepted " .. path) or ("[omniac approval] denied " .. path),
        "Comment",
      },
    }, true, {})
  end)

  return true
end

function M.apply_file_update(params)
  local path = params and params.path
  local status = params and params.status

  if type(path) ~= "string" or path == "" then
    vim.api.nvim_echo({ { "[omniac approval] file update ignored: missing path", "WarningMsg" } }, true, {})
    return false
  end

  if status == "failed" then
    vim.api.nvim_echo({
      { "[omniac approval] edit failed " .. path, "WarningMsg" },
    }, true, {})
    return false
  end

  local after = as_lines(params and params.newText)
  if not after then
    vim.api.nvim_echo({
      { "[omniac approval] completed edit has no file contents " .. path, "WarningMsg" },
    }, true, {})
    return false
  end

  write_lines(path, after)
  vim.api.nvim_echo({
    { "[omniac approval] applied completed edit " .. path, "Comment" },
  }, true, {})
  return true
end

return M
