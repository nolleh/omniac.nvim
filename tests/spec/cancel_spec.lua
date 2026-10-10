local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim cancel", function()
  after_each(helpers.cleanup_after_test)

  it("insert esc exits insert mode before normal esc cancels active turn", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local cancels = 0

    ui.set_cancel_handler(function()
      cancels = cancels + 1
    end)
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    feed("i<Esc>")
    assert_equal(cancels, 0, "insert esc should not cancel the active turn")
    assert_equal(vim.api.nvim_get_mode().mode, "n", "insert esc should return to normal mode")

    feed("<Esc><Esc>")
    vim.cmd("redraw")
    vim.wait(50, function()
      return cancels > 0
    end)

    assert_equal(cancels, 1, "normal esc should send one cancel request while working")
  end)

  it("cancel failure allows retry", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local cancels = 0

    ui.set_cancel_handler(function()
      cancels = cancels + 1
      ui.handle_notification({
        method = "omniac/prompt_cancel_failed",
        params = {
          message = "cancel failed",
        },
      }, { ui = { chat_width = 48 } })
    end)
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    feed("i<Esc>")
    assert_equal(cancels, 0, "insert esc should not send the first cancel request")

    feed("<Esc>")
    vim.cmd("redraw")
    vim.wait(50, function()
      return cancels >= 1
    end)
    feed("<Esc>")
    vim.cmd("redraw")
    vim.wait(50, function()
      return cancels >= 2
    end)

    assert_equal(cancels, 2, "failed cancel should allow a later esc retry")
  end)

  it("cancelled turn restores working activity on restart", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({ method = "omniac/prompt_cancelled", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "restarted turn should restore working activity")
    assert_true(activity:match("Cancelled current turn") == nil, "restarted turn should clear cancelled activity")
  end)

  it("late cancelled completion from old turn is ignored", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = { turnId = 1 } }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/prompt_cancelled", params = { turnId = 1 } },
      { ui = { chat_width = 48 } }
    )
    ui.handle_notification({ method = "omniac/prompt_started", params = { turnId = 2 } }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/response_completed", params = { turnId = 1, stopReason = "cancelled" } },
      { ui = { chat_width = 48 } }
    )

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "late cancelled completion should not replace working activity")
    assert_true(activity:match("Cancelled current turn") == nil, "late cancelled completion should stay hidden")
  end)

  it("cancel suppresses late current-turn tool output", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48, tool_results = "all" },
    }

    ui.set_cancel_handler(function() end)
    ui.open(config, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, config)
    feed("i<Esc><Esc>")
    vim.cmd("redraw")

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "late command",
        output = "late output\n",
        exitCode = 0,
      },
    }, config)

    local chat_buf = vim.fn.bufnr("omniac")
    local cancelled = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(cancelled:match("late command") == nil, "late cancelled tool output should be hidden")

    ui.handle_notification({
      method = "omniac/response_completed",
      params = {
        stopReason = "max_tokens",
      },
    }, config)

    cancelled = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(
      cancelled:match("Stopped: token limit") == nil,
      "late cancelled completion should not add a stop reason footer"
    )
    assert_true(
      activity:match("Stopped: max_tokens") == nil,
      "late cancelled completion should not add stop reason activity"
    )

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, config)
    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "next command",
        output = "next output\n",
        exitCode = 0,
      },
    }, config)

    local next_turn = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(next_turn:match("next command") ~= nil, "next turn tool output should render normally")
  end)
end)
