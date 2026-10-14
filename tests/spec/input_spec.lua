local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim input", function()
  after_each(helpers.cleanup_after_test)

  it("keeps input when submission is rejected and restores saved attachments", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local accepted = false
    local submissions = {}

    ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 42 } }, function(text, attachments)
      if not accepted then
        return false
      end
      table.insert(submissions, { text = text, attachments = attachments })
    end)

    feed("ihello<CR>")
    local input_buf = vim.fn.bufnr("omniac://input")
    assert_true(
      table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"):find("hello", 1, true) ~= nil,
      "rejected submission should remain in input"
    )

    accepted = true
    feed("<CR>")
    assert_equal(submissions[1].text, "hello", "accepted submission should send the draft")
    assert_equal(
      ui.restore_input("saved prompt", { { type = "reference", text = "context", path = "/tmp/example" } }),
      true
    )
    feed("<CR>")
    assert_equal(submissions[2].text, "saved prompt", "restored text should be sent")
    assert_equal(submissions[2].attachments[1].path, "/tmp/example", "restored reference should be sent")
  end)

  it("queues the input with Tab and clears the draft", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local queued = {}
    ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 42 } }, function() end, function(text, attachments)
      table.insert(queued, { text = text, attachments = attachments })
      return true
    end)

    feed("iqueued prompt<Tab>")
    assert_equal(#queued, 1, "Tab should queue one prompt")
    assert_equal(queued[1].text, "queued prompt", "queued text should match the draft")
    assert_equal(#queued[1].attachments, 0, "queued attachments should be captured")
    local input_buf = vim.fn.bufnr("omniac://input")
    assert_true(
      vim.wait(200, function()
        local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
        return table.concat(lines, "\n"):find("queued prompt", 1, true) == nil
      end),
      "queued input should be cleared"
    )
  end)

  it("sends queued prompts in order after the active response completes", function()
    local omniac = require("omniac")
    local ui = require("omniac.ui")
    local original_submit = ui.submit
    ui.submit = function() end
    local prompts = {}
    local callbacks = {}
    omniac.backend = { running = true }
    function omniac.backend:prompt(text, _, callback)
      table.insert(prompts, text)
      table.insert(callbacks, callback)
    end
    local first = { text = "first", attachments = {} }
    omniac.active_submission = first
    omniac.failed_submission = nil
    omniac.queued_submissions = {
      { text = "second", attachments = {} },
      { text = "third", attachments = {} },
    }

    omniac.ask(first.text, first.attachments, first)
    assert_equal(#prompts, 1, "only the active prompt should be sent")
    callbacks[1](nil, {})
    assert_equal(prompts[2], "second", "the first queued prompt should be next")
    callbacks[2](nil, {})
    assert_equal(prompts[3], "third", "queued prompts should keep their order")
    callbacks[3](nil, {})
    assert_equal(omniac.active_submission, nil, "the queue should finish without an active prompt")
    assert_equal(#omniac.queued_submissions, 0, "the queue should be empty")

    omniac.backend = nil
    ui.submit = original_submit
  end)

  it("retains one failed prompt with its content and resends only on request", function()
    local omniac = require("omniac")
    local ui = require("omniac.ui")
    local original_show_failure_action = ui.show_failure_action
    local original_status = ui.set_status
    local original_activity = ui.set_activity
    local original_message = ui.add_message
    local prompts = {}
    local callbacks = {}
    local menu
    local client = { running = true }
    function client:prompt(text, params, callback)
      table.insert(prompts, { text = text, params = params })
      table.insert(callbacks, callback)
    end
    ui.show_failure_action = function(callback)
      menu = callback
    end
    ui.set_status = function() end
    ui.set_activity = function() end
    ui.add_message = function() end

    local item = {
      text = "question",
      attachments = { { type = "reference", path = "/tmp/example" } },
      prompt = "question with context",
      params = { prompt = { { type = "text", text = "question with context" } } },
    }
    omniac.backend = client
    omniac.active_submission = item
    omniac.failed_submission = nil
    omniac.ask(item.text, item.attachments, item)
    callbacks[1]({ message = "timed out" })
    assert_equal(#prompts, 1, "failure should not resend automatically")
    assert_equal(omniac.failed_submission, item, "failed submission should be saved")
    assert_true(
      vim.wait(200, function()
        return menu ~= nil
      end),
      "failure action menu should open"
    )
    menu("resend")
    assert_equal(#prompts, 2, "explicit retry should send exactly once")
    assert_equal(prompts[2].params.prompt[1].text, "question with context", "retry should reuse original prompt")
    assert_equal(item.attachments[1].path, "/tmp/example", "saved attachment should remain available")
    callbacks[2](nil, {})
    assert_equal(omniac.active_submission, nil, "successful retry should release the submission")
    assert_equal(omniac.failed_submission, nil, "successful retry should clear the saved failure")

    omniac.backend = nil
    ui.show_failure_action = original_show_failure_action
    ui.set_status = original_status
    ui.set_activity = original_activity
    ui.add_message = original_message
  end)

  it("input focus returns to end of wrapped message", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    feed(string.rep("a", 80))
    vim.cmd("stopinsert")
    vim.cmd("wincmd p")
    feed("i")
    vim.cmd("redraw")

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local view = vim.fn.winsaveview()

    assert_equal(vim.wo.wrap, true, "input window should wrap instead of horizontal scrolling")
    assert_equal(view.leftcol, 0, "input window should not be horizontally scrolled")
    assert_equal(cursor[1], #lines - 1, "cursor should return to final input display line")
    assert_true(cursor[2] > 0, "cursor should be past the input prefix")
    vim.cmd("stopinsert")
  end)

  it("input cursor is clamped away from prompt marker", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("startinsert")
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    vim.cmd("doautocmd CursorMovedI")
    vim.cmd("redraw")

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert_true(cursor[2] >= #"│ > ", "cursor should be moved to the content column")
    vim.cmd("stopinsert")
  end)

  it("input padding cursor is remapped safely", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(0, { 3, #"│ " })
    vim.cmd("doautocmd TextChangedI")
    vim.cmd("redraw")

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert_equal(cursor[1], 2, "padding cursor should map back to the editable input line")
  end)

  it("input history recalls previous prompts with up and down", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted = {}
    local input_buf

    local function wait_for(predicate, message)
      local ok = vim.wait(500, function()
        if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
          return false
        end
        return predicate(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
      end)
      assert_true(ok, message or "timed out waiting for input state")
    end

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(text)
      table.insert(submitted, text)
    end)

    feed("ifirst prompt<CR>")
    feed("isecond prompt<CR>")

    feed("<Up>")
    vim.cmd("redraw")
    input_buf = vim.fn.bufnr("omniac://input")
    wait_for(function(lines)
      return table.concat(lines, "\n"):match("second prompt") ~= nil
    end, "timed out waiting for input to show second prompt")

    vim.cmd("stopinsert")
    vim.cmd("redraw")

    feed("<Up>")
    vim.cmd("redraw")
    wait_for(function(lines)
      return table.concat(lines, "\n"):match("first prompt") ~= nil
    end, "timed out waiting for input to show first prompt")

    feed("<Down>")
    vim.cmd("redraw")
    wait_for(function(lines)
      return table.concat(lines, "\n"):match("second prompt") ~= nil
    end, "timed out waiting for input to show second prompt")

    feed("<Down>")
    vim.cmd("redraw")
    wait_for(function(lines)
      return (lines[2] or "") == "│ > "
    end, "timed out waiting for empty prompt")

    assert_equal(submitted[1], "first prompt", "first prompt should be submitted")
    assert_equal(submitted[2], "second prompt", "second prompt should be submitted")
  end)

  it("input up and down keep normal cursor motion when text is present", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    feed("ihello")
    local before = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("omniac://input"), 0, -1, false), "\n")
    feed("<Up>")
    vim.cmd("redraw")
    local after = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("omniac://input"), 0, -1, false), "\n")
    assert_equal(after, before, "up should not replace non-empty input with history")
  end)

  it("editing a recalled prompt ends history navigation", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    feed("ifirst prompt<CR>")
    feed("isecond prompt<CR>")
    feed("<Up>")
    local input_buf = vim.fn.bufnr("omniac://input")
    assert_true(
      vim.wait(500, function()
        return (vim.api.nvim_buf_get_lines(input_buf, 1, 2, false)[1] or ""):find("second prompt", 1, true) ~= nil
      end),
      "history should recall the latest prompt"
    )

    feed(" edited")
    vim.cmd("redraw")
    local before = vim.api.nvim_buf_get_lines(input_buf, 1, 2, false)[1]
    feed("<Up>")
    vim.cmd("redraw")
    assert_equal(vim.api.nvim_buf_get_lines(input_buf, 1, 2, false)[1], before, "editing should stop history traversal")
  end)

  it("ctrl-c clears a draft and lets empty-input history navigation start again", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted = {}

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(text)
      table.insert(submitted, text)
    end)

    feed("isaved prompt<CR>")
    feed("idraft text<C-c>")
    vim.cmd("redraw")
    local input_buf = vim.fn.bufnr("omniac://input")
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    assert_equal(lines[2], "│ > ", "ctrl-c should clear the draft")
    assert_equal(#submitted, 1, "ctrl-c should not submit a prompt")

    feed("<Up>")
    assert_true(
      vim.wait(500, function()
        return table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"):find("saved prompt", 1, true)
          ~= nil
      end),
      "up should recall history after ctrl-c"
    )
  end)

  it("tab has no Omniac mapping and shift-tab toggles plan without changing focus", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local input_buf = vim.fn.bufnr("omniac://input")
    local toggled = 0
    ui.set_plan_toggle_handler(function()
      toggled = toggled + 1
    end)
    assert_true(vim.fn.maparg("<Tab>", "i", false, true).buffer ~= 1, "Tab should have no Omniac mapping")
    feed("<S-Tab>")
    assert_equal(toggled, 1, "Shift-Tab should toggle plan mode")
    assert_equal(vim.api.nvim_get_current_buf(), input_buf, "Shift-Tab should keep input focused")
  end)

  it("shift-tab toggles plan from the activity window", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local activity_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == "omniac://activity" then
        activity_win = win
        break
      end
    end
    assert_true(activity_win ~= nil, "activity window should exist")

    local toggled = 0
    ui.set_plan_toggle_handler(function()
      toggled = toggled + 1
    end)
    vim.api.nvim_set_current_win(activity_win)
    feed("<S-Tab>")
    assert_equal(toggled, 1, "Shift-Tab should toggle plan mode")
    assert_equal(vim.api.nvim_get_current_win(), activity_win, "Shift-Tab should keep activity focused")
  end)

  it("control-k and control-j move vertically across Omniac windows", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    feed("i<C-k>")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://activity", "Ctrl-k should move above input")

    local input_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == "omniac://input" then
        input_win = win
        break
      end
    end
    vim.api.nvim_set_current_win(input_win)
    feed("<C-j>")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://status", "Ctrl-j should move below input")

    feed("<C-k>")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "Ctrl-k should move above status")
    feed("<C-k>")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://activity", "Ctrl-k should move above input")
    feed("<C-k>")
    assert_equal(
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
      "omniac",
      "Ctrl-k should move above activity to chat"
    )
    feed("<C-j>")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://activity", "Ctrl-j should move below chat")
  end)

  it("closes every Omniac split when one of them is quit", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local original_win = vim.api.nvim_get_current_win()
    local ui_state = ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)
    local omniac_wins = {
      ui_state.card_win,
      ui_state.chat_win,
      ui_state.activity_win,
      ui_state.input_win,
      ui_state.status_win,
    }

    vim.api.nvim_win_call(ui_state.activity_win, function()
      vim.cmd("quit")
    end)

    assert_true(
      vim.wait(250, function()
        for _, win in ipairs(omniac_wins) do
          if win and vim.api.nvim_win_is_valid(win) then
            return false
          end
        end
        return true
      end),
      "quitting one Omniac split should close the whole UI"
    )
    assert_true(vim.api.nvim_win_is_valid(original_win), "quitting Omniac should preserve the original editor window")
  end)

  it("input ctrl-v attaches clipboard image and submits it", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.clipboard"] = {
      read_image = function()
        return {
          type = "image",
          mimeType = "image/png",
          data = "aW1n",
          byteSize = 3,
        }
      end,
    }
    local ui = require("omniac.ui")
    local submitted_text
    local submitted_attachments

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(text, attachments)
      submitted_text = text
      submitted_attachments = attachments
    end)

    vim.cmd("startinsert")
    feed("<C-v>")
    vim.wait(20)
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 1, 2, false, { "│ > describe image" })
    feed("<CR>")
    vim.cmd("redraw")

    assert_equal(submitted_text, "describe image", "submit should keep typed prompt text")
    assert_equal(#submitted_attachments, 1, "submit should include the pasted image")
    assert_equal(submitted_attachments[1].mimeType, "image/png", "image mime type should be preserved")

    package.loaded["omniac.clipboard"] = nil
  end)

  it("input allows greater-than as user text", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(0, { 2, #"│ > " })
    feed("i><Esc>")
    vim.cmd("redraw")

    local line = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 1, 2, false)[1]
    assert_equal(line, "│ > >", "greater-than should be kept as input text")
  end)

  it("normal i inside input prompt starts at content column", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    feed("ix<Esc>")
    vim.cmd("redraw")

    local line = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 1, 2, false)[1]
    assert_equal(line, "│ > x", "typed text should be inserted after the input prompt")
  end)

  it("input height shrinks back to three display lines", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    assert_equal(vim.api.nvim_win_get_height(0), 5, "input window should start with three display lines")
    assert_equal(vim.api.nvim_buf_line_count(0), 5, "input box should start with three display lines")

    local text = table.concat({ "a", "b", "c", "d", "e" }, "<S-CR>")
    feed("i" .. text .. "<Esc>")
    vim.cmd("redraw")

    assert_equal(vim.api.nvim_win_get_height(0), 7, "input window should grow with input lines")

    feed("i<BS><BS><BS><BS><Esc>")
    vim.cmd("redraw")

    assert_equal(vim.api.nvim_win_get_height(0), 5, "input window should shrink back to the minimum display height")
    assert_equal(vim.api.nvim_buf_line_count(0), 5, "input box should fill the minimum input window height")
    assert_equal(vim.fn.winsaveview().topline, 1, "input top border should stay visible")
  end)

  it("input line background does not override border foreground", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local input_hl = vim.api.nvim_get_hl(0, { name = "OmniacInput" })
    local input_text_hl = vim.api.nvim_get_hl(0, { name = "OmniacInputText" })

    assert_equal(input_hl.fg, nil, "input line highlight should only provide the input background")
    assert_equal(input_hl.bg, tonumber("313244", 16), "input line highlight should keep the input background")
    assert_equal(input_text_hl.fg, tonumber("cdd6f4", 16), "input text should keep the normal input foreground")
    assert_equal(input_text_hl.bg, tonumber("313244", 16), "input text should keep the input background")
  end)
end)
