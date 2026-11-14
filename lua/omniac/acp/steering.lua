local M = {}

function M.busy(client)
  return (client.steering_requests or 0) > 0 or client.steering_external_turn == true
end

function M.status(client, update)
  local meta = type(update._meta) == "table" and update._meta.codex or nil
  local status = type(meta) == "table" and meta.threadStatus or nil
  local kind = type(status) == "table" and status.type or nil
  if kind == "active" and M.busy(client) then
    if client.active_turn_id == nil or client.steering_idle_observed then
      if client.active_turn_id ~= nil then
        client:_emit_response({ stopReason = "end_turn" })
      end
      client.steering_external_turn = true
      client:_start_prompt_turn()
    end
    client.steering_idle_observed = false
  elseif (kind == "idle" or kind == "systemError") and client.steering_external_turn then
    client.steering_external_turn = false
    client.steering_completed = (client.steering_completed or 0) + 1
    client:_emit_response({ stopReason = kind == "idle" and "end_turn" or "error" })
    local waiters = client.steering_waiters or {}
    client.steering_waiters = {}
    for _, finish in ipairs(waiters) do
      finish(kind == "systemError" and { message = "Steering turn failed" } or nil)
    end
  elseif kind == "idle" or kind == "systemError" then
    client.steering_idle_observed = true
  end
end

function M.request(client, params, callback)
  local completed = client.steering_completed or 0
  local transport = client.transport
  local session_id = client.session_id
  client.steering_requests = (client.steering_requests or 0) + 1
  local done = false
  local function finish(err, result)
    if done then
      return
    end
    done = true
    client.steering_requests = math.max(0, (client.steering_requests or 0) - 1)
    callback(err, result)
  end
  local ok, err = pcall(function()
    transport:request("_session/steering", params, function(request_err, result)
      if client.transport ~= transport or client.session_id ~= session_id then
        finish({ message = "Session changed before steering completed" })
      elseif request_err then
        finish(request_err)
      elseif type(result) ~= "table" or (result.outcome ~= "injected" and result.outcome ~= "startedNewTurn") then
        finish({ message = "Agent did not accept the steering message" })
      elseif result.outcome == "injected" then
        finish(nil, result)
      elseif (client.steering_completed or 0) > completed then
        finish(nil, result)
      else
        if not client.steering_external_turn then
          if client.active_turn_id ~= nil then
            client:_emit_response({ stopReason = "end_turn" })
          end
          client:_start_prompt_turn()
        end
        client.steering_idle_observed = false
        client.steering_external_turn = true
        client.steering_waiters = client.steering_waiters or {}
        table.insert(client.steering_waiters, function(turn_err)
          finish(turn_err, result)
        end)
      end
    end)
  end)
  if not ok then
    finish({ message = tostring(err) })
  end
end

return M
