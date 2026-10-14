local M = {}

local function applied_count(batch)
  local filesystem = require("omniac.filesystem")
  local count = 0
  for _, item in ipairs(batch) do
    local file = filesystem.read_text_file({ path = item.path })
    if file and file.content == item.adjustedText then
      count = count + 1
    end
  end
  return count
end

local function followup_prompt(adjustments)
  local parts = {
    "The user adjusted an edit in the approval diff. The original edit batch was rejected so that the reviewed versions can be applied instead.",
    "Apply the reviewed content for each path below. Preserve the user's changes exactly. Do not restore the original proposal.",
  }

  for index, item in ipairs(adjustments) do
    table.insert(parts, string.format("File %d: %s", index, item.path))
    table.insert(parts, "Original proposal:\n" .. item.proposedText)
    table.insert(parts, "User-reviewed content:\n" .. item.adjustedText)
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
        local continued = state.active and state.active.followup_queued
        state.active = nil
        local stop_reason = result and (result.stopReason or result.stop_reason)
        if continued and not prompt_err and (stop_reason == "cancelled" or stop_reason == "canceled") then
          ui.set_activity("Adjusted approval captured; applying the next reviewed edit.", config)
        elseif prompt_err or stop_reason == "cancelled" or stop_reason == "canceled" or stop_reason == "error" then
          local reason = type(prompt_err) == "table" and (prompt_err.message or prompt_err)
            or (prompt_err or stop_reason)
          local applied = applied_count(batch)
          if applied == #batch then
            ui.add_message("Notice", "Reviewed content is present in all " .. #batch .. " file(s).", config)
            ui.set_activity("Reviewed edits applied.", config)
          else
            ui.add_message(
              "Error",
              string.format(
                "Adjusted approval follow-up ended (%s). Reviewed content confirmed in %d of %d file(s); check the remaining files.",
                tostring(reason),
                applied,
                #batch
              ),
              config
            )
            ui.set_activity("Adjusted approval follow-up ended; check remaining files.", config)
          end
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
    local items = item.path and { item } or item
    if not current() or not turn_id or type(items) ~= "table" or #items == 0 then
      return false
    end
    for _, entry in ipairs(items) do
      if entry.sessionId ~= client.session_id then
        return false
      end
    end
    self.pending[turn_id] = self.pending[turn_id] or {}
    for _, entry in ipairs(items) do
      table.insert(self.pending[turn_id], entry)
    end
    if self.active and self.active.turn_id == turn_id then
      self.active.followup_queued = true
    end
    ui.set_activity("Adjusted approval captured; waiting for this turn to finish.", config)
    return true
  end

  function state:matches_followup(params, payload)
    local active = self.active
    if not current() or not active or not active.turn_id or client.active_turn_id ~= active.turn_id then
      return false
    end
    if params.sessionId ~= client.session_id or type(payload) ~= "table" then
      return false
    end
    local payloads = payload.path and { payload } or payload
    if type(payloads) ~= "table" or #payloads == 0 then
      return false
    end
    local remaining = vim.deepcopy(active.items)
    local filesystem = require("omniac.filesystem")
    for _, entry in ipairs(payloads) do
      if type(entry.oldText) ~= "string" then
        return false
      end
      local file = filesystem.read_text_file({ path = entry.path })
      if not file or file.content ~= entry.oldText then
        return false
      end
      local match_index
      for index, item in ipairs(remaining) do
        if item.path == entry.path and item.adjustedText == entry.newText then
          match_index = index
          break
        end
      end
      if not match_index then
        return false
      end
      table.remove(remaining, match_index)
    end
    active.items = remaining
    return true
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
