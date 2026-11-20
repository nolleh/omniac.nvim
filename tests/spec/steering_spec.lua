local helpers = require("tests.helpers")

describe("omniac.nvim mid-turn steering", function()
  local app, ui, client, state, requests

  before_each(function()
    helpers.cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    app = require("omniac")
    ui = require("omniac.ui")
    app.config = require("omniac.config").merge({
      ui = { chat_width = 60, mascot_motion = false, mascot_follow_cursor = false },
    })
    client = require("omniac.backend.acp").new(app.config)
    client.running = true
    client.session_id = "steering-session"
    client.steering_supported = true
    requests = {}
    client.transport = {
      request = function(_, method, params, callback)
        table.insert(requests, { method = method, params = params, callback = callback })
      end,
      close = function() end,
    }
    client:on_notification(function(message)
      ui.handle_notification(message, app.config)
    end)
    app.backend = client
    app.open_chat()
    state = ui.open(app.config)
    ui.clear_conversation(app.config)
    vim.v.errmsg = ""
  end)

  after_each(function()
    client:close()
    app.backend = nil
    app.active_submission = nil
    app.queued_submissions = {}
    helpers.cleanup_after_test()
  end)

  local function wait_for(predicate)
    assert.is_true(vim.wait(500, predicate))
  end

  local function update(value)
    client:_handle_notification({
      method = "session/update",
      params = { sessionId = client.session_id, update = value },
    })
  end

  local function status(kind)
    update({ sessionUpdate = "session_info_update", _meta = { codex = { threadStatus = { type = kind } } } })
  end

  local function user_count(text)
    local count = 0
    for _, message in ipairs(state.messages) do
      if message.role == "You" and message.text == text then
        count = count + 1
      end
    end
    return count
  end

  local agent_commands = {
    "/plan",
    "/mcp",
    "/skills",
    "/status",
    "/review",
    "/review-branch main",
    "/review-commit abc123",
    "/compact",
    "/goal keep testing",
    "/rename new title",
    "/logout",
  }

  for _, command in ipairs(agent_commands) do
    it("guards active-turn agent commands without changing the current request: " .. command, function()
      state.submit("first", {})
      local active, turn_id = app.active_submission, client.active_turn_id
      local messages = #state.messages
      assert.is_false(state.submit(command, {}))
      assert.equals(1, #requests)
      assert.equals(active, app.active_submission)
      assert.equals(turn_id, client.active_turn_id)
      assert.equals(messages, #state.messages)
      assert.equals(0, #app.queued_submissions)
      assert.is_nil(app.failed_submission)
      assert.is_truthy(state.transient_activity:find("cannot run during a turn through ACP", 1, true))
      requests[1].callback(nil, { stopReason = "end_turn" })
    end)
  end

  it("proxies idle commands and preserves agent errors", function()
    for _, command in ipairs(agent_commands) do
      state.submit(command, {})
      local request = requests[#requests]
      assert.equals("session/prompt", request.method)
      assert.equals(command, request.params.prompt[1].text)
      request.callback(nil, { stopReason = "end_turn" })
    end
    state.submit("/compact", {})
    requests[#requests].callback({ message = "Compaction rejected by agent" })
    assert.equals("/compact", app.failed_submission.text)
    assert.is_truthy(vim.inspect(state.messages):find("Compaction rejected by agent", 1, true))
  end)

  it("preserves a blocked command draft and sends it only when retried after completion", function()
    helpers.feed("ifirst<CR>")
    helpers.feed("i/status<CR>")
    assert.equals(1, #requests)
    assert.is_truthy(
      table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"):find("/status", 1, true)
    )
    requests[1].callback(nil, { stopReason = "end_turn" })
    vim.wait(30, function()
      return false
    end)
    assert.equals(1, #requests, "blocked commands must not run automatically")
    helpers.feed("<CR>")
    assert.equals(2, #requests)
    assert.equals("/status", requests[2].params.prompt[1].text)
    requests[2].callback(nil, { stopReason = "end_turn" })
  end)

  it("guards future commands and multiline arguments without treating dollar skills as commands", function()
    state.submit("first", {})
    assert.is_false(app.steer("/future-command", {}))
    assert.is_false(app.ask("/status"))
    assert.is_false(state.submit("/review first line\nsecond line", {}))
    assert.equals(1, #requests)
    assert.is_true(state.submit("$code-explanation explain this", {}))
    assert.equals("_session/steering", requests[2].method)
    requests[2].callback(nil, { outcome = "injected" })
    requests[1].callback(nil, { stopReason = "end_turn" })
  end)

  it("sends absolute-path messages as steering without changing the current request", function()
    state.submit("first", {})
    local active, turn_id = app.active_submission, client.active_turn_id
    for _, text in ipairs({
      "/Users/nolleh/project/main.lua 파일도 확인해줘",
      "/tmp/project/file-name.lua check this file",
      "/var/log/app.log\nCheck this log too",
    }) do
      assert.is_true(state.submit(text, {}))
      local request = requests[#requests]
      assert.equals("_session/steering", request.method)
      assert.equals(text, request.params.prompt[1].text)
      assert.equals(active, app.active_submission)
      assert.equals(turn_id, client.active_turn_id)
      request.callback(nil, { outcome = "injected" })
    end
    assert.equals(4, #requests)
    assert.equals(0, #app.queued_submissions)
    requests[1].callback(nil, { stopReason = "end_turn" })
  end)

  it("keeps local commands available through their dedicated handlers", function()
    state.submit("first", {})
    for command, method in pairs({
      changes = "review_changes",
      model = "select_model",
      mode = "select_mode",
      exit = "exit",
    }) do
      local called = false
      app[method] = function()
        called = true
      end
      state.submit("/" .. command, {})
      assert.is_true(called)
    end
    assert.equals(1, #requests)
    requests[1].callback(nil, { stopReason = "end_turn" })
  end)

  for _, command in ipairs({ "/clear", "/resume", "/compact", "/status" }) do
    it("also guards commands while only a steering acknowledgment is pending: " .. command, function()
      client.steering_requests = 1
      assert.is_false(state.submit(command, {}))
      assert.equals(0, #requests)
      assert.is_nil(app.active_submission)
      client.steering_requests = 0
    end)
  end

  it("uses the initialize response to negotiate steering support", function()
    for _, enabled in ipairs({ true, false }) do
      client.transport.request = function(_, method, _, callback)
        assert.equals("initialize", method)
        callback(nil, { protocolVersion = 1, _meta = { steering = { supported = enabled } } })
      end
      client:_initialize(function(err)
        assert.is_nil(err)
      end)
      assert.equals(enabled, client:supports_steering())
    end
  end)

  it("sends Enter immediately as steering while Tab waits for the full turn", function()
    helpers.feed("ifirst<CR>")
    local turn_id = client.active_turn_id
    local active = app.active_submission
    update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Before " } })
    wait_for(function()
      return state.streaming_message_index ~= nil
    end)
    local response = state.streaming_message_index
    helpers.feed("ichange direction<CR>")
    assert.equals(2, #requests)
    assert.equals("_session/steering", requests[2].method)
    assert.equals("steering-session", requests[2].params.sessionId)
    assert.is_truthy(requests[2].params.prompt[1].text:find("change direction", 1, true))
    assert.equals(active, app.active_submission)
    assert.equals(turn_id, client.active_turn_id)
    assert.equals(response, state.streaming_message_index)
    assert.equals(1, user_count("change direction"))
    assert.equals("", vim.v.errmsg)
    helpers.feed("iqueued later<Tab>")
    assert.equals(2, #requests)
    requests[2].callback(nil, { outcome = "injected" })
    update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "after" } })
    requests[1].callback(nil, { stopReason = "end_turn" })
    wait_for(function()
      return #requests == 3
    end)
    assert.equals("Before after", state.messages[response].text)
    assert.equals("session/prompt", requests[3].method)
    assert.is_truthy(requests[3].params.prompt[1].text:find("queued later", 1, true))
    requests[3].callback(nil, { stopReason = "end_turn" })
  end)

  for _, order in ipairs({ "ack_first", "status_first", "completion_first" }) do
    it("tracks a steering-created turn before draining the queue: " .. order, function()
      state.submit("first", {})
      state.submit("steer", {})
      state.queue_submit("queued", {})
      requests[1].callback(nil, { stopReason = "end_turn" })
      local function acknowledge()
        requests[2].callback(nil, { outcome = "startedNewTurn" })
      end
      if order == "ack_first" then
        acknowledge()
      end
      status("active")
      if order == "status_first" then
        acknowledge()
      end
      wait_for(function()
        return state.status == "working" and client.active_turn_id ~= nil
      end)
      assert.equals(2, #requests)
      local external_turn = client.active_turn_id
      update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "External answer" } })
      status("idle")
      if order == "completion_first" then
        acknowledge()
      end
      wait_for(function()
        return #requests == 3
      end)
      assert.equals(external_turn + 1, client.active_turn_id)
      assert.equals("session/prompt", requests[3].method)
      assert.equals(0, client.steering_requests)
      assert.is_false(client.steering_external_turn)
      assert.equals(1, user_count("steer"))
      requests[3].callback(nil, { stopReason = "end_turn" })
    end)
  end

  for _, signal in ipairs({ "acknowledgment", "status" }) do
    it("preserves a new steering turn when the old prompt response arrives late: " .. signal, function()
      state.submit("first", {})
      state.submit("steer", {})
      if signal == "acknowledgment" then
        requests[2].callback(nil, { outcome = "startedNewTurn" })
      else
        status("idle")
        status("active")
      end
      local external_turn = client.active_turn_id
      assert.equals(2, external_turn)
      requests[1].callback(nil, { stopReason = "end_turn" })
      assert.equals(external_turn, client.active_turn_id)
      update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "New turn" } })
      if signal == "status" then
        requests[2].callback(nil, { outcome = "startedNewTurn" })
      end
      status("idle")
      wait_for(function()
        return state.status == "ready"
      end)
      assert.is_nil(client.active_turn_id)
      assert.equals(2, client.turn_sequence)
    end)
  end

  it("keeps the input when steering is unsupported", function()
    client.steering_supported = false
    helpers.feed("ifirst<CR>")
    helpers.feed("ikeep this<CR>")
    assert.equals(1, #requests)
    assert.is_truthy(
      table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"):find("keep this", 1, true)
    )
    assert.equals(0, user_count("keep this"))
    requests[1].callback(nil, { stopReason = "end_turn" })
  end)

  it("restores a rejected steering message without failing or ending the active turn", function()
    helpers.feed("ifirst<CR>")
    local active = app.active_submission
    local turn_id = client.active_turn_id
    helpers.feed("itry again<CR>")
    requests[2].callback({ message = "Steering denied" })
    wait_for(function()
      return table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"):find("try again", 1, true)
        ~= nil
    end)
    assert.equals(active, app.active_submission)
    assert.equals(turn_id, client.active_turn_id)
    assert.equals("working", state.status)
    assert.is_nil(app.failed_submission)
    requests[1].callback(nil, { stopReason = "end_turn" })
  end)

  it("keeps concurrent steering acknowledgments from releasing queued prompts early", function()
    state.submit("first", {})
    state.submit("steer one", {})
    state.submit("steer two", {})
    state.queue_submit("queued", {})
    requests[1].callback(nil, { stopReason = "end_turn" })
    requests[2].callback(nil, { outcome = "injected" })
    vim.wait(30, function()
      return false
    end)
    assert.equals(3, #requests)
    requests[3].callback(nil, { outcome = "injected" })
    wait_for(function()
      return #requests == 4
    end)
    assert.equals("session/prompt", requests[4].method)
    requests[4].callback(nil, { stopReason = "end_turn" })
  end)

  it("sends attachment context and rejects unsupported images before transport", function()
    state.submit("first", {})
    assert.is_true(
      state.submit("context", { { type = "reference", path = "/tmp/context.lua", text = "saved context" } })
    )
    assert.is_truthy(vim.inspect(requests[2].params.prompt):find("saved context", 1, true))
    requests[2].callback(nil, { outcome = "injected" })
    local failure
    client:steer("image", { prompt = { { type = "image", data = "png", mimeType = "image/png" } } }, function(err)
      failure = err
    end)
    assert.is_truthy(failure.message:find("image", 1, true))
    assert.equals(2, #requests)
    requests[1].callback(nil, { stopReason = "end_turn" })
  end)
end)
