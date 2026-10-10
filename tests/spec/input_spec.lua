local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim input", function()
  after_each(helpers.cleanup_after_test)

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

  it("tab switches between Omniac input and chat windows", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "Omniac should open focused on input")

    feed("<Tab>")
    vim.cmd("redraw")
    assert_equal(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "omniac", "Tab should focus chat")

    feed("<S-Tab>")
    vim.cmd("redraw")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "Shift-Tab should focus input")
  end)

  it("tab navigation works from explicitly focused activity window", function()
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

    vim.api.nvim_set_current_win(activity_win)
    feed("<Tab>")
    vim.cmd("redraw")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "Tab from activity should focus input")

    vim.api.nvim_set_current_win(activity_win)
    feed("<S-Tab>")
    vim.cmd("redraw")
    assert_equal(
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
      "omniac",
      "Shift-Tab from activity should focus chat"
    )
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
