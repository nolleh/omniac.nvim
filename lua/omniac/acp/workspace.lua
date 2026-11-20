local snapshot = require("omniac.changes.snapshot")
local M = {}

function M.new(client)
  local cwd = (client.config.agent or {}).cwd or vim.loop.cwd()
  local state = {
    initial = snapshot.capture(cwd),
    pending = {},
    completed = {},
    session_id = client.session_id,
    turn_id = client.active_turn_id,
  }
  local baseline = state.initial
  local window

  function state:checkpoint()
    return baseline
  end

  local function collect(source)
    local current = snapshot.capture(cwd)
    for _, change in ipairs(snapshot.diff(window or baseline, current)) do
      client:_emit_notification({
        method = "omniac/file_update",
        params = vim.tbl_extend("force", change, {
          sessionId = state.session_id,
          turnId = state.turn_id,
          source = source or "workspace",
        }),
      })
    end
    baseline = current
    window = nil
  end

  function state:update(update, activity)
    local id = update.toolCallId
    local call = id and client.tool_calls[id]
    if not id or not call or call.turn_id ~= self.turn_id or self.completed[id] then
      return
    end
    local editing = activity.kind == "edit" or activity.kind == "delete" or activity.kind == "move"
    if not editing and activity.kind ~= "execute" and not call.command and not call.terminal then
      return
    end
    local done = activity.status == "completed" or activity.status == "failed"
    if call.terminal and not call.terminal_finished then
      done = false
    end
    if not self.pending[id] then
      if not next(self.pending) and not done then
        window = snapshot.capture(cwd)
      end
      self.pending[id] = true
    end
    if done then
      self.pending[id] = nil
      self.completed[id] = true
      if not next(self.pending) then
        collect(editing and "acp" or "terminal")
      end
    end
  end

  function state:finish()
    if next(self.pending) then
      collect()
      self.pending = {}
    end
  end

  return state
end

return M
