local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true

describe("omniac.nvim acp files", function()
  after_each(helpers.cleanup_after_test)

  it("ACP edit diff emits permission diff for new files", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client:on_notification(function(message)
      if message.method == "omniac/permission_diff" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          title = "Editing files",
          toolCallId = "call_new_file",
          content = {
            {
              type = "diff",
              _meta = { kind = "update" },
              path = "/private/tmp/omniac-new-file.md",
              oldText = vim.NIL,
              newText = "# New\n",
            },
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "new file edits should emit permission_diff")
    assert_equal(notification.params.toolCallId, "call_new_file", "permission diff should keep the tool call id")
    assert_equal(notification.params.path, "/private/tmp/omniac-new-file.md", "permission diff should keep the path")
    assert_equal(notification.params.oldText, "", "new file oldText should be normalized to empty text")
    assert_equal(notification.params.newText, "# New\n", "permission diff should keep the proposed content")
  end)

  it("ACP edit add emits permission diff for created files", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client:on_notification(function(message)
      if message.method == "omniac/permission_diff" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          title = "Editing files",
          toolCallId = "call_added_file",
          content = {
            {
              type = "diff",
              _meta = { kind = "add" },
              path = "/private/tmp/omniac-added-file.md",
              oldText = vim.NIL,
              newText = "# Added\n",
            },
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "created file edits should emit permission_diff")
    assert_equal(notification.params.toolCallId, "call_added_file", "created file diff should keep tool call id")
    assert_equal(notification.params.path, "/private/tmp/omniac-added-file.md", "created file diff should keep path")
    assert_equal(notification.params.oldText, "", "created file oldText should be normalized to empty text")
    assert_equal(notification.params.newText, "# Added\n", "created file diff should keep new text")
  end)

  it("ACP completed edits keep the turn that started the tool call", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client.session_id = "sess_1"
    client.active_turn_id = 7
    client:on_notification(function(message)
      if message.method == "omniac/file_update" then
        notification = message
      end
    end)
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          toolCallId = "call_turn_7",
        },
      },
    })

    client.active_turn_id = 8
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call_update",
          kind = "edit",
          status = "completed",
          toolCallId = "call_turn_7",
          content = {
            {
              type = "diff",
              path = "/tmp/turn-7.lua",
              oldText = "old\n",
              newText = "new\n",
            },
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)
    assert_true(notification ~= nil, "completed edit should emit a file update")
    assert_equal(notification.params.sessionId, "sess_1", "file update should include its session")
    assert_equal(notification.params.turnId, 7, "file update should retain the originating turn")
  end)

  it("ACP completed edits retain earlier diffs when completion omits content", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification
    local path = "/private/tmp/omniac-edit-snapshot-" .. tostring(vim.loop.hrtime()) .. ".txt"
    vim.fn.writefile({ "before", "rest" }, path)

    client.session_id = "sess_1"
    client.active_turn_id = 3
    client:on_notification(function(message)
      if message.method == "omniac/file_update" then
        notification = message
      end
    end)
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          toolCallId = "call_snapshot",
          content = {
            {
              type = "diff",
              path = path,
              oldText = "before",
              newText = "after",
            },
          },
        },
      },
    })

    vim.fn.writefile({ "after", "rest" }, path)
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call_update",
          status = "completed",
          toolCallId = "call_snapshot",
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)
    pcall(vim.fn.delete, path)

    assert_true(notification ~= nil, "content-less completion should emit the cached file update")
    assert_equal(notification.params.turnId, 3, "cached file update should keep its originating turn")
    assert_equal(notification.params.oldText, "before\nrest\n", "file update should preserve the full baseline")
    assert_equal(notification.params.newText, "after\nrest\n", "file update should read the full completed file")
  end)

  it("ACP prompt rejects image content blocks without capability", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requested = false
    local received_err

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function()
        requested = true
      end,
    }

    client:prompt("look", {
      prompt = {
        { type = "text", text = "look" },
        { type = "image", mimeType = "image/png", data = "aW1n" },
      },
    }, function(err)
      received_err = err
    end)

    assert_equal(requested, false, "unsupported image prompt should not call transport")
    assert_true(received_err and received_err.message:match("image prompts"), "unsupported image prompt should error")
  end)

  it("ACP prompt rejects embedded references without capability", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requested = false
    local received_err

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function()
        requested = true
      end,
    }

    client:prompt("explain", {
      prompt = {
        { type = "text", text = "explain" },
        {
          type = "resource",
          resource = {
            uri = "file:///tmp/example.lua#L1-L2",
            mimeType = "text/plain",
            text = "local example = true",
          },
        },
      },
    }, function(err)
      received_err = err
    end)

    assert_equal(requested, false, "unsupported embedded context should not call transport")
    assert_true(received_err and received_err.message:match("embedded context"), "unsupported resource should error")
  end)

  it("ACP fs/read_text_file prefers unsaved buffer content", function()
    package.loaded["omniac.filesystem"] = nil
    local filesystem = require("omniac.filesystem")
    local path = "/private/tmp/omniac-fs-read-" .. tostring(vim.loop.now()) .. ".txt"
    vim.fn.writefile({ "disk" }, path)

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "buffer", "changed" })
    vim.bo[buf].modified = true

    local result, err = filesystem.handle_request("fs/read_text_file", {
      sessionId = "session",
      path = path,
      line = 2,
      limit = 1,
    })

    assert_equal(err, nil, "read_text_file should not return an error")
    assert_equal(result.content, "changed\n", "read_text_file should read from the loaded buffer")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("ACP fs/write_text_file writes disk and updates loaded buffer", function()
    package.loaded["omniac.filesystem"] = nil
    local filesystem = require("omniac.filesystem")
    local path = "/private/tmp/omniac-fs-write-" .. tostring(vim.loop.now()) .. ".txt"
    vim.fn.writefile({ "old" }, path)

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "old" })
    vim.bo[buf].modified = true

    local result, err = filesystem.handle_request("fs/write_text_file", {
      sessionId = "session",
      path = path,
      content = "new\nvalue\n",
    })

    assert_equal(err, nil, "write_text_file should not return an error")
    assert_equal(result, vim.NIL, "write_text_file should return JSON null")
    assert_equal(table.concat(vim.fn.readfile(path), "\n"), "new\nvalue", "file should be written to disk")
    assert_equal(
      table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
      "new\nvalue",
      "loaded buffer should be updated"
    )
    assert_equal(vim.bo[buf].modified, false, "loaded buffer should be marked unmodified after write")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)
