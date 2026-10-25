local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim core", function()
  after_each(helpers.cleanup_after_test)

  it("defaults use an ACP agent without backend selection", function()
    package.loaded["omniac.config"] = nil
    local defaults = require("omniac.config").defaults

    assert_equal(defaults.agent.cmd[1], "codex-acp", "default command should speak ACP")
    assert_equal(defaults.backend, nil, "backend selection should not be configurable")
    assert_equal(defaults.agent.auto_initialize, nil, "legacy transport initialization should be removed")
    assert_equal(defaults.ui.change_review, "summary", "change review should default to a non-blocking summary")
    assert_equal(defaults.ui.welcome_card, "pinned", "welcome card should default to pinned")
    assert_equal(defaults.ui.mascot_follow_cursor, true, "mascot gaze should default to enabled")
    assert_equal(defaults.ui.mascot_motion, true, "mascot idle and work motion should default to enabled")
    assert_equal(defaults.references.include_modified_buffer, false, "full modified-buffer references should be opt-in")
  end)

  it("stdio transport exposes protocol primitives only", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({})

    assert_true(type(client.request) == "function", "transport should expose JSON-RPC requests")
    assert_true(type(client.notify) == "function", "transport should expose JSON-RPC notifications")
    assert_true(type(client.respond) == "function", "transport should expose JSON-RPC responses")
    assert_equal(client.thread_start, nil, "transport should not expose Codex thread startup")
    assert_equal(client.turn_start, nil, "transport should not expose Codex turn startup")
    assert_equal(client.prompt, nil, "transport should not expose Codex prompt handling")
  end)

  it("stdio transport sends JSON-RPC 2.0 request and response envelopes", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({})
    local sent = {}

    client.running = true
    client.jobid = 1
    client._send_raw = function(_, payload)
      table.insert(sent, payload)
    end

    client:request("initialize", {})
    client:notify("session/cancel", { sessionId = "sess_1" })
    client:respond("server-request", {})
    client:_dispatch_message({
      jsonrpc = "2.0",
      id = "agent-request",
      method = "client/unknown",
      params = {},
    })

    assert_equal(sent[1].jsonrpc, "2.0", "requests should declare JSON-RPC 2.0")
    assert_equal(sent[1].method, "initialize", "request method should be preserved")
    assert_equal(sent[2].method, "session/cancel", "notification method should be preserved")
    assert_equal(sent[2].id, nil, "notifications must not have an id")
    assert_equal(sent[2].params.sessionId, "sess_1", "notification params should be preserved")
    assert_equal(sent[3].jsonrpc, "2.0", "responses should declare JSON-RPC 2.0")
    assert_equal(sent[3].id, "server-request", "response id should be preserved")
    assert_equal(sent[4].jsonrpc, "2.0", "automatic responses should declare JSON-RPC 2.0")
    assert_equal(sent[4].id, "agent-request", "automatic response id should be preserved")
  end)

  it("times out unanswered requests and ignores late responses", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({
      client = { request_timeout_ms = 20, prompt_timeout_ms = 40 },
    })
    local errors = {}
    client.running = true
    client.jobid = 1
    client._send_raw = function() end

    local id = client:request("initialize", {}, function(err)
      table.insert(errors, err)
    end)
    assert_true(
      vim.wait(200, function()
        return #errors == 1
      end),
      "request should time out"
    )
    assert_true(errors[1].message:find("initialize timed out", 1, true) ~= nil)
    assert_equal(client.pending[id], nil, "timed-out request should be removed")
    client:_dispatch_message({ id = id, result = {} })
    assert_equal(#errors, 1, "late response should not call the callback again")

    local prompt_calls = 0
    local prompt_error
    local prompt_id = client:request("session/prompt", {}, function(err)
      prompt_calls = prompt_calls + 1
      prompt_error = err
    end)
    vim.wait(25)
    assert_equal(prompt_calls, 0, "prompt should use its longer timeout")
    client:_dispatch_message({ id = prompt_id, result = {} })
    vim.wait(50)
    assert_equal(prompt_calls, 1, "successful prompt response should call once")
    assert_equal(prompt_error, nil, "successful response should have no error")
    client:close()
  end)

  it("pauses prompt timeout while a permission request awaits a response", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({
      client = { prompt_timeout_ms = 40 },
    })
    local prompt_calls = 0
    local permission_reply
    client.running = true
    client.jobid = 1
    client._send_raw = function() end
    client:on_request(function(_, reply)
      permission_reply = reply
    end)

    local prompt_id = client:request("session/prompt", {}, function()
      prompt_calls = prompt_calls + 1
    end)
    vim.wait(15)
    client:_dispatch_message({
      id = "permission-1",
      method = "session/request_permission",
      params = {},
    })
    assert_true(
      vim.wait(100, function()
        return permission_reply ~= nil
      end),
      "permission request should reach its handler"
    )
    vim.wait(60)
    assert_equal(prompt_calls, 0, "approval wait time should not consume the prompt timeout")

    permission_reply({ outcome = { outcome = "cancelled" } })
    client:_dispatch_message({ id = prompt_id, result = {} })
    vim.wait(50)
    assert_equal(prompt_calls, 1, "prompt should complete normally after the permission response")
    client:close()
  end)

  it("fails pending requests when the agent exits", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({ client = { request_timeout_ms = 1000 } })
    local errors = {}
    client.running = true
    client._send_raw = function() end
    client:request("initialize", {}, function(err)
      table.insert(errors, err)
    end)

    client:_fail_pending("ACP agent exited before responding")
    assert_true(
      vim.wait(200, function()
        return #errors == 1
      end),
      "exit should fail pending requests"
    )
    assert_equal(errors[1].message, "ACP agent exited before responding")
    assert_equal(next(client.pending), nil, "exit should clear pending requests")
  end)

  it("stdio transport keeps large debug chunks as summaries", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({ debug = true })
    local notifications = {}
    client:on_notification(function(message)
      table.insert(notifications, message)
    end)

    client:_debug("stdout_chunk", { lines = { string.rep("x", 10000), "tail" } })

    local entry = client:get_debug_log()[1]
    assert_equal(entry.payload.line_count, 2, "debug summary should retain the line count")
    assert_equal(entry.payload.bytes, 10004, "debug summary should retain the byte count")
    assert_equal(#notifications, 0, "debug bookkeeping should not emit protocol notifications")
  end)

  it("selection references preserve source range and unsaved text", function()
    package.loaded["omniac.editor.selection"] = nil
    local selection = require("omniac.editor.selection")
    local buf = vim.api.nvim_create_buf(false, false)
    local path = "/private/tmp/omniac-reference-" .. tostring(vim.loop.hrtime()) .. ".lua"

    vim.api.nvim_buf_set_name(buf, path)
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local first = true",
      "local second = true",
      "return second",
    })
    vim.bo[buf].modified = true

    local reference = selection.reference_from_range(buf, 2, 3)

    assert_equal(reference.type, "reference", "selection should become a reference attachment")
    assert_equal(reference.path, path, "reference should preserve the source path")
    assert_equal(reference.filetype, "lua", "reference should preserve the source filetype")
    assert_equal(reference.startLine, 2, "reference should preserve the first selected line")
    assert_equal(reference.endLine, 3, "reference should preserve the last selected line")
    assert_equal(reference.text, "local second = true\nreturn second", "reference should capture buffer text")
    assert_equal(reference.modified, true, "reference should record unsaved buffer state")
    assert_true(reference.uri:match("#L2%-L3$") ~= nil, "reference URI should identify its line range")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("current-buffer references omit unsaved contents unless explicitly enabled", function()
    cleanup_omniac_buffers()
    pcall(vim.api.nvim_del_user_command, "OmniacReferenceBuffer")
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil

    local omniac = require("omniac")
    omniac.setup({ agent = { cmd = { "custom-acp" } }, keymaps = false })
    omniac.open_chat = function() end

    local ui = require("omniac.ui")
    local original_attach = ui.attach_reference
    local attached = {}
    ui.attach_reference = function(reference)
      table.insert(attached, reference)
    end

    local path = "/private/tmp/omniac-buffer-reference-" .. tostring(vim.loop.hrtime()) .. ".lua"
    assert_equal(vim.fn.writefile({ "on disk" }, path), 0, "test fixture should be written")
    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved", "buffer content" })
    vim.bo[bufnr].modified = true
    vim.api.nvim_set_current_buf(bufnr)

    local ok, err = pcall(vim.cmd, "OmniacReferenceBuffer")
    if ok then
      omniac.config.references.include_modified_buffer = true
      ok, err = pcall(vim.cmd, "OmniacReferenceBuffer")
    end
    ui.attach_reference = original_attach
    vim.fn.delete(path)

    assert_true(ok, tostring(err))
    assert_equal(#attached, 2, "both reference policies should attach the current file")
    assert_equal(attached[1].pathOnly, true, "default policy should link the on-disk file")
    assert_equal(attached[1].text, "unsaved\nbuffer content", "the captured buffer remains available locally")
    assert_equal(attached[2].pathOnly, false, "opt-in policy should embed the modified buffer")
    assert_equal(attached[2].text, "unsaved\nbuffer content", "opt-in should include the full buffer contents")

    omniac.config.references.include_modified_buffer = false
    local unnamed_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(unnamed_buf, 0, -1, false, { "unpersisted content" })
    vim.bo[unnamed_buf].modified = true
    vim.api.nvim_set_current_buf(unnamed_buf)
    assert_true(pcall(vim.cmd, "OmniacReferenceBuffer"), "referencing an unnamed buffer should be safe")
    assert_equal(#attached, 2, "unpersisted buffer contents should not be attached by default")

    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.api.nvim_buf_delete(unnamed_buf, { force = true })
  end)
end)
