local request = require("omniac.approval.request")
local state_factory = require("omniac.approval.state")
local diff = require("omniac.changes.review")
local filesystem = require("omniac.editor.filesystem")
local choice_dialog = require("omniac.ui.choice_dialog")

local M = {}
local EDIT_DIFF_WAIT_MS = 1000

local function diff_separate_tab(config)
  local ui = config and config.ui or {}
  return ui.diff_separate_tab == true
end

local function select_permission_option(params, reply, config, notice_index, notice_text, approval_state)
  local options = params and params.options or {}

  if type(options) ~= "table" or #options == 0 then
    request.update(notice_index, notice_text, request.result_text(nil, false), config, "rejected")
    reply(permission_response(params, false))
    return
  end

  vim.schedule(function()
    if approval_state and not approval_state:is_active() then
      return
    end
    choice_dialog.open(options, {
      prompt = request.summary(params),
      body = request.body(params),
    }, function(choice)
      if approval_state and not approval_state:is_active() then
        return
      end
      request.update(
        notice_index,
        notice_text,
        request.result_text(choice, choice ~= nil),
        config,
        request.choice_status(choice)
      )
      reply(request.selected_response(choice))
    end)
  end)
end

local function diff_payloads(value, config)
  local payloads = {}
  for _, item in ipairs(request.content_items(value)) do
    if
      type(item) == "table"
      and (item.type == "diff" or (type(item._meta) == "table" and (item._meta.kind == "update" or item._meta.kind == "add")))
      and type(item.path) == "string"
      and type(item.newText) == "string"
    then
      table.insert(payloads, {
        path = item.path,
        oldText = item.oldText,
        newText = item.newText,
      })
    end
  end

  if #payloads == 0 and type(value) == "table" and type(value.path) == "string" and type(value.newText) == "string" then
    table.insert(payloads, {
      path = value.path,
      oldText = value.oldText,
      newText = value.newText,
    })
  end

  if #payloads == 0 and type(value) == "table" and value.kind == "edit" then
    local preview =
      require("omniac.acp.edit_preview").from_input(value.rawInput, config and config.agent and config.agent.cwd)
    if preview then
      table.insert(payloads, preview)
    end
  end
  return payloads
end

local function append_diff_payloads(pending, payloads)
  for _, payload in ipairs(payloads) do
    local found = false
    for _, existing in ipairs(pending.payloads) do
      if
        existing.path == payload.path
        and existing.oldText == payload.oldText
        and existing.newText == payload.newText
      then
        found = true
        break
      end
    end
    if not found then
      table.insert(pending.payloads, payload)
    end
  end
end

local function show_pending_paths(pending)
  if not pending.notice_text then
    return
  end
  local missing = {}
  for _, payload in ipairs(pending.payloads) do
    if not pending.notice_text:find("`" .. payload.path .. "`", 1, true) then
      table.insert(missing, "- `" .. payload.path .. "`")
    end
  end
  if #missing == 0 then
    return
  end

  pending.notice_text = pending.notice_text .. "\n\nFiles:\n" .. table.concat(missing, "\n")
  local ok, ui = pcall(require, "omniac.ui")
  if ok and ui and ui.update_notice then
    ui.update_notice(pending.notice_index, pending.notice_text, pending.config)
  end
end

permission_response = function(permission_request, accepted)
  local option_id = request.first_option_id(permission_request)
  return {
    outcome = accepted and option_id and {
      outcome = "selected",
      optionId = option_id,
    } or {
      outcome = "cancelled",
    },
  }
end

local function finish_permission_diff(pending, accepted)
  pending.replied = true
  pending.approval_state:clear(pending.tool_call_id)
  if not accepted then
    request.update(pending.notice_index, pending.notice_text, "Decision: Rejected", pending.config, "rejected")
    pending.reply(permission_response(pending.params, false))
    return
  end

  if #pending.adjustments > 0 then
    local reject_id = request.reject_option_id(pending.params)
    local adjusted = #pending.adjustments == 1 and pending.adjustments[1] or pending.adjustments
    if reject_id and pending.on_adjusted and pending.on_adjusted(adjusted) then
      request.update(
        pending.notice_index,
        pending.notice_text,
        "Decision: Adjusted in diff; applying after this turn finishes.",
        pending.config,
        "adjusted"
      )
      pending.reply({ outcome = { outcome = "selected", optionId = reject_id } })
      return
    end
    request.update(
      pending.notice_index,
      pending.notice_text,
      "Decision: Adjusted diff could not be forwarded; original edit was not approved.",
      pending.config,
      "rejected"
    )
    pending.reply({ outcome = { outcome = "cancelled" } })
    return
  end

  request.update(pending.notice_index, pending.notice_text, "Decision: Accepted", pending.config, "approved")
  pending.reply(permission_response(pending.params, true))
end

