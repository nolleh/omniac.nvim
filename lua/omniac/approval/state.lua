local M = {}

local function close_timer(pending)
  if pending.diff_timer then
    pending.diff_timer:stop()
    pending.diff_timer:close()
    pending.diff_timer = nil
  end
end

function M.new()
  local state = {
    permissions = {},
    diffs = {},
    closed = false,
  }

  function state:track(pending)
    if self.closed then
      return false
    end
    self.permissions[pending.tool_call_id] = pending
    return true
  end

  function state:is_active()
    return not self.closed
  end

  function state:contains(pending)
    return not self.closed and self.permissions[pending.tool_call_id] == pending
  end

  function state:pending(tool_call_id)
    if self.closed then
      return nil
    end
    return self.permissions[tool_call_id]
  end

  function state:cache_diffs(tool_call_id, payloads)
    if self.closed or not tool_call_id then
      return
    end
    self.diffs[tool_call_id] = self.diffs[tool_call_id] or {}
    for _, payload in ipairs(payloads or {}) do
      table.insert(self.diffs[tool_call_id], payload)
    end
  end

  function state:cached_diffs(tool_call_id)
    if self.closed then
      return {}
    end
    return self.diffs[tool_call_id] or {}
  end

  function state:clear(tool_call_id)
    local pending = self.permissions[tool_call_id]
    if pending then
      close_timer(pending)
    end
    self.permissions[tool_call_id] = nil
    self.diffs[tool_call_id] = nil
  end

  function state:close()
    if self.closed then
      return
    end
    self.closed = true
    for _, pending in pairs(self.permissions) do
      pending.replied = true
      close_timer(pending)
    end
    self.permissions = {}
    self.diffs = {}
  end

  return state
end

return M
