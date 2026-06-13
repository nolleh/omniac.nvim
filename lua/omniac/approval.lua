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

local function is_omniac_buffer(name)
  return name:match("omniac$") or name:match("omniac://")
end

local function is_review_candidate(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  local buftype = vim.bo[buf].buftype
  local filetype = vim.bo[buf].filetype

  if is_omniac_buffer(name) then
    return false
  end

  if buftype ~= "" then
    return false
  end

  if filetype == "NvimTree" or filetype == "neo-tree" or filetype == "qf" then
    return false
  end

  return true
end

local function review_window()
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current) and is_review_candidate(current) then
    return current
  end

  local best_win = nil
  local best_width = -1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_review_candidate(win) then
      local width = vim.api.nvim_win_get_width(win)
      if width > best_width then
        best_win = win
        best_width = width
      end
    end
  end

  if best_win and vim.api.nvim_win_is_valid(best_win) then
    return best_win
  end

  return nil
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

local function first_string(value, keys)
  if type(value) ~= "table" then
    return nil
  end

  for _, key in ipairs(keys) do
    if type(value[key]) == "string" and value[key] ~= "" then
      return value[key]
    end
  end

  return nil
end

local function first_value(value, keys)
  if type(value) ~= "table" then
    return nil
  end

  for _, key in ipairs(keys) do
    if value[key] ~= nil then
      return value[key]
    end
  end

  return nil
end

local function find_change(params)
  if type(params) ~= "table" then
    return {}
  end

  for _, key in ipairs({ "change", "fileChange", "file_change" }) do
    if type(params[key]) == "table" then
      return params[key]
    end
  end

  for _, key in ipairs({ "changes", "fileChanges", "file_changes", "edits" }) do
    if type(params[key]) == "table" and type(params[key][1]) == "table" then
      return params[key][1]
    end
  end

  return params
end

local function patch_path(patch)
  if type(patch) ~= "string" then
    return nil
  end

  for line in patch:gmatch("([^\n]*)\n?") do
    local path = line:match("^%+%+%+%s+b/(.+)$") or line:match("^%+%+%+%s+(.+)$")
    if path and path ~= "/dev/null" then
      return path
    end
  end

  return nil
end

local function apply_patch(original, patch)
  if type(patch) ~= "string" then
    return nil
  end

  local result = {}
  local source_index = 1
  local in_hunk = false

  for line in (patch .. "\n"):gmatch("(.-)\n") do
    local old_start = line:match("^@@ %-(%d+)")
    if old_start then
      old_start = tonumber(old_start)
      while source_index < old_start do
        table.insert(result, original[source_index] or "")
        source_index = source_index + 1
      end
      in_hunk = true
    elseif in_hunk then
      local marker = line:sub(1, 1)
      local body = line:sub(2)
      if marker == " " then
        table.insert(result, original[source_index] or body)
        source_index = source_index + 1
      elseif marker == "-" then
        source_index = source_index + 1
      elseif marker == "+" then
        table.insert(result, body)
      elseif marker == "\\" then
        -- no newline marker
      else
        in_hunk = false
      end
    end
  end

  while source_index <= #original do
    table.insert(result, original[source_index])
    source_index = source_index + 1
  end

  return result
end

local function approval_payload(method, accepted)
  if method == "applyPatchApproval" then
    return {
      decision = accepted and "approved_for_session" or "denied",
    }
  end

  return {
    decision = accepted and "acceptForSession" or "reject",
  }
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
  local kind = tool_call.kind or "tool"
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

local function permission_details(params)
  local tool_call = params and params.toolCall or {}
  local raw_input = type(tool_call.rawInput) == "table" and tool_call.rawInput or {}
  local lines = { permission_summary(params) }
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

local function permission_result_text(option, accepted)
  if type(option) == "table" then
    return "Decision: " .. option_label(option)
  end
  return accepted and "Decision: Accepted" or "Decision: Cancelled"
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

local function update_permission_text(notice_index, base_text, decision, config)
  local ok, ui = pcall(require, "omniac.ui")
  if not ok or not ui or not ui.update_notice then
    return
  end

  ui.update_notice(notice_index, table.concat({ base_text or "", "", decision }, "\n"), config)
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
    update_permission_text(notice_index, notice_text, permission_result_text(nil, false), config)
    reply(permission_response(params, false))
    return
  end

  vim.schedule(function()
    permission_dialog.open(options, {
      prompt = permission_summary(params),
    }, function(choice)
      update_permission_text(notice_index, notice_text, permission_result_text(choice, choice ~= nil), config)
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
    origin_win = review_window(),
    separate_tab = diff_separate_tab(pending.config),
  }, function(accepted)
    if pending.replied then
      return
    end
    pending.replied = true
    pending_acp_permissions[pending.tool_call_id] = nil
    pending_acp_diffs[pending.tool_call_id] = nil
    update_permission_text(
      pending.notice_index,
      pending.notice_text,
      accepted and "Decision: Accepted" or "Decision: Rejected",
      pending.config
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

function M.review_request(method, params, reply, resolve, config)
  if type(resolve) == "table" and config == nil then
    config = resolve
    resolve = nil
  end

  local tool_call = params and params.toolCall
  if method == "session/request_permission" then
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
    return
  end

  local change = find_change(params)
  local patch = first_string(change, { "patch", "diff", "unifiedDiff", "unified_diff" })
    or first_string(params, { "patch", "diff", "unifiedDiff", "unified_diff" })
  local path = first_string(change, {
    "path",
    "filePath",
    "file_path",
    "targetFile",
    "target_file",
    "old_file_path",
    "new_file_path",
  }) or patch_path(patch) or "Omniac change"

  local before = as_lines(first_value(change, {
    "oldContent",
    "old_content",
    "before",
    "beforeContent",
    "old_file_contents",
  }))
  local after = as_lines(first_value(change, {
    "newContent",
    "new_content",
    "after",
    "afterContent",
    "content",
    "contents",
    "new_file_contents",
  }))

  if not before and path and vim.fn.filereadable(path) == 1 then
    before = vim.fn.readfile(path)
  end
  before = before or {}

  if not after and patch then
    after = apply_patch(before, patch)
  end

  if not after then
    vim.api.nvim_echo({
      { "[omniac approval] ignored request without a file diff", "WarningMsg" },
    }, true, {})
    reply(resolve and resolve(false) or approval_payload(method, false))
    return
  end

  diff.open_review(path, before, after, {
    title = "Omniac approval: " .. path,
    origin_win = review_window(),
    separate_tab = diff_separate_tab(config),
  }, function(accepted)
    reply(resolve and resolve(accepted) or approval_payload(method, accepted))
  end)
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
    origin_win = review_window(),
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

function M.review_acp_permission(params, reply, config)
  M.review_request("session/request_permission", params, reply, nil, config)
end

return M