local function open_permission_diff(pending)
  if pending.opened or pending.replied then
    return false
  end
  local payload = pending.payloads[1]
  if not payload then
    return false
  end
  local allow_id = request.allow_once_option_id(pending.params)
  local followup_payload = #pending.payloads == 1 and payload or pending.payloads
  if allow_id and pending.matches_followup and pending.matches_followup(pending.params, followup_payload) then
    pending.replied = true
    pending.approval_state:clear(pending.tool_call_id)
    request.update(
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
  pending.index = 1
  pending.adjustments = {}
  pending.selector_open = false
  choice_dialog.dismiss()
  if pending.diff_timer then
    pending.diff_timer:stop()
    pending.diff_timer:close()
    pending.diff_timer = nil
  end

  local function open_next()
    if pending.replied then
      return
    end
    local current = pending.payloads[pending.index]
    if not current then
      finish_permission_diff(pending, true)
      return
    end
    diff.open_review(current.path, request.as_lines(current.oldText) or {}, request.as_lines(current.newText) or {}, {
      title = #pending.payloads == 1 and ("Omniac permission: " .. current.path)
        or string.format("Omniac permission (%d/%d): %s", pending.index, #pending.payloads, current.path),
      origin_win = diff.select_review_window(),
      separate_tab = diff_separate_tab(pending.config),
      on_close = function()
        if not pending.replied then
          open_next()
        end
      end,
    }, function(accepted, accepted_lines, edited)
      if pending.replied then
        return
      end
      if not accepted then
        finish_permission_diff(pending, false)
        return
      end
      table.insert(pending.adjustments, {
        sessionId = pending.params.sessionId,
        path = current.path,
        proposedText = current.newText,
        adjustedText = edited and table.concat(accepted_lines or {}, "\n") or current.newText,
      })
      pending.edited = pending.edited or edited
      pending.index = pending.index + 1
      if not pending.payloads[pending.index] then
        if not pending.edited then
          pending.adjustments = {}
        end
        finish_permission_diff(pending, true)
      end
    end)
  end
  open_next()
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
  request.update(pending.notice_index, pending.notice_text, "Waiting for proposed diff...", pending.config)

  pending.diff_timer = vim.loop.new_timer()
  pending.diff_timer:start(
    EDIT_DIFF_WAIT_MS,
    0,
    vim.schedule_wrap(function()
      close_pending_timer(pending)
      if pending.replied or pending.opened or not pending.approval_state:contains(pending) then
        return
      end

      pending.selector_open = true
      request.update(
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
        pending.approval_state:clear(pending.tool_call_id)
        pending.reply(result)
      end, pending.config, pending.notice_index, pending.notice_text, pending.approval_state)
    end)
  )
end

local function review_acp_permission(approval_state, params, reply, config, on_adjusted, matches_followup)
  local tool_call = params and params.toolCall
  local notice_index, notice_text = request.show(params, config)
  if type(tool_call) ~= "table" then
    select_permission_option(params, reply, config, notice_index, notice_text, approval_state)
    return
  end

  if tool_call.kind ~= "edit" then
    select_permission_option(params, reply, config, notice_index, notice_text, approval_state)
    return
  end

  local tool_call_id = tool_call.toolCallId or tostring(vim.loop.now())
  local pending = {
    tool_call_id = tool_call_id,
    approval_state = approval_state,
    params = params,
    reply = reply,
    config = config,
    notice_index = notice_index,
    notice_text = notice_text,
    on_adjusted = on_adjusted,
    matches_followup = matches_followup,
    payloads = {},
    opened = false,
    replied = false,
  }
  if not approval_state:track(pending) then
    return false
  end

  append_diff_payloads(pending, diff_payloads(tool_call, config))
  append_diff_payloads(pending, approval_state:cached_diffs(pending.tool_call_id))
  show_pending_paths(pending)
  if #pending.payloads > 0 then
    open_permission_diff(pending)
  else
    schedule_edit_permission_fallback(pending)
  end
  return true
end

local function attach_acp_permission_diff(approval_state, params)
  local tool_call_id = params and params.toolCallId
  local payloads = diff_payloads(params)
  if #payloads == 0 then
    return false
  end

  if tool_call_id then
    approval_state:cache_diffs(tool_call_id, payloads)
  end

  local pending = tool_call_id and approval_state:pending(tool_call_id)
  if not pending then
    return false
  end

  append_diff_payloads(pending, payloads)
  show_pending_paths(pending)
  if pending.opened then
    return true
  end
  return open_permission_diff(pending)
end

function M.new()
  local approval_state = state_factory.new()
  local state = {}

  function state:review_acp_permission(params, reply, config, on_adjusted, matches_followup)
    if not approval_state:is_active() then
      return false
    end
    return review_acp_permission(approval_state, params, reply, config, on_adjusted, matches_followup)
  end

  function state:attach_acp_permission_diff(params)
    return attach_acp_permission_diff(approval_state, params)
  end

  function state:close()
    approval_state:close()
    choice_dialog.dismiss()
  end

  return state
end

local default_approval = M.new()

function M.review_acp_permission(params, reply, config, on_adjusted, matches_followup)
  return default_approval:review_acp_permission(params, reply, config, on_adjusted, matches_followup)
end

function M.attach_acp_permission_diff(params)
  return default_approval:attach_acp_permission_diff(params)
end

function M.review_file_update(params, config)
  local path = params and params.path
  local before = request.as_lines(params and params.oldText) or {}
  local after = request.as_lines(params and params.newText) or {}

  if type(path) ~= "string" or path == "" then
    vim.api.nvim_echo({ { "[omniac approval] file update ignored: missing path", "WarningMsg" } }, true, {})
    return false
  end

  vim.api.nvim_echo({ { "[omniac approval] opening file update review " .. path, "Comment" } }, true, {})
  filesystem.write_file_lines(path, before)

  diff.open_review(path, before, after, {
    title = "Omniac file update: " .. path,
    origin_win = diff.select_review_window(),
    separate_tab = diff_separate_tab(config),
  }, function(accepted, accepted_lines)
    filesystem.write_file_lines(path, accepted and (accepted_lines or after) or before)
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

  local after = request.as_lines(params and params.newText)
  if not after then
    vim.api.nvim_echo({
      { "[omniac approval] completed edit has no file contents " .. path, "WarningMsg" },
    }, true, {})
    return false
  end

  filesystem.write_file_lines(path, after)
  vim.api.nvim_echo({
    { "[omniac approval] applied completed edit " .. path, "Comment" },
  }, true, {})
  return true
end

return M
