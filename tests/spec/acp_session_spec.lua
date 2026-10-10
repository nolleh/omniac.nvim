local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true

describe("omniac.nvim acp session", function()
  after_each(helpers.cleanup_after_test)

  it("ACP protocol file logs follow debug option", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local base = "/private/tmp/omniac-acp-log-test-" .. tostring(vim.loop.hrtime())
    local off_dir = base .. "-off"
    local on_dir = base .. "-on"

    local off_client = acp.new({
      debug = false,
      logs = { dir = off_dir },
    })
    off_client:_debug("request", { method = "session/new", params = {} })
    local off_logs = vim.fn.globpath(off_dir, "acp-*.jsonl", false, true)
    assert_equal(#off_logs, 0, "debug=false should not write ACP protocol files")

    local on_client = acp.new({
      debug = true,
      logs = { dir = on_dir },
    })
    on_client:_debug("request", { method = "session/new", params = {} })
    on_client:_debug("notification", {
      method = "session/update",
      params = { update = { sessionUpdate = "agent_message_chunk", content = "hello" } },
    })
    vim.wait(100, function()
      local paths = vim.fn.globpath(on_dir, "acp-*.jsonl", false, true)
      return #paths == 1 and #vim.fn.readfile(paths[1]) == 2
    end)
    local on_logs = vim.fn.globpath(on_dir, "acp-*.jsonl", false, true)
    assert_equal(#on_logs, 1, "debug=true should write ACP protocol files")
    assert_equal(#vim.fn.readfile(on_logs[1]), 2, "queued protocol events should flush together without loss")

    pcall(vim.fn.delete, off_dir, "rf")
    pcall(vim.fn.delete, on_dir, "rf")
  end)

  it("ACP close marks the subprocess exit as intentional", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local transport_closed = false

    client.running = true
    client.transport = {
      close = function()
        transport_closed = true
      end,
    }

    client:close()

    assert_equal(client.closing, true, "close should mark the following exit as intentional")
    assert_equal(transport_closed, true, "close should stop the ACP transport")
  end)

  it("ACP mode config options cycle with set_config_option", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requests = {}
    local updates = {}

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        table.insert(requests, {
          method = method,
          params = params,
        })
        callback(nil, {
          configOptions = {
            {
              id = "mode",
              name = "Session Mode",
              category = "mode",
              type = "select",
              currentValue = params.value,
              options = {
                { value = "plan", name = "Plan" },
                { value = "agent", name = "Agent" },
              },
            },
          },
        })
      end,
    }
    client:on_notification(function(message)
      if message.method == "omniac/session_mode_update" then
        table.insert(updates, message.params)
      end
    end)

    client:_apply_session_state({
      configOptions = {
        {
          id = "mode",
          name = "Session Mode",
          category = "mode",
          type = "select",
          currentValue = "plan",
          options = {
            { value = "plan", name = "Plan" },
            { value = "agent", name = "Agent" },
          },
        },
      },
    })
    client:cycle_session_mode(function(err)
      assert_equal(err, nil, "cycling config-backed mode should succeed")
    end)

    assert_equal(requests[1].method, "session/set_config_option", "config-backed modes should use set_config_option")
    assert_equal(requests[1].params.configId, "mode", "request should target the mode config option")
    assert_equal(requests[1].params.value, "agent", "cycle should select the next mode")
    vim.wait(50, function()
      return #updates > 0 and updates[#updates].currentModeName == "Agent"
    end)
    assert_equal(updates[#updates].currentModeName, "Agent", "mode update should expose the selected mode name")
  end)

  it("ACP model config options change with set_config_option", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local request
    local updates = {}

    client:on_notification(function(message)
      if message.method == "omniac/session_model_update" then
        table.insert(updates, message.params)
      end
    end)

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        request = { method = method, params = params }
        callback(nil, {
          configOptions = {
            {
              id = "model",
              category = "model",
              type = "select",
              currentValue = params.value,
              options = {
                { value = "gpt-5", name = "GPT-5" },
                { value = "gpt-5-mini", name = "GPT-5 Mini" },
              },
            },
          },
        })
      end,
    }
    client:_apply_session_state({
      configOptions = {
        {
          id = "model",
          category = "model",
          type = "select",
          currentValue = "gpt-5",
          options = {
            { value = "gpt-5", name = "GPT-5" },
            { value = "gpt-5-mini", name = "GPT-5 Mini" },
          },
        },
      },
    })

    vim.wait(50, function()
      return #updates > 0
    end)
    assert_equal(client:get_session_model().currentModelId, "gpt-5", "model state should expose the current model")
    assert_equal(#client:get_session_model().availableModels, 2, "model state should expose selectable models")
    assert_equal(updates[#updates].currentModelName, "GPT-5", "model update should expose the selected model name")

    local selected
    client:set_session_model("GPT-5 Mini", function(err, _, model_id)
      assert_equal(err, nil, "setting an advertised model should succeed")
      selected = model_id
    end)

    vim.wait(50, function()
      return #updates > 1
    end)
    assert_equal(request.method, "session/set_config_option", "model changes should use set_config_option")
    assert_equal(request.params.configId, "model", "request should target the model config option")
    assert_equal(request.params.value, "gpt-5-mini", "model names should resolve to their option value")
    assert_equal(selected, "gpt-5-mini", "callback should expose the selected model id")
    assert_equal(client:get_session_model().currentModelId, "gpt-5-mini", "selected model should update local state")
    assert_equal(updates[#updates].currentModelName, "GPT-5 Mini", "model update should follow model changes")
  end)

  it("ACP permission-like config modes are ignored", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local updates = {}

    client:on_notification(function(message)
      if message.method == "omniac/session_mode_update" then
        table.insert(updates, message.params)
      end
    end)
    client:_apply_session_state({
      configOptions = {
        {
          id = "mode",
          name = "Mode",
          category = "mode",
          type = "select",
          currentValue = "agent",
          options = {
            { value = "agent", name = "Agent" },
            { value = "full-access", name = "Full Access" },
            { value = "read-only", name = "Read Only" },
          },
        },
      },
    })

    vim.wait(20)
    assert_equal(#updates, 0, "permission-like modes should not be treated as planning modes")
  end)

  it("ACP legacy planning modes cycle with set_mode", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local request

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        request = {
          method = method,
          params = params,
        }
        callback(nil, {})
      end,
    }
    client:_apply_session_state({
      modes = {
        currentModeId = "plan",
        availableModes = {
          { id = "plan", name = "Plan" },
          { id = "agent", name = "Agent" },
        },
      },
    })
    client:cycle_session_mode(function(err)
      assert_equal(err, nil, "cycling legacy modes should succeed")
    end)

    assert_equal(request.method, "session/set_mode", "legacy modes should use set_mode")
    assert_equal(request.params.modeId, "agent", "cycle should select the next legacy mode")
  end)

  it("ACP cancel sends session cancel notification", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      notify = function(_, method, params)
        notification = {
          method = method,
          params = params,
        }
      end,
    }

    client:cancel(function(err)
      assert_equal(err, nil, "cancel should succeed")
    end)

    assert_equal(notification.method, "session/cancel", "cancel should use the ACP notification")
    assert_equal(notification.params.sessionId, "sess_1", "cancel should target the active session")
  end)

  it("ACP completed tool call emits tool result output", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client:on_notification(function(message)
      if message.method == "omniac/tool_result" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call_update",
          kind = "execute",
          status = "completed",
          title = "Check file",
          toolCallId = "call_tool_result",
          rawInput = {
            command = "test -f foo && echo exist || echo not exist",
            cwd = "/tmp",
          },
          rawOutput = {
            output = "exist\n",
            exit_code = 0,
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "completed tool call should emit tool_result")
    assert_equal(
      notification.params.command,
      "test -f foo && echo exist || echo not exist",
      "tool result should keep command"
    )
    assert_equal(notification.params.output, "exist\n", "tool result should keep output")
    assert_equal(notification.params.exitCode, 0, "tool result should keep exit code")
  end)

  it("ACP usage updates expose context-window consumption", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client.session_id = "sess_1"
    client:on_notification(function(message)
      if message.method == "omniac/usage_update" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "usage_update",
          used = 90000,
          size = 100000,
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "usage update should be emitted")
    assert_equal(notification.params.sessionId, "sess_1", "usage update should keep the session id")
    assert_equal(notification.params.used, 90000, "usage update should keep used tokens")
    assert_equal(notification.params.size, 100000, "usage update should keep context size")
  end)

  it("ACP prompt sends image content blocks when advertised", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local request

    client.session_id = "sess_1"
    client.running = true
    client.agent_capabilities = {
      promptCapabilities = {
        image = true,
      },
    }
    client.transport = {
      request = function(_, method, params, callback)
        request = {
          method = method,
          params = params,
        }
        callback(nil, {})
      end,
    }

    client:prompt("look", {
      prompt = {
        { type = "text", text = "look" },
        { type = "image", mimeType = "image/png", data = "aW1n" },
      },
    }, function(err)
      assert_equal(err, nil, "image prompt should be accepted when advertised")
    end)

    assert_equal(request.method, "session/prompt", "image prompts should use session/prompt")
    assert_equal(request.params.prompt[2].type, "image", "image content block should be preserved")
    assert_equal(request.params.prompt[2].data, "aW1n", "image data should be preserved")
  end)

  it("ACP prompt response emits stop reason", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local completed

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, _, callback)
        assert_equal(method, "session/prompt", "prompt should use session/prompt")
        client:_handle_notification({
          method = "session/update",
          params = {
            update = {
              sessionUpdate = "agent_message_chunk",
              content = {
                {
                  type = "text",
                  text = "hello",
                },
              },
            },
          },
        })
        client:_handle_notification({
          method = "session/update",
          params = {
            update = {
              sessionUpdate = "agent_message_chunk",
              content = {
                {
                  type = "text",
                  text = " world",
                },
              },
            },
          },
        })
        assert_equal(#client.response_chunks, 2, "streamed response chunks should accumulate without string copying")
        callback(nil, {
          stopReason = "max_tokens",
        })
      end,
    }
    client:on_notification(function(message)
      if message.method == "omniac/response_completed" then
        completed = message
      end
    end)

    client:prompt("hello")

    vim.wait(50, function()
      return completed ~= nil
    end)

    assert_true(completed ~= nil, "streamed prompt should emit response_completed")
    assert_equal(completed.params.stopReason, "max_tokens", "completion event should include stop reason")
    assert_equal(client.last_stop_reason, "max_tokens", "client should remember last stop reason")
  end)

  it("ACP replay chunks do not accumulate as an active response", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "agent_message_chunk",
          content = { { type = "text", text = string.rep("history", 1000) } },
        },
      },
    })

    assert_equal(#client.response_chunks, 0, "session replay should not retain history in the live response buffer")
  end)

  it("ACP empty prompt result still emits response_completed", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local completed

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, _, callback)
        assert_equal(method, "session/prompt", "prompt should use session/prompt")
        client:_handle_notification({
          method = "session/update",
          params = {
            update = {
              sessionUpdate = "tool_call_update",
              kind = "execute",
              status = "failed",
              title = "Run tests",
              toolCallId = "call_failed_test",
              rawOutput = {
                output = "1 test failed\n",
                exit_code = 1,
              },
            },
          },
        })
        callback(nil, {
          stopReason = "end_turn",
        })
      end,
    }
    client:on_notification(function(message)
      if message.method == "omniac/response_completed" then
        completed = message
      end
    end)

    client:prompt("run tests")

    vim.wait(50, function()
      return completed ~= nil
    end)

    assert_true(completed ~= nil, "empty prompt result should still emit response_completed")
    assert_equal(completed.params.stopReason, "end_turn", "completion should keep stop reason")
  end)

  it("ACP list sessions requests even without advertised capability", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({
      agent = {
        cwd = "/tmp/project",
      },
    })
    local request
    local listed

    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        request = {
          method = method,
          params = params,
        }
        callback(nil, {
          sessions = {
            { sessionId = "sess_1", title = "One" },
          },
        })
      end,
    }

    client:list_sessions(function(err, sessions)
      assert_equal(err, nil, "list_sessions should not fail before trying request")
      listed = sessions
    end)

    assert_equal(request.method, "session/list", "list_sessions should optimistically request session/list")
    assert_equal(request.params.cwd, "/tmp/project", "session/list should include the configured cwd")
    assert_equal(listed[1].sessionId, "sess_1", "session/list results should be returned")
  end)

  it("ACP list sessions returns the first page without blocking on pagination", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requests = {}
    local listed

    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        table.insert(requests, {
          method = method,
          params = params,
        })
        callback(nil, {
          sessions = {
            { sessionId = "sess_1" },
          },
          nextCursor = "cursor_2",
        })
      end,
    }

    client:list_sessions(function(err, sessions)
      assert_equal(err, nil, "list_sessions should return the first page")
      listed = sessions
    end)

    assert_equal(#requests, 1, "session selection should not wait for later pages")
    assert_equal(requests[1].params.cursor, nil, "session selection should request the latest page")
    assert_equal(#listed, 1, "sessions from the first page should be returned")
    assert_equal(listed[1].sessionId, "sess_1", "the recent session should be included")
  end)

  it("ACP select session falls back when list request fails", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local selector_opts
    local client = acp.new({
      agent = {
        session = {
          action = "select",
        },
      },
      session_selector = function(sessions, opts, callback)
        selector_opts = opts
        callback({ action = "new" })
      end,
    })
    local methods = {}

    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        table.insert(methods, method)
        if method == "session/list" then
          callback({ message = "not supported" }, nil)
        elseif method == "session/new" then
          callback(nil, { sessionId = "new_session" })
        else
          callback(nil, {})
        end
      end,
    }

    client:_setup_session(function(err, result, method)
      assert_equal(err, nil, "select fallback should continue with chosen new session")
      assert_equal(method, "session/new", "fallback selection should create a new session")
    end)

    assert_equal(methods[1], "session/list", "select setup should try session/list first")
    assert_equal(selector_opts.list_supported, false, "selector should know list failed")
    assert_true(selector_opts.message:match("not supported") ~= nil, "selector should receive the list error message")
  end)

  it("ACP mode state can be nested in session result", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local updates = {}

    client:on_notification(function(message)
      if message.method == "omniac/session_mode_update" then
        table.insert(updates, message.params)
      end
    end)
    client:_apply_session_state({
      session = {
        modes = {
          currentModeId = "plan",
          availableModes = {
            { id = "plan", name = "Plan" },
            { id = "auto", name = "Auto" },
          },
        },
      },
    })

    vim.wait(50, function()
      return #updates > 0 and updates[#updates].currentModeName == "Plan"
    end)
    assert_equal(updates[#updates].currentModeName, "Plan", "nested session mode should be parsed")
  end)
end)
