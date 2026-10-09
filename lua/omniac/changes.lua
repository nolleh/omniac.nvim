local diff = require("omniac.diff")

local M = {}

local state = {
  session_id = nil,
  active_turn_id = nil,
  last_turn_id = nil,
  sequence = 0,
  session = nil,
  turns = {},
}

local function collection()
  return {
    by_path = {},
    order = {},
  }
end

local function ensure_session(session_id)
  if state.session and (not session_id or session_id == state.session_id) then
    return
  end

  state.session_id = session_id
  state.active_turn_id = nil
  state.last_turn_id = nil
  state.sequence = 0
  state.session = collection()
  state.turns = {}
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs and vim.fs.normalize(path) or path
end

local function operation(before, after, explicit)
  if explicit == "add" or explicit == "delete" or explicit == "move" or explicit == "copy" then
    return explicit
  end
  if before == "" and after ~= "" then
    return "add"
  end
  if before ~= "" and after == "" then
    return "delete"
  end
  return "modify"
end

local function upsert(target, params)
  local path = normalize_path(params.path)
  if not path or type(params.oldText) ~= "string" or type(params.newText) ~= "string" then
    return false
  end

  local item = target.by_path[path]
  if not item then
    state.sequence = state.sequence + 1
    item = {
      path = path,
      oldText = params.oldText,
      newText = params.newText,
      operation = operation(params.oldText, params.newText, params.operation),
      sessionId = params.sessionId,
      turnId = params.turnId,
      toolCallId = params.toolCallId,
      title = params.title,
      source = params.source or "acp",
      sequence = state.sequence,
    }
    target.by_path[path] = item
    table.insert(target.order, path)
  else
    item.newText = params.newText
    item.operation = operation(item.oldText, item.newText, params.operation or item.operation)
    item.turnId = params.turnId or item.turnId
    item.toolCallId = params.toolCallId or item.toolCallId
    item.title = params.title or item.title
  end

  return true
end

local function items(target)
  local result = {}
  for _, path in ipairs((target and target.order) or {}) do
    local item = target.by_path[path]
    if item and item.oldText ~= item.newText then
      table.insert(result, vim.deepcopy(item))
    end
  end
  return result
end

local function scope_name(scope)
  return scope == "session" and "session" or "turn"
end

local function scope_collection(scope)
  scope = scope_name(scope)
  ensure_session(state.session_id)
  if scope == "session" then
    return state.session
  end
  local turn_id = state.last_turn_id or state.active_turn_id
  return turn_id and state.turns[turn_id] or nil
end

local function display_path(path)
  local relative = vim.fn.fnamemodify(path, ":.")
  return relative ~= "" and relative or path
end

local function operation_label(value)
  return ({
    add = "A",
    copy = "C",
    delete = "D",
    modify = "M",
    move = "R",
  })[value] or "M"
end

function M.reset(session_id)
  state.session = nil
  ensure_session(session_id)
end

function M.start_turn(params)
  params = params or {}
  ensure_session(params.sessionId or state.session_id)
  local turn_id = params.turnId or state.active_turn_id
  if not turn_id then
    return nil
  end
  state.active_turn_id = turn_id
  state.last_turn_id = turn_id
  state.turns[turn_id] = collection()
  return turn_id
end

function M.record(params)
  params = params or {}
  if not state.session then
    ensure_session(params.sessionId)
  elseif params.sessionId and state.session_id and params.sessionId ~= state.session_id then
    return false
  end
  local turn_id = params.turnId or state.active_turn_id or state.last_turn_id
  if not turn_id then
    return false
  end

  params = vim.tbl_extend("force", {}, params, {
    sessionId = params.sessionId or state.session_id,
    turnId = turn_id,
  })
  state.turns[turn_id] = state.turns[turn_id] or collection()
  local recorded = upsert(state.turns[turn_id], params)
  if recorded then
    upsert(state.session, params)
  end
  return recorded
end

function M.finish_turn(params)
  params = params or {}
  if not state.session then
    ensure_session(params.sessionId)
  elseif params.sessionId and state.session_id and params.sessionId ~= state.session_id then
    return 0
  end
  local turn_id = params.turnId or state.active_turn_id or state.last_turn_id
  if turn_id and state.active_turn_id and turn_id ~= state.active_turn_id then
    return 0
  end
  if turn_id then
    state.last_turn_id = turn_id
  end
  return #items(turn_id and state.turns[turn_id] or nil)
end

function M.get(scope)
  return items(scope_collection(scope))
end

function M.count(scope)
  return #M.get(scope)
end

function M.open(scope, config)
  scope = scope_name(scope)
  local available = M.get(scope)
  if #available == 0 then
    vim.notify("No Omniac changes recorded for this " .. scope, vim.log.levels.INFO, { title = "Omniac changes" })
    return false
  end

  vim.ui.select(available, {
    prompt = "Omniac changes · " .. scope,
    format_item = function(item)
      return string.format("%s  %s", operation_label(item.operation), display_path(item.path))
    end,
  }, function(item)
    if not item then
      return
    end
    diff.open_preview(
      item.path,
      vim.split(item.oldText, "\n", { plain = true }),
      vim.split(item.newText, "\n", {
        plain = true,
      }),
      {
        title = "Omniac changes: " .. display_path(item.path),
        separate_tab = config and config.ui and config.ui.diff_separate_tab,
      }
    )
  end)
  return true
end

return M
