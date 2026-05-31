local diff = require("omniac.diff")

local M = {}

local function review_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if not name:match("Omniac Chat$") and not name:match("Omniac Input$") and not name:match("Omniac Status$") then
      return win
    end
  end

  return vim.api.nvim_get_current_win()
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

function M.review_request(method, params, reply, resolve)
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
    after = as_lines(vim.inspect(params)) or {}
    before = {}
    path = "Approval request details"
  end

  diff.open_review(path, before, after, {
    title = "Omniac approval: " .. path,
    origin_win = review_window(),
  }, function(accepted)
    reply(resolve and resolve(accepted) or approval_payload(method, accepted))
  end)
end

function M.review_acp_permission(params, reply)
  local option_id = first_option_id(params)
  M.review_request("session/request_permission", params, reply, function(accepted)
    return {
      outcome = accepted and option_id and {
        outcome = "selected",
        optionId = option_id,
      } or {
        outcome = "cancelled",
      },
    }
  end)
end

return M
