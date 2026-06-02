local diff = require("omniac.diff")

local M = {}
local pending_acp_permissions = {}
local pending_acp_diffs = {}

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

local function permission_text(params)
  local tool_call = params and params.toolCall or {}
  local raw_input = type(tool_call.rawInput) == "table" and tool_call.rawInput or {}
  local lines = {
    "Permission requested",
    "",
    "kind: " .. tostring(tool_call.kind or "unknown"),
  }

  local command = raw_input.command or tool_call.title
  if type(command) == "string" and command ~= "" then
    table.insert(lines, "command: " .. command)
  end

  local cwd = raw_input.cwd
  if type(cwd) == "string" and cwd ~= "" then
    table.insert(lines, "cwd: " .. cwd)
  end

  for _, item in ipairs(content_items(tool_call)) do
    local text = first_string(item, { "text", "message" })
    if not text and type(item.content) == "table" then
      text = first_string(item.content, { "text", "message" })
    end
    if text and text ~= "" then
      table.insert(lines, "")
      table.insert(lines, text)
      break
    end
  end

  return table.concat(lines, "\n")
end

local function show_permission_text(params, config)
  local ok, ui = pcall(require, "omniac.ui")
  if ok and ui and ui.add_message then
    ui.add_message("Omniac", permission_text(params), config)
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

local function select_permission_option(params, reply, config)
  local options = params and params.options or {}
  show_permission_text(params, config)

  if type(options) ~= "table" or #options == 0 then
    reply(permission_response(params, false))
    return
  end

  vim.schedule(function()
    vim.ui.select(options, {
      prompt = "Omniac permission",
      format_item = option_label,
    }, function(choice)
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
    if type(tool_call) ~= "table" then
      select_permission_option(params, reply, config)
      return
    end

    if tool_call.kind ~= "edit" then
      select_permission_option(params, reply, config)
      return
    end

    local tool_call_id = tool_call.toolCallId or tostring(vim.loop.now())
    local pending = {
      tool_call_id = tool_call_id,
      params = params,
      reply = reply,
      config = config,
      opened = false,
      replied = false,
    }
    pending_acp_permissions[pending.tool_call_id] = pending

    local payload = diff_payload(tool_call) or pending_acp_diffs[pending.tool_call_id]
    if payload then
      open_permission_diff(pending, payload)
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
