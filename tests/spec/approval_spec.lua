local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim approval", function()
  after_each(helpers.cleanup_after_test)

  it("reviews raw-input replacements before any tool notification and leaves disk unchanged", function()
    local approval = require("omniac.approval").new()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "prefix", "before", "suffix" }, path)
    local review = require("omniac.changes.review")
    local original = review.open_review
    local captured, result, accept
    review.open_review = function(target, before, after, _, callback)
      captured = { path = target, before = before, after = after }
      accept = callback
    end
    local ok, err = pcall(function()
      approval:review_acp_permission({
        toolCall = {
          kind = "edit",
          toolCallId = "raw-replacement",
          rawInput = { file_path = path, old_string = "before", new_string = "after" },
        },
        options = { { optionId = "allow", kind = "allow_once" }, { optionId = "deny", kind = "reject_once" } },
      }, function(reply)
        result = reply
      end, {})
      assert_true(captured ~= nil)
      assert_equal(captured.path, vim.fs.normalize(path))
      assert_equal(table.concat(captured.after, "\n"), "prefix\nafter\nsuffix\n")
      accept(true, captured.after, false)
      assert_equal(result.outcome.optionId, "allow")
      assert_equal(table.concat(vim.fn.readfile(path), "\n"), "prefix\nbefore\nsuffix")
    end)
    review.open_review = original
    approval:close()
    vim.fn.delete(path)
    if not ok then
      error(err)
    end
  end)

  it("permission request shows JSON-RPC details in chat and selector", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.approval"] = nil
    package.loaded["omniac.ui.choice_dialog"] = nil
    local ui = require("omniac.ui")
    local approval = require("omniac.approval")
    local dialog_text

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/response_chunk", params = { text = "before " } },
      { ui = { chat_width = 48 } }
    )

    local replied
    approval.review_acp_permission({
      sessionId = "019ebc08-548b-7033-bb21-96097389145c",
      toolCall = {
        kind = "execute",
        status = "pending",
        toolCallId = "call_NoA8PXYCbZ2V0zw4BmoF62T3",
        locations = {
          { path = "lua/omniac/clipboard.lua" },
          { path = "lua/omniac/backend/acp.lua" },
        },
        rawInput = {
          command = "stylua lua/omniac/clipboard.lua lua/omniac/backend/acp.lua lua/omniac/init.lua lua/omniac/ui.lua tests/headless.lua",
          cwd = "/Users/nolleh/Documents/workspace_github/omniac.nvim",
          summary = "Format changed Lua files",
          reason = "Prepare the files for commit",
        },
        content = {
          {
            type = "content",
            content = {
              type = "text",
              text = "커밋 전에 변경된 Lua 파일 포맷을 확인/적용하도록 허용할까요?",
            },
          },
        },
      },
      options = {
        { optionId = "allow_once", name = "Allow Once" },
        { optionId = "allow_always", name = "Allow for Session" },
        { optionId = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, { ui = { chat_width = 48 } })

    vim.wait(50, function()
      return vim.fn.bufnr("omniac://permission") ~= -1
    end)
    local dialog_buf = vim.fn.bufnr("omniac://permission")
    local body_lines = vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false)
    dialog_text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    assert_true(table.concat(body_lines, "\n"):match("cwd:") ~= nil, "permission body should include cwd")
    local chat_buf = vim.fn.bufnr("omniac")
    local namespace = vim.api.nvim_get_namespaces()["omniac.ui"]
    local function permission_badge()
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat_buf, namespace, 0, -1, { details = true })) do
        local chunks = mark[4].virt_text
        if chunks and chunks[1] and mark[4].virt_text_pos == "right_align" then
          assert_equal(chunks[2][1], "  ", "permission badge should have right padding")
          return chunks[1][1], chunks[1][2]
        end
      end
    end
    assert_equal(permission_badge(), "● Pending", "permission request should have a pending badge")
    feed("1")
    vim.wait(50, function()
      return replied ~= nil
    end)

    ui.handle_notification(
      { method = "omniac/response_chunk", params = { text = "after" } },
      { ui = { chat_width = 48 } }
    )
    ui.handle_notification({ method = "omniac/response_completed", params = {} }, { ui = { chat_width = 48 } })

    assert_equal(permission_badge(), "✓ Approved", "accepted permission should update the badge")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local before_index = chat:find("before", 1, true)
    local permission_index = chat:find("Permission requested", 1, true)
    local after_index = chat:find("after", 1, true)
    assert_true(before_index ~= nil, "chat should include response before permission request")
    assert_true(permission_index ~= nil, "permission request should be inserted into chat")
    assert_true(after_index ~= nil, "chat should include response after permission request")
    assert_true(before_index < permission_index, "permission request should follow prior response text")
    assert_true(permission_index < after_index, "later response text should follow permission request")
    assert_true(chat:match("Permission requested") ~= nil, "permission request should be inserted into chat")
    assert_true(chat:match("```sh") ~= nil, "permission command should be rendered as shell code")
    assert_true(chat:match("stylua lua/omniac/clipboard.lua") ~= nil, "permission chat should show the command")
    assert_true(chat:match("커밋 전에 변경된 Lua 파일") ~= nil, "permission chat should show content text")
    assert_true(chat:match("Decision: Allow Once") ~= nil, "permission chat should show selected decision")
    assert_true(
      chat:find("Summary: Format changed Lua files", 1, true) ~= nil,
      "permission result should retain summary"
    )
    assert_true(
      chat:find("Reason: Prepare the files for commit", 1, true) ~= nil,
      "permission result should retain reason"
    )
    assert_true(chat:match("cwd:") ~= nil, "permission chat should show cwd")
    assert_true(chat:find("Files:", 1, true) ~= nil, "permission chat should list affected files")
    assert_true(chat:find("lua/omniac/backend/acp.lua", 1, true) ~= nil, "permission chat should show ACP locations")
    assert_true(chat:match("Options:") == nil, "permission chat should leave options to the selector")
    assert_true(chat:match("Details:") == nil, "permission chat should not expose protocol-ish detail labels")
    assert_true(dialog_text:match("Permission requested: execute") ~= nil, "selector prompt should still be shown")
    assert_true(
      dialog_text:match("stylua lua/omniac/clipboard.lua") ~= nil,
      "selector should show the command to approve"
    )
    assert_true(
      dialog_text:match("커밋 전에 변경된 Lua 파일 포맷을 확인/적용하도록 허용할까요%?") ~= nil,
      "selector should show the request text"
    )
    assert_true(dialog_text:match("cwd:") ~= nil, "selector should show the working directory")
    assert_true(dialog_text:find("lua/omniac/backend/acp.lua", 1, true) ~= nil, "selector should show affected files")
    assert_true(dialog_text:find("Summary: Format changed Lua files", 1, true) ~= nil, "selector should show summary")
    assert_true(dialog_text:find("Reason: Prepare the files for commit", 1, true) ~= nil, "selector should show reason")
    assert_equal(replied.outcome.optionId, "allow_once", "permission reply should select the chosen option")

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Permission requested") == nil, "permission activity should clear after decision")
  end)

  it("permission selector leaves insert mode and stays read-only", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui.choice_dialog"] = nil
    local dialog = require("omniac.ui.choice_dialog")

    vim.cmd("startinsert")
    vim.wait(50, function()
      return vim.fn.mode():match("^i") ~= nil
    end)

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, { prompt = "Permission requested: execute" }, function(_) end)

    vim.wait(50, function()
      return not vim.fn.mode():match("^i")
    end)

    local dialog_buf = vim.fn.bufnr("omniac://permission")
    assert_true(dialog_buf ~= -1, "permission selector should open")
    assert_equal(vim.bo[dialog_buf].modifiable, false, "permission selector should not be modifiable")
    assert_equal(vim.bo[dialog_buf].readonly, true, "permission selector should be read-only")
    assert_true(not vim.fn.mode():match("^i"), "permission selector should not stay in insert mode")

    dialog.dismiss()
  end)

  it("permission selector has a bordered action area below the request", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui.choice_dialog"] = nil
    local dialog = require("omniac.ui.choice_dialog")

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, { prompt = "Permission requested: execute" }, function(_) end)

    local body_buf = vim.fn.bufnr("omniac://permission")
    local selector_buf = vim.fn.bufnr("omniac://permission-selector")
    local body_win = vim.fn.win_findbuf(body_buf)[1]
    local selector_win = vim.fn.win_findbuf(selector_buf)[1]
    local body_config = vim.api.nvim_win_get_config(body_win)
    local selector_config = vim.api.nvim_win_get_config(selector_win)
    local selector_lines = vim.api.nvim_buf_get_lines(selector_buf, 0, -1, false)
    local selected_hl = vim.api.nvim_get_hl(0, { name = "OmniacPermissionSelected" })

    assert_true(body_config.border ~= nil, "permission body should keep its outline")
    assert_equal(body_config.title_pos, "left", "permission title should use native left alignment")
    assert_true(
      selector_config.border ~= nil and selector_config.border ~= "none",
      "permission actions should have an outline"
    )
    assert_equal(selector_config.col, body_config.col, "permission actions should align with the card")
    assert_equal(
      selector_config.row,
      body_config.row + body_config.height + 2,
      "permission actions should sit below the request card"
    )
    assert_true(selector_lines[1]:match("^› 1  Allow Once") ~= nil, "selected permission action should use a cursor")
    assert_equal(selected_hl.fg, tonumber("11111b", 16), "selected permission action should use the session foreground")
    assert_equal(selected_hl.bg, tonumber("94e2d5", 16), "selected permission action should use the session background")
    assert_equal(selected_hl.bold, true, "selected permission action should match the bold session selection")

    dialog.dismiss()
  end)

  it("permission body wraps long commands and preserves source newlines", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui.choice_dialog"] = nil
    local dialog = require("omniac.ui.choice_dialog")
    local command = "python3 -c '" .. string.rep("print(1234567890);", 30) .. "'"

    dialog.open({ { optionId = "allow_once", name = "Allow Once" } }, {
      prompt = "Permission requested: execute",
      body = "Command:\n```sh\n" .. command .. "\nsecond line\n```",
    }, function(_) end)

    local body_buf = vim.fn.bufnr("omniac://permission")
    local body_win = vim.fn.win_findbuf(body_buf)[1]
    local lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
    assert_equal(lines[5], command, "the full command should remain in the buffer")
    assert_equal(lines[6], "second line", "source newlines should stay separate")
    assert_equal(vim.wo[body_win].wrap, true, "long command lines should wrap visually")
    assert_true(vim.api.nvim_win_get_width(body_win) >= 50, "request card should leave space for command text")
    feed("<C-d>")
    assert_equal(vim.fn.bufnr("omniac://permission"), body_buf, "scrolling details should keep the dialog open")

    dialog.dismiss()
  end)

  it("permission dialog uses markdown rendering for the body", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui.choice_dialog"] = nil
    package.loaded["render-markdown"] = nil

    local render_calls = {}
    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function(ctx)
          table.insert(render_calls, ctx)
        end,
      }
    end

    local dialog = require("omniac.ui.choice_dialog")

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, {
      prompt = "Permission requested: execute",
      body = table.concat({
        "Title: Markdown body",
        "",
        "```sh",
        "printf ok",
        "```",
        "",
        "| A | B |",
        "| - | - |",
        "| 1 | 2 |",
      }, "\n"),
    }, function(_) end)

    local dialog_buf = vim.fn.bufnr("omniac://permission")
    assert_true(dialog_buf ~= -1, "permission dialog should open")
    assert_equal(vim.bo[dialog_buf].filetype, "omniac-permission", "permission dialogs should have their own filetype")
    assert_equal(vim.treesitter.language.get_lang("omniac-permission"), "markdown")
    assert_true(#render_calls > 0, "permission dialog should call render-markdown")
    assert_equal(render_calls[#render_calls].buf, dialog_buf, "render-markdown should receive the permission buffer")
    assert_equal(
      render_calls[#render_calls].event,
      "OmniacPermissionRender",
      "render-markdown should receive a permission render event"
    )

    vim.wait(50)
    local settled_calls = #render_calls

    feed("j")
    vim.wait(50)
    assert_equal(#render_calls, settled_calls, "moving the permission selection should not rerender the markdown body")

    local dialog_text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    assert_true(dialog_text:match("```sh") ~= nil, "permission body should keep markdown source")
    assert_true(dialog_text:match("| A | B |") ~= nil, "permission body should keep table markdown source")

    dialog.dismiss()
    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("edit permission without diff falls back to selector", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.approval"] = nil
    package.loaded["omniac.ui.choice_dialog"] = nil
    local ui = require("omniac.ui")
    local approval = require("omniac.approval")
    local dialog_text

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    local replied
    approval.review_acp_permission({
      sessionId = "sess_1",
      toolCall = {
        kind = "edit",
        status = "pending",
        toolCallId = "call_edit_without_diff",
        content = vim.NIL,
      },
      options = {
        { optionId = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, { ui = { chat_width = 48 } })

    vim.wait(1200, function()
      return vim.fn.bufnr("omniac://permission") ~= -1
    end)
    local dialog_buf = vim.fn.bufnr("omniac://permission")
    dialog_text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    feed("1")

    vim.wait(50, function()
      return replied ~= nil
    end)

    local chat_buf = vim.fn.bufnr("omniac")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(dialog_text:match("Permission requested: edit") ~= nil, "edit fallback selector should stay compact")
    assert_true(chat:match("Decision: Allow Once") ~= nil, "edit fallback should record the selected decision")
    assert_equal(replied.outcome.optionId, "allow_once", "edit fallback should reply with selected option")
  end)

  it("closing approval state cancels its pending permission", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    package.loaded["omniac.ui.choice_dialog"] = nil
    local approval = require("omniac.approval").new()
    local replied

    approval:review_acp_permission({
      sessionId = "closing_session",
      toolCall = {
        kind = "edit",
        toolCallId = "closing_permission",
        content = vim.NIL,
      },
      options = {
        { optionId = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, {})

    approval:close()
    vim.wait(1100)

    assert_equal(replied, nil, "closed approval state should not reply from a stale timer")
    assert_equal(vim.fn.bufnr("omniac://permission"), -1, "closed approval state should not open a stale selector")
  end)

  it("late edit permission diff replaces fallback selector", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.approval"] = nil
    package.loaded["omniac.ui.choice_dialog"] = nil
    local ui = require("omniac.ui")
    local approval = require("omniac.approval")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    local replied
    approval.review_acp_permission({
      sessionId = "sess_1",
      toolCall = {
        kind = "edit",
        status = "pending",
        toolCallId = "call_late_diff",
        content = vim.NIL,
      },
      options = {
        { optionId = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, { ui = { chat_width = 48 } })

    vim.wait(1200, function()
      return vim.fn.bufnr("omniac://permission") ~= -1
    end)
    assert_true(vim.fn.bufnr("omniac://permission") ~= -1, "fallback selector should open while waiting for diff")

    local opened = approval.attach_acp_permission_diff({
      toolCallId = "call_late_diff",
      path = "/tmp/omniac-late-new-file.md",
      oldText = vim.NIL,
      newText = "# Late\n",
    })

    assert_true(opened, "late permission diff should open a review")
    local chat = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("omniac"), 0, -1, false), "\n")
    assert_true(chat:find("/tmp/omniac-late-new-file.md", 1, true) ~= nil, "late diff path should appear in chat")
    assert_equal(vim.fn.bufnr("omniac://permission"), -1, "late diff should close fallback selector")
    local current = vim.api.nvim_get_current_buf()
    local current_name = vim.api.nvim_buf_get_name(current)
    assert_true(
      current_name:match("Omniac permission: /tmp/omniac%-late%-new%-file%.md") ~= nil,
      "diff review should show the file path"
    )
    assert_equal(
      vim.api.nvim_buf_get_lines(current, 0, -1, false)[1],
      "# Late",
      "diff review should show proposed content"
    )

    vim.cmd("w")
    assert_true(replied ~= nil, "accepting late diff should reply")
    assert_equal(replied.outcome.optionId, "allow_once", "accepted late diff should use the allow option")
  end)

  it("reviews every file before approving one edit permission", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    local approval = require("omniac.approval")
    local replied
    approval.review_acp_permission({
      sessionId = "sess_multi",
      toolCall = {
        kind = "edit",
        toolCallId = "call_multi",
        content = {
          { type = "diff", path = "/tmp/omniac-multi-a.txt", oldText = "a", newText = "A" },
          { type = "diff", path = "/tmp/omniac-multi-b.txt", oldText = "b", newText = "B" },
        },
      },
      options = { { optionId = "allow_once", kind = "allow_once" } },
    }, function(result)
      replied = result
    end, {})

    assert_true(vim.api.nvim_buf_get_name(0):find("omniac-multi-a", 1, true) ~= nil)
    vim.cmd("w")
    assert_equal(replied, nil, "first file should not approve the whole request")
    assert_true(
      vim.wait(200, function()
        return vim.api.nvim_buf_get_name(0):find("omniac-multi-b", 1, true) ~= nil
      end),
      "second file should open after the first closes"
    )
    vim.cmd("w")
    assert_equal(replied.outcome.optionId, "allow_once", "all files should approve one request")
  end)

  it("rejects the whole edit permission when one file is denied", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    local approval = require("omniac.approval")
    local replied
    approval.review_acp_permission({
      sessionId = "sess_multi",
      toolCall = {
        kind = "edit",
        toolCallId = "call_multi_denied",
        content = {
          { type = "diff", path = "/tmp/omniac-denied-a.txt", oldText = "a", newText = "A" },
          { type = "diff", path = "/tmp/omniac-denied-b.txt", oldText = "b", newText = "B" },
        },
      },
      options = { { optionId = "allow_once", kind = "allow_once" } },
    }, function(result)
      replied = result
    end, {})

    vim.cmd("q")
    assert_true(
      vim.wait(1000, function()
        return replied ~= nil
      end),
      "denial should reply after the diff window closes"
    )
    assert_equal(replied.outcome.outcome, "cancelled", "denial should reject the entire request")
    vim.wait(30)
    assert_true(vim.api.nvim_buf_get_name(0):find("omniac-denied-b", 1, true) == nil)
  end)

  it("forwards all reviewed files when one proposed diff is adjusted", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    local approval = require("omniac.approval")
    local replied
    local adjusted
    approval.review_acp_permission({
      sessionId = "sess_multi",
      toolCall = {
        kind = "edit",
        toolCallId = "call_multi_adjusted",
        content = {
          { type = "diff", path = "/tmp/omniac-adjusted-a.txt", oldText = "a", newText = "A" },
          { type = "diff", path = "/tmp/omniac-adjusted-b.txt", oldText = "b", newText = "B" },
        },
      },
      options = {
        { optionId = "allow_once", kind = "allow_once" },
        { optionId = "reject_once", kind = "reject_once" },
      },
    }, function(result)
      replied = result
    end, {}, function(items)
      adjusted = items
      return true
    end)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Adjusted A" })
    vim.cmd("w")
    assert_true(vim.wait(200, function()
      return vim.api.nvim_buf_get_name(0):find("omniac-adjusted-b", 1, true) ~= nil
    end))
    vim.cmd("w")
    assert_equal(replied.outcome.optionId, "reject_once", "the original batch should be rejected")
    assert_equal(#adjusted, 2, "follow-up should include both files")
    assert_equal(adjusted[1].adjustedText, "Adjusted A")
    assert_equal(adjusted[2].adjustedText, "B")
  end)

  it("edited diff approval rejects the original edit and captures adjusted text", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    local approval = require("omniac.approval")
    local replied
    local adjusted

    approval.review_acp_permission({
      sessionId = "sess_adjusted",
      toolCall = {
        kind = "edit",
        toolCallId = "call_adjusted",
        content = { { type = "diff", path = "/tmp/omniac-adjusted.txt", oldText = "old", newText = "proposed" } },
      },
      options = {
        { optionId = "allow_once", kind = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", kind = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, {}, function(item)
      adjusted = item
      return true
    end)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "user edit" })
    vim.cmd("w")

    assert_equal(replied.outcome.optionId, "reject_once", "adjusted approval should reject original proposal")
    assert_equal(adjusted.path, "/tmp/omniac-adjusted.txt", "adjustment should retain target path")
    assert_equal(adjusted.proposedText, "proposed", "adjustment should retain original proposal")
    assert_equal(adjusted.adjustedText, "user edit", "adjustment should capture final buffer contents")
    assert_equal(vim.fn.filereadable(adjusted.path), 0, "approval should not write the target file")
  end)

  it("diff edit followed by undo still uses the adjusted approval flow", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    local approval = require("omniac.approval")
    local replied
    local adjusted

    approval.review_acp_permission({
      sessionId = "sess_undo",
      toolCall = {
        kind = "edit",
        toolCallId = "call_undo",
        content = { { type = "diff", path = "/tmp/omniac-undo.txt", oldText = "old", newText = "proposed" } },
      },
      options = {
        { optionId = "allow_once", kind = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", kind = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, {}, function(item)
      adjusted = item
      return true
    end)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "temporary" })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "proposed" })
    vim.cmd("w")

    assert_equal(replied.outcome.optionId, "reject_once", "any text edit should use the follow-up flow")
    assert_equal(adjusted.adjustedText, "proposed", "final text should be captured without comparing it")
  end)

  it("adjusted approval waits for turn completion before prompting", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    local original_message = ui.add_message
    ui.set_activity = function() end
    ui.add_message = function() end

    local prompts = {}
    local client = { session_id = "sess_followup", active_turn_id = 7 }
    client.prompt = function(self, text, _, callback)
      table.insert(prompts, text)
      self.active_turn_id = 8
      self.prompt_callback = callback
    end
    local followup = require("omniac.approval.followup").new(client, {}, function()
      return true
    end)
    assert_true(
      followup:queue({
        sessionId = "sess_followup",
        path = "/tmp/example.txt",
        proposedText = "proposed",
        adjustedText = "adjusted",
      }),
      "adjustment should queue during the active turn"
    )
    assert_true(
      followup:queue({
        sessionId = "sess_followup",
        path = "/tmp/second.txt",
        proposedText = "second proposal",
        adjustedText = "second adjustment",
      }),
      "another adjusted file should join the same turn"
    )
    assert_equal(#prompts, 0, "permission response must not start another prompt")

    followup:finish_turn({ sessionId = "sess_followup", turnId = 7, stopReason = "cancelled" })
    client.active_turn_id = nil
    vim.wait(100, function()
      return #prompts == 1
    end)
    assert_equal(#prompts, 1, "follow-up should start after a rejected edit ends the turn as cancelled")
    assert_true(prompts[1]:match("adjusted") ~= nil, "follow-up should carry adjusted content")
    assert_true(prompts[1]:match("second adjustment") ~= nil, "follow-up should carry every adjusted file")
    client.active_turn_id = nil
    client.prompt_callback(nil, {})

    ui.set_activity = original_activity
    ui.add_message = original_message
  end)

  it("auto-approves only the matching adjusted edit in its follow-up turn", function()
    cleanup_omniac_buffers()
    local path = "/private/tmp/omniac-followup-" .. tostring(vim.loop.hrtime()) .. ".txt"
    vim.fn.writefile({ "original" }, path)
    local client = { session_id = "sess_match", active_turn_id = 10 }
    client.prompt = function(self, _, _, callback)
      self.active_turn_id = 11
      self.prompt_callback = callback
    end
    local followup = require("omniac.approval.followup").new(client, {}, function()
      return true
    end)
    followup:queue({
      sessionId = "sess_match",
      path = path,
      proposedText = "proposal",
      adjustedText = "user edit\n",
    })
    followup:finish_turn({ sessionId = "sess_match", turnId = 10, stopReason = "cancelled" })
    client.active_turn_id = nil
    vim.wait(100, function()
      return client.active_turn_id == 11
    end)

    local approval = require("omniac.approval")
    local function request(new_text, old_text)
      return {
        sessionId = "sess_match",
        toolCall = {
          kind = "edit",
          toolCallId = "match-" .. tostring(vim.loop.hrtime()),
          content = { { type = "diff", path = path, oldText = old_text, newText = new_text } },
        },
        options = {
          { optionId = "allow_once", kind = "allow_once", name = "Allow Once" },
          { optionId = "cancel", kind = "reject_once", name = "Reject" },
        },
      }
    end
    local function review(params)
      local response
      approval.review_acp_permission(
        params,
        function(result)
          response = result
        end,
        {},
        nil,
        function(permission, payload)
          return followup:matches_followup(permission, payload)
        end
      )
      return response
    end

    local matched = review(request("user edit\n", "original\n"))
    assert_equal(matched.outcome.optionId, "allow_once", "exact adjusted text should be accepted without a diff")
    assert_equal(vim.fn.bufnr("Omniac permission: " .. path), -1, "automatic approval should not open a diff")

    local repeated = review(request("user edit\n", "original\n"))
    assert_equal(repeated, nil, "matching approval should be consumed after one use")
    vim.cmd("q")

    local changed = review(request("other edit\n", "original\n"))
    assert_equal(changed, nil, "different proposed content should require review")
    vim.cmd("q")

    vim.fn.writefile({ "changed elsewhere" }, path)
    local stale = review(request("user edit\n", "original\n"))
    assert_equal(stale, nil, "changed current content should require review")
    vim.cmd("q")

    client.active_turn_id = nil
    client.prompt_callback(nil, {})
    vim.fn.delete(path)
  end)

  it("matches a follow-up edit batch atomically", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    ui.set_activity = function() end
    local first = "/private/tmp/omniac-batch-first-" .. tostring(vim.loop.hrtime()) .. ".txt"
    local second = "/private/tmp/omniac-batch-second-" .. tostring(vim.loop.hrtime()) .. ".txt"
    vim.fn.writefile({ "first=old" }, first)
    vim.fn.writefile({ "second=old" }, second)

    local client = { session_id = "sess_batch", active_turn_id = 20 }
    client.prompt = function(self, _, _, callback)
      self.active_turn_id = 21
      self.prompt_callback = callback
    end
    local followup = require("omniac.approval.followup").new(client, {}, function()
      return true
    end)
    followup:queue({
      { sessionId = "sess_batch", path = first, proposedText = "first=proposed\n", adjustedText = "first=reviewed\n" },
      {
        sessionId = "sess_batch",
        path = second,
        proposedText = "second=proposed\n",
        adjustedText = "second=proposed\n",
      },
    })
    followup:finish_turn({ sessionId = "sess_batch", turnId = 20 })
    client.active_turn_id = nil
    assert_true(vim.wait(100, function()
      return client.active_turn_id == 21
    end))

    local request = { sessionId = "sess_batch" }
    local batch = {
      { path = first, oldText = "first=old\n", newText = "first=reviewed\n" },
      { path = second, oldText = "second=old\n", newText = "second=wrong\n" },
    }
    assert_equal(followup:matches_followup(request, batch), false, "one mismatched file must reject the whole batch")
    batch[2].newText = "second=proposed\n"
    assert_equal(followup:matches_followup(request, batch), true, "a fully matching batch should be accepted")
    assert_equal(followup:matches_followup(request, batch), false, "accepted edits should be consumed once")

    followup:close()
    vim.fn.delete(first)
    vim.fn.delete(second)
    ui.set_activity = original_activity
  end)

  it("adjusted approval queue is discarded when its connection closes", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    ui.set_activity = function() end

    local prompt_count = 0
    local client = { session_id = "sess_closed", active_turn_id = 3 }
    client.prompt = function()
      prompt_count = prompt_count + 1
    end
    local followup = require("omniac.approval.followup").new(client, {}, function()
      return true
    end)
    assert_true(
      followup:queue({
        sessionId = "sess_closed",
        path = "/tmp/example.txt",
        proposedText = "before",
        adjustedText = "after",
      }),
      "adjustment should queue before disconnect"
    )
    followup:finish_turn({ sessionId = "sess_closed", turnId = 3 })
    followup:close()
    client.active_turn_id = nil
    vim.wait(50)
    assert_equal(prompt_count, 0, "closed connection must not send a queued follow-up")

    ui.set_activity = original_activity
  end)

  it("adjusted approval reports a failed follow-up", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    local original_message = ui.add_message
    local messages = {}
    ui.set_activity = function() end
    ui.add_message = function(_, message)
      table.insert(messages, message)
    end

    local client = { session_id = "sess_error", active_turn_id = 4 }
    client.prompt = function(self, _, _, callback)
      self.active_turn_id = 5
      self.prompt_callback = callback
    end
    local followup = require("omniac.approval.followup").new(client, {}, function()
      return true
    end)
    followup:queue({
      sessionId = "sess_error",
      path = "/tmp/example.txt",
      proposedText = "before",
      adjustedText = "after",
    })
    followup:finish_turn({ sessionId = "sess_error", turnId = 4 })
    client.active_turn_id = nil
    vim.wait(100, function()
      return client.prompt_callback ~= nil
    end)
    client.active_turn_id = nil
    client.prompt_callback(nil, { stopReason = "error" })
    assert_true(messages[1]:match("follow%-up ended") ~= nil, "failed follow-up should be visible")

    ui.set_activity = original_activity
    ui.add_message = original_message
  end)

  it("continues a follow-up after another adjusted approval", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    local original_message = ui.add_message
    local messages = {}
    ui.set_activity = function() end
    ui.add_message = function(kind, message)
      table.insert(messages, { kind = kind, message = message })
    end

    local client = { session_id = "sess_nested", active_turn_id = 30 }
    local callbacks = {}
    local next_turn = 31
    client.prompt = function(self, _, _, callback)
      self.active_turn_id = next_turn
      next_turn = next_turn + 1
      table.insert(callbacks, callback)
    end
    local followup = require("omniac.approval.followup").new(client, {}, function()
      return true
    end)
    local function adjusted(path)
      return { sessionId = "sess_nested", path = path, proposedText = "before", adjustedText = "after" }
    end

    assert_true(followup:queue(adjusted("/tmp/first.txt")))
    followup:finish_turn({ sessionId = "sess_nested", turnId = 30 })
    client.active_turn_id = nil
    assert_true(vim.wait(100, function()
      return #callbacks == 1
    end))

    assert_true(followup:queue(adjusted("/tmp/second.txt")))
    followup:finish_turn({ sessionId = "sess_nested", turnId = 31 })
    client.active_turn_id = nil
    callbacks[1](nil, { stopReason = "cancelled" })
    assert_equal(#messages, 0, "another adjusted approval should not report an error")
    assert_true(
      vim.wait(100, function()
        return #callbacks == 2
      end),
      "next reviewed edit should start automatically"
    )

    followup:close()
    ui.set_activity = original_activity
    ui.add_message = original_message
  end)

  it("reports reviewed files as applied when a follow-up ends cancelled", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    local original_message = ui.add_message
    local messages = {}
    ui.set_activity = function() end
    ui.add_message = function(kind, message)
      table.insert(messages, { kind = kind, message = message })
    end

    local path = "/private/tmp/omniac-adjusted-result-" .. tostring(vim.loop.hrtime()) .. ".txt"
    local client = { session_id = "sess_result", active_turn_id = 12 }
    client.prompt = function(self, _, _, callback)
      self.active_turn_id = 13
      self.prompt_callback = callback
    end
    local followup = require("omniac.approval.followup").new(client, {}, function()
      return true
    end)
    followup:queue({
      sessionId = "sess_result",
      path = path,
      proposedText = "proposal",
      adjustedText = "reviewed\n",
    })
    followup:finish_turn({ sessionId = "sess_result", turnId = 12 })
    client.active_turn_id = nil
    vim.wait(100, function()
      return client.prompt_callback ~= nil
    end)
    vim.fn.writefile({ "reviewed" }, path)
    client.active_turn_id = nil
    client.prompt_callback(nil, { stopReason = "cancelled" })

    assert_equal(messages[1].kind, "Notice", "applied edit should not appear as an error")
    assert_true(messages[1].message:match("present in all 1 file") ~= nil)
    vim.fn.delete(path)
    ui.set_activity = original_activity
    ui.add_message = original_message
  end)

  it("permission dialog ignores escape without cancelling", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui.choice_dialog"] = nil
    local dialog = require("omniac.ui.choice_dialog")
    local choice = "unset"

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, {
      prompt = "Permission requested: execute",
    }, function(selected)
      choice = selected
    end)

    feed("<Esc><Esc>")
    vim.wait(50)

    assert_equal(choice, "unset", "escape should not choose or cancel permission")
    assert_true(vim.fn.bufnr("omniac://permission") ~= -1, "permission dialog should remain open after escape")

    feed("q")
    vim.wait(50, function()
      return choice ~= "unset"
    end)
    assert_equal(choice.optionId, "reject_once", "q should explicitly reject permission")
  end)

  it("permission dialog replaces an existing dialog", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui.choice_dialog"] = nil
    local dialog = require("omniac.ui.choice_dialog")

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
    }, {
      prompt = "Permission requested: first",
    }, function() end)

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
    }, {
      prompt = "Permission requested: second",
    }, function() end)

    local dialog_buf = vim.fn.bufnr("omniac://permission")
    local text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    assert_true(text:match("second") ~= nil, "second permission dialog should replace the first")
    assert_true(text:match("first") == nil, "stale permission dialog content should be removed")

    feed("q")
  end)
end)
