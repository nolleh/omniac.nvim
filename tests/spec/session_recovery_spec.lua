local helpers = require("tests.helpers")

describe("omniac.nvim session recovery", function()
  local transport = require("omniac.transport")
  local dialog = require("omniac.session.dialog")
  local ui = require("omniac.ui")
  local original_new, original_dialog, original_open
  local app, submit, requests, replay_history

  before_each(function()
    original_new = transport.new
    original_dialog = dialog.open
    original_open = ui.open
    package.loaded["omniac"] = nil
    app = require("omniac")
    app.config = require("omniac.config").merge({ debug = false })
    requests = {}
    replay_history = nil
    ui.open = function(_, callback)
      submit = callback
    end
    transport.new = function()
      local instance = {}
      function instance:on_notification(callback)
        self.notify = callback
        return self
      end
      function instance:on_request()
        return self
      end
      function instance:on_exit(callback)
        self.exit = callback
        return self
      end
      function instance:start() end
      function instance:close()
        vim.schedule(function()
          self.exit(143, "exit")
        end)
      end
      function instance:request(method, params, callback)
        table.insert(requests, { method = method, params = params })
        vim.schedule(function()
          if method == "initialize" then
            callback(nil, {
              protocolVersion = 1,
              agentCapabilities = { loadSession = true, sessionCapabilities = { resume = {} } },
            })
          elseif method == "session/list" then
            callback(nil, { sessions = { { sessionId = "available-session" } } })
          elseif params.sessionId == "locked-session" then
            callback({ message = "Internal error", data = { details = "already has an active writer" } })
          else
            if method == "session/load" and replay_history then
              replay_history(self, params.sessionId)
            end
            callback(nil, { sessionId = params.sessionId or "new-session" })
          end
        end)
      end
      return instance
    end
    dialog.open = function(sessions, opts, callback)
      helpers.assert_equal(opts.list_supported, true, "recovery should fetch the session list")
      helpers.assert_equal(sessions[1].sessionId, "available-session")
      callback({ action = "load", id = sessions[1].sessionId })
    end
  end)

  after_each(function()
    app.disconnect()
    vim.wait(20)
    transport.new = original_new
    dialog.open = original_dialog
    ui.open = original_open
    helpers.cleanup_after_test()
  end)

  for _, action in ipairs({ "load", "resume" }) do
    it("recovers through /resume after session/" .. action .. " fails", function()
      app.open_chat({ session = { action = action, id = "locked-session" } })
      helpers.assert_true(
        vim.wait(500, function()
          return app.backend and not app.backend.running
        end),
        "failed setup should close the connection"
      )
      helpers.assert_equal(app.backend.transport, nil)

      submit("/resume", {})
      helpers.assert_true(
        vim.wait(1000, function()
          return app.backend and app.backend.session_id == "available-session"
        end),
        "resume should reconnect, list sessions, and load the selected session"
      )
      local listed = false
      for _, request in ipairs(requests) do
        listed = listed or request.method == "session/list"
      end
      helpers.assert_true(listed, "recovery must request sessions over a fresh connection")

      local completed = false
      app.backend:prompt("continue", nil, function(err)
        helpers.assert_equal(err, nil)
        completed = true
      end)
      helpers.assert_true(
        vim.wait(500, function()
          return completed
        end),
        "recovered session should accept prompts"
      )
      helpers.assert_equal(requests[#requests].params.sessionId, "available-session")
    end)
  end

  it("opens the session list through /resume after disconnecting", function()
    app.open_chat()
    helpers.assert_true(vim.wait(500, function()
      return app.backend and app.backend.session_id == "new-session"
    end))
    app.disconnect()
    submit("/resume", {})
    helpers.assert_true(
      vim.wait(1000, function()
        return app.backend and app.backend.session_id == "available-session"
      end),
      "disconnected resume should reconnect and list sessions"
    )
  end)

  it("replaces history on repeated /resume selections and keeps user and agent turns separate", function()
    local state
    ui.open = function(cfg, callback, queue_callback)
      submit = callback or submit
      state = original_open(cfg, callback, queue_callback)
      return state
    end
    local selected = "first-session"
    dialog.open = function(_, _, callback)
      callback({ action = "load", id = selected })
    end
    replay_history = function(instance, id)
      for _, update in ipairs({
        { sessionUpdate = "user_message_chunk", content = { type = "text", text = id .. " question" } },
        { sessionUpdate = "agent_message_chunk", content = { type = "text", text = id .. " answer" } },
        { sessionUpdate = "user_message_chunk", content = { type = "text", text = "Follow " } },
        { sessionUpdate = "user_message_chunk", content = { type = "text", text = "up" } },
        { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Final answer" } },
      }) do
        instance.notify({ method = "session/update", params = { sessionId = id, update = update } })
      end
    end
    app.open_chat()
    helpers.assert_true(vim.wait(500, function()
      return app.backend and app.backend.session_id == "new-session"
    end))
    ui.add_message("You", "Old conversation", app.config)
    for _, id in ipairs({ "first-session", "second-session", "second-session" }) do
      selected = id
      local previous = app.backend
      submit("/resume", {})
      helpers.assert_true(vim.wait(1000, function()
        return app.backend ~= previous and app.backend and app.backend.session_id == id and not state.session_loading
      end))
      helpers.assert_equal(#state.messages, 4, "only the selected conversation should remain")
      helpers.assert_equal(state.messages[1].role, "You")
      helpers.assert_equal(state.messages[1].text, id .. " question")
      helpers.assert_equal(state.messages[2].role, "Omniac")
      helpers.assert_equal(state.messages[2].text, id .. " answer")
      helpers.assert_equal(state.messages[3].text, "Follow up")
      helpers.assert_equal(state.messages[4].text, "Final answer")
    end
    submit("Continue", {})
    helpers.assert_true(vim.wait(500, function()
      return app.active_submission == nil
    end))
    helpers.assert_equal(requests[#requests].method, "session/prompt")
    helpers.assert_equal(requests[#requests].params.sessionId, "second-session")
  end)
end)
