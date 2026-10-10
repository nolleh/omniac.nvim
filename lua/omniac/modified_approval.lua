local M = {}

local function followup_prompt(adjustments)
  local parts = {
    "The user adjusted an edit in the approval diff. The original edit was rejected so that the adjusted version can be applied instead.",
    "Apply the adjusted content for each path below. Preserve the user's changes exactly. Do not restore the original proposal.",
  }

  for index, item in ipairs(adjustments) do
    table.insert(parts, string.format("File %d: %s", index, item.path))
    table.insert(parts, "Original proposal:\n" .. item.proposedText)
    table.insert(parts, "User-approved adjusted content:\n" .. item.adjustedText)
  end

  return table.concat(parts, "\n\n")
end

function M.new(client, config, is_current)
  local ui = require("omniac.ui")
  local state = {
    client = client,
    config = config,
    is_current = is_current,
    pending = {},
    ready = {},
    active = nil,
    sending = false,
    closed = false,
  }

  local function current()
    return not state.closed and is_current() and client.session_id ~= nil
  end

  local dispatch
  dispatch = function()
    if not current() or state.sending or #state.ready == 0 or client.active_turn_id ~= nil then
      return
    end

    local batch = table.remove(state.ready, 1)
    state.sending = true
    ui.set_activity(string.format("Applying %d adjusted approval%s...", #batch, #batch == 1 and "" or "s"), config)

    local ok, err = pcall(function()
      client:prompt(followup_prompt(batch), nil, function(prompt_err, result)
        if not current() then
          return
        end
        state.sending = false
        state.active = nil
        local stop_reason = result and (result.stopReason or result.stop_reason)
        if prompt_err or stop_reason == "cancelled" or stop_reason == "canceled" or stop_reason == "error" then
          local reason = type(prompt_err) == "table" and (prompt_err.message or prompt_err)
            or (prompt_err or stop_reason)
          ui.add_message("Error", "Adjusted approval follow-up failed: " .. tostring(reason), config)
          ui.set_activity("Adjusted approval follow-up failed.", config)
        else
          ui.add_message("Notice", "Adjusted approval follow-up finished for " .. #batch .. " file(s).", config)
          ui.set_activity("Adjusted approval follow-up finished.", config)
        end
        vim.schedule(dispatch)
      end)
      state.active = { turn_id = client.active_turn_id, items = vim.deepcopy(batch) }
    end)
    if not ok then
      state.sending = false
      ui.add_message("Error", "Adjusted approval follow-up failed: " .. tostring(err), config)
      ui.set_activity("Adjusted approval follow-up failed.", config)
      vim.schedule(dispatch)
    end
  end

  function state:queue(item)
    local turn_id = client.active_turn_id
    if not current() or not turn_id or item.sessionId ~= client.session_id then
      return false
    end
    self.pending[turn_id] = self.pending[turn_id] or {}
    table.insert(self.pending[turn_id], item)
    ui.set_activity("Adjusted approval captured; waiting for this turn to finish.", config)
    return true
  end

  function state:matches_followup(params, payload)
    local active = self.active
    if not current() or not active or not active.turn_id or client.active_turn_id ~= active.turn_id then
      return false
    end
    if params.sessionId ~= client.session_id or type(payload.oldText) ~= "string" then
      return false
    end
    local file = require("omniac.filesystem").read_text_file({ path = payload.path })
    if not file or file.content ~= payload.oldText then
      return false
    end
    for index, item in ipairs(active.items) do
      if item.path == payload.path and item.adjustedText == payload.newText then
        table.remove(active.items, index)
        return true
      end
    end
    return false
  end

  function state:finish_turn(params)
    if not current() or params.sessionId ~= client.session_id then
      return
    end
    local batch = self.pending[params.turnId]
    if batch then
      self.pending[params.turnId] = nil
      table.insert(self.ready, batch)
    end
    vim.schedule(dispatch)
  end

  function state:cancel_turn(turn_id)
    self.pending[turn_id] = nil
  end

  function state:close()
    self.closed = true
    self.pending = {}
    self.ready = {}
    self.active = nil
  end

  return state
end

return M
