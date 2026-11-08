local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true

local function recorder()
  local client = require("omniac.backend.acp").new({})
  client.active_turn_id = 7
  local results = {}
  local activities = {}
  client:on_notification(function(message)
    if message.method == "omniac/tool_result" then
      table.insert(results, message.params)
    elseif message.method == "omniac/tool_activity" then
      table.insert(activities, message.params)
    end
  end)
  local function send(update)
    client:_handle_notification({ method = "session/update", params = { update = update } })
    vim.wait(10, function()
      return false
    end)
  end
  return client, results, activities, send
end

describe("omniac.nvim ACP tool call aggregation", function()
  after_each(helpers.cleanup_after_test)

  it("produces the same result for live and history terminal event sequences", function()
    local outputs = {}
    for _, replay in ipairs({ false, true }) do
      local client, results, activities, send = recorder()
      send({
        sessionUpdate = "tool_call",
        toolCallId = "exec-example",
        kind = "execute",
        title = "Check files",
        status = replay and "completed" or "in_progress",
        rawInput = { command = "check-files", cwd = "/tmp" },
        content = { { type = "terminal", terminalId = "exec-example" } },
      })
      assert_equal(#results, 0, "a terminal reference is not output, even when already completed")
      send({
        sessionUpdate = "tool_call_update",
        toolCallId = "exec-example",
        _meta = { terminal_output_delta = { data = "first\n" } },
      })
      assert_equal(#results, 0, "partial output should wait for terminal completion")
      local completion = {
        sessionUpdate = "tool_call_update",
        toolCallId = "exec-example",
        status = not replay and "completed" or nil,
        _meta = {
          terminal_output_delta = { data = "second\n" },
          terminal_exit = { exit_code = 0 },
        },
      }
      send(completion)
      assert_equal(#results, 1)
      assert_equal(results[1].output, "first\nsecond\n")
      assert_equal(results[1].command, "check-files")
      assert_equal(results[1].title, "Check files")
      assert_equal(results[1].cwd, "/tmp")
      assert_equal(results[1].exitCode, 0)
      assert_equal(activities[#activities].status, "completed", "missing fields should retain prior status")
      assert_equal(activities[#activities].title, "Check files", "output-only updates should retain the title")
      send(completion)
      assert_equal(#results, 1, "repeated completion must not add a duplicate transcript entry")
      assert_equal(client.tool_calls["exec-example"].chunks, nil, "completed calls must release output chunks")
      table.insert(outputs, results[1])
    end
    assert.are.same(outputs[1], outputs[2])
  end)

  it("keeps interleaved tool output separate and supports ordinary ACP text results", function()
    local _, results, _, send = recorder()
    for _, id in ipairs({ "a", "b" }) do
      send({
        sessionUpdate = "tool_call",
        toolCallId = id,
        status = "in_progress",
        kind = "execute",
        rawInput = { command = "run-" .. id },
      })
    end
    send({
      sessionUpdate = "tool_call_update",
      toolCallId = "a",
      _meta = { terminal_output_delta = { data = "output-a" } },
    })
    send({
      sessionUpdate = "tool_call_update",
      toolCallId = "b",
      status = "failed",
      content = {
        { type = "content", content = { type = "text", text = "failure-b" } },
        { type = "content", content = { type = "text", text = "details-b" } },
      },
    })
    send({
      sessionUpdate = "tool_call_update",
      toolCallId = "a",
      _meta = { terminal_exit = { exit_code = 0 } },
    })
    assert_equal(#results, 2)
    assert_equal(results[1].command, "run-b")
    assert_equal(results[1].output, "failure-b\ndetails-b")
    assert_equal(results[1].status, "failed")
    assert_equal(results[2].command, "run-a")
    assert_equal(results[2].output, "output-a")
    assert_equal(results[2].status, "completed")
  end)

  it("does not turn references, IDs or empty terminal output into result text", function()
    local _, results, _, send = recorder()
    send({
      sessionUpdate = "tool_call",
      toolCallId = "references",
      status = "completed",
      content = {
        { type = "terminal", terminalId = "exec-private-id" },
        { type = "resource_link", uri = "file:///tmp/example", name = "example" },
        { type = "diff", path = "/tmp/example", newText = "not terminal output" },
      },
      rawOutput = { exit_code = 0, terminalId = "exec-private-id" },
    })
    send({
      sessionUpdate = "tool_call_update",
      toolCallId = "references",
      _meta = { terminal_exit = { exit_code = 0 } },
    })
    assert_equal(#results, 0)
  end)

  it("prefers a final output snapshot over already streamed chunks", function()
    local _, results, _, send = recorder()
    send({
      sessionUpdate = "tool_call",
      toolCallId = "snapshot",
      status = "in_progress",
      _meta = { terminal_output_delta = { data = "hello" } },
    })
    send({
      sessionUpdate = "tool_call_update",
      toolCallId = "snapshot",
      status = "completed",
      rawOutput = { stdout = "hello world", exitCode = 0 },
    })
    assert_equal(#results, 1)
    assert_equal(results[1].output, "hello world", "a snapshot must not be appended to its own prefix")
  end)

  it("clears tool aggregation at a new turn and on close", function()
    local client, _, _, send = recorder()
    send({ sessionUpdate = "tool_call", toolCallId = "old", status = "in_progress" })
    assert_true(client.tool_calls.old ~= nil)
    client.running = true
    client.session_id = "session"
    client.transport = {
      request = function(_, _, _, callback)
        assert_equal(next(client.tool_calls), nil, "new turns should not retain historical tool state")
        callback(nil, { stopReason = "end_turn" })
      end,
      close = function() end,
    }
    client:prompt("next")
    send({ sessionUpdate = "tool_call", toolCallId = "new", status = "in_progress" })
    client:close()
    assert_equal(next(client.tool_calls), nil)
  end)

  it("does not retain completion markers across session load or resume", function()
    local client, _, _, send = recorder()
    client.transport = {
      request = function(_, _, _, callback)
        assert_equal(next(client.tool_calls), nil, "a new history replay may reuse the same tool IDs")
        callback(nil, {})
      end,
    }
    for _, method in ipairs({ "_load_session", "_resume_session" }) do
      send({
        sessionUpdate = "tool_call",
        toolCallId = "reused",
        status = "completed",
        rawOutput = "done",
      })
      assert_true(client.tool_calls.reused.emitted)
      client[method](client, "another-session", function() end)
    end
  end)
end)
