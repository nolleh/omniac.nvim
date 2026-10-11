local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim activity", function()
  after_each(helpers.cleanup_after_test)

  it("restores the previous activity after a short notice", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { agent = { cmd = { "codex-acp" } }, ui = { chat_width = 42 } }
    ui.open(config, function(_) end)
    local activity_buf = vim.fn.bufnr("omniac://activity")
    local function activity()
      return table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    end

    ui.set_status("working", config)
    ui.flash_activity("Plan mode enabled.", config, 30)
    assert_true(activity():find("Plan mode enabled.", 1, true) ~= nil, "notice should appear immediately")
    assert_true(
      vim.wait(200, function()
        return activity():find("Working", 1, true) ~= nil
      end),
      "working activity should return after the notice"
    )

    ui.flash_activity("Plan mode disabled.", config, 30)
    ui.set_activity("New activity", config)
    vim.wait(60)
    assert_true(activity():find("New activity", 1, true) ~= nil, "a newer activity should not be replaced")
  end)

  it("opens changes from non-input Omniac windows while the summary is visible", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local previous_lines = vim.o.lines
    vim.o.lines = 40
    local config = { agent = { cmd = { "codex-acp" } }, ui = { chat_width = 42, welcome_card = "pinned" } }
    local scopes = {}
    ui.set_change_review_handler(function(scope)
      table.insert(scopes, scope)
    end)
    local ui_state = ui.open(config, function(_) end)

    ui.set_activity("Changed 2 files this turn", config, { change_summary = true })
    vim.api.nvim_set_current_win(ui_state.chat_win)
    feed("t")
    vim.api.nvim_set_current_win(ui_state.status_win)
    feed("s")
    vim.api.nvim_set_current_win(ui_state.activity_win)
    feed("t")
    vim.api.nvim_set_current_win(ui_state.card_win)
    feed("s")
    assert_equal(scopes[1], "turn", "t should review the latest turn")
    assert_equal(scopes[2], "session", "s should review the session")
    assert_equal(scopes[3], "turn", "activity should keep its shortcut")
    assert_equal(scopes[4], "session", "card should support session changes")

    local function mapped(buf, key)
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if mapping.lhs == key then
          return true
        end
      end
      return false
    end
    assert_true(not mapped(ui_state.input_buf, "t"), "input should not map t")
    assert_true(not mapped(ui_state.input_buf, "s"), "input should not map s")

    ui.set_activity("Another activity", config)
    for _, buf in ipairs({ ui_state.chat_buf, ui_state.activity_buf, ui_state.status_buf, ui_state.card_buf }) do
      assert_true(not mapped(buf, "t"), "t should be unmapped when the summary is replaced")
      assert_true(not mapped(buf, "s"), "s should be unmapped when the summary is replaced")
    end
    vim.o.lines = previous_lines
  end)

  it("activity text keeps horizontal padding when truncated", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 42 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "completed",
        title = string.rep("very-long-command ", 10),
        exitCode = 0,
      },
    }, { ui = { chat_width = 42 } })

    local activity_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):match("omniac://activity") then
        activity_buf = buf
        break
      end
    end

    assert_true(activity_buf ~= nil, "activity buffer should exist")
    local line = vim.api.nvim_buf_get_lines(activity_buf, 0, 1, false)[1]
    assert_true(line:match("^  "), "activity line should keep left padding")
    assert_true(line:match("  $"), "activity line should keep right padding")
  end)

  it("multiline activity grows to three lines and shrinks again", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity_win = vim.fn.win_findbuf(activity_buf)[1]
    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win = vim.fn.win_findbuf(chat_buf)[1]
    local initial_chat_height = vim.api.nvim_win_get_height(chat_win)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 42 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "in_progress",
        title = table.concat({ "first command", "second command", "third command", "fourth command" }, "\n"),
      },
    }, { ui = { chat_width = 42 } })

    local expanded = vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false)
    assert_equal(#expanded, 3, "activity should show at most three lines")
    assert_equal(vim.api.nvim_win_get_height(activity_win), 3, "activity window should grow with multiline text")
    assert_true(expanded[1]:match("first command") ~= nil, "activity should keep the first command line")
    assert_true(expanded[2]:match("second command") ~= nil, "activity should keep the second command line")
    assert_true(expanded[3]:match("third command…") ~= nil, "activity should ellipsize hidden lines")
    assert_equal(
      vim.api.nvim_win_get_height(chat_win),
      initial_chat_height - 2,
      "chat should yield space to multiline activity"
    )

    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "in_progress",
        title = "short command",
      },
    }, { ui = { chat_width = 42 } })

    assert_equal(vim.api.nvim_buf_line_count(activity_buf), 1, "single-line activity should use one buffer line")
    assert_equal(vim.api.nvim_win_get_height(activity_win), 1, "activity window should shrink to one line")
    assert_equal(
      vim.api.nvim_win_get_height(chat_win),
      initial_chat_height,
      "chat should reclaim space after activity shrinks"
    )
  end)

  it("tool result output is collapsed and toggled", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 60, tool_results = "all" },
    }, function(_) end)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "printf lines",
        output = table.concat({ "one", "two", "three", "four", "five", "six" }, "\n") .. "\n",
        exitCode = 0,
      },
    }, { ui = { chat_width = 60, tool_results = "all" } })

    local chat_buf = vim.fn.bufnr("omniac")
    local collapsed = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(collapsed:match("Ran printf lines") ~= nil, "tool result should show command")
    assert_true(collapsed:match("one") ~= nil, "collapsed output should show first line")
    assert_true(collapsed:match("two") ~= nil, "collapsed output should show second line")
    assert_true(collapsed:match("five") ~= nil, "collapsed output should show penultimate line")
    assert_true(collapsed:match("six") ~= nil, "collapsed output should show last line")
    assert_true(collapsed:match("three") == nil, "collapsed output should hide middle lines")
    assert_true(collapsed:match("%+2 lines") ~= nil, "collapsed output should show hidden line count")

    feed("<C-t>")
    vim.wait(20)
    local expanded = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(expanded:match("three") ~= nil, "expanded output should show hidden line")
    assert_true(expanded:match("%-2 lines") ~= nil, "expanded output should show collapse hint")
  end)

  it("completed tool results return activity to working", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "completed",
        title = "run tests",
        exitCode = 0,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        title = "run tests",
        output = "ok\n",
        exitCode = 0,
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Completed execute: run tests") ~= nil, "completed tool activity should show briefly")

    vim.wait(700, function()
      activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
      return activity:match("Working") ~= nil
    end)

    assert_true(activity:match("Working") ~= nil, "completed tool result should return to working activity")
    assert_true(activity:match("Completed execute: run tests") == nil, "completed tool activity should not linger")
  end)

  it("failed tool results return activity to working", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "failed",
        title = "run tests",
        exitCode = 1,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "failed",
        title = "run tests",
        output = "nope\n",
        exitCode = 1,
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Failed execute: run tests") ~= nil, "failed tool activity should show briefly")

    vim.wait(700, function()
      activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
      return activity:match("Working") ~= nil
    end)

    assert_true(activity:match("Working") ~= nil, "failed tool result should return to working activity")
    assert_true(activity:match("Failed execute: run tests") == nil, "failed tool activity should not linger")
  end)

  it("assistant chunks clear completed tool activity", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "completed",
        title = "run tests",
        exitCode = 0,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "follow-up answer",
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "assistant chunk should restore working activity")
    assert_true(
      activity:match("Completed execute: run tests") == nil,
      "completed tool activity should clear on assistant chunk"
    )
  end)

  it("assistant chunks clear failed tool activity", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "failed",
        title = "run tests",
        exitCode = 1,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "follow-up answer",
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "assistant chunk should restore working activity")
    assert_true(
      activity:match("Failed execute: run tests") == nil,
      "failed tool activity should clear on assistant chunk"
    )
  end)

  it("compact tool results hide noisy completed output", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = {
      agent = { cmd = { "codex-acp" } },
      ui = {
        chat_width = 60,
        tool_results = "compact",
        tool_result_max_lines = 4,
      },
    }

    ui.open(config, function(_) end)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        title = "call_hidden",
        output = "internal output\n",
        exitCode = 0,
      },
    }, config)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "printf lines",
        output = table.concat({ "one", "two", "three", "four", "five" }, "\n") .. "\n",
        exitCode = 0,
      },
    }, config)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "printf ok",
        output = "ok\n",
        exitCode = 0,
      },
    }, config)

    local chat_buf = vim.fn.bufnr("omniac")
    local collapsed = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(collapsed:match("Ran call_hidden") == nil, "compact mode should hide opaque completed calls")
    assert_true(collapsed:match("Ran printf lines") == nil, "compact mode should hide long completed output")
    assert_true(collapsed:match("Ran printf ok") ~= nil, "compact mode should keep short named output")
  end)

  it("transport reconnect messages render as activity", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 62 },
    }, function(_) end)

    ui.handle_notification({
      method = "omniac/response_chunk",
      params = { text = "Reconnecting... 4/5\n" },
    }, { ui = { chat_width = 62 } })
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "Warning: Falling back from WebSockets to HTTPS transport. stream disconnected before completion: Connection refused (os error 61)\n",
      },
    }, { ui = { chat_width = 62 } })

    local chat_buf = vim.fn.bufnr("omniac")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")

    assert_true(chat:match("Reconnecting") == nil, "reconnect messages should not be added to chat")
    assert_true(chat:match("Falling back from WebSockets") == nil, "transport warnings should not be added to chat")
    assert_true(activity:match("Falling back from WebSockets") ~= nil, "transport warning should render as activity")
  end)
end)
