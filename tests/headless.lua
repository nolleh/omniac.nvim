vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.showmode = false
vim.api.nvim_echo = function() end
vim.notify = function() end

local failures = 0
local reported = false

local function report(message)
  if reported then
    io.stdout:write("\n")
  end
  io.stdout:write(message .. "\n")
  io.stdout:flush()
  reported = true
end

local function fail(message)
  error(message, 2)
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    fail(
      string.format("%s: expected %s, got %s", message or "assert_equal", vim.inspect(expected), vim.inspect(actual))
    )
  end
end

local function assert_true(value, message)
  if not value then
    fail(message or "assert_true failed")
  end
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(tostring(keys or ""), true, false, true), "xt", false)
  vim.wait(20, function()
    return true
  end)
  vim.cmd("redraw")
end

local function run(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    report("ok - " .. name)
  else
    failures = failures + 1
    report("not ok - " .. name)
    report(err)
  end
end

local function cleanup_omniac_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local basename = vim.fn.fnamemodify(name, ":t")
    if basename == "omniac" or name:match("omniac://") then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function has_window_for_buffer_name(name)
  local target = vim.fn.bufnr(name)
  if target == -1 then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == target then
      return true
    end
  end
  return false
end

run("diff review accepts with :w", function()
  package.loaded["omniac.diff"] = nil
  local diff = require("omniac.diff")
  local result

  diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {}, function(accepted, lines)
    result = {
      accepted = accepted,
      lines = lines,
    }
  end)

  vim.cmd("w")

  assert_true(result ~= nil, "review callback should run")
  assert_equal(result.accepted, true, "review should be accepted")
  assert_equal(result.lines[1], "new", "accepted lines should come from proposed buffer")
end)

run("diff review denies with :q", function()
  package.loaded["omniac.diff"] = nil
  local diff = require("omniac.diff")
  local result

  diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {}, function(accepted, lines)
    result = {
      accepted = accepted,
      lines = lines,
    }
  end)

  vim.cmd("q")

  assert_true(result ~= nil, "review callback should run")
  assert_equal(result.accepted, false, "review should be denied")
  assert_equal(result.lines, nil, "denied review should not return accepted lines")
end)

run("diff review can deny edited proposed buffer with :q", function()
  package.loaded["omniac.diff"] = nil
  local diff = require("omniac.diff")
  local result

  diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {}, function(accepted, lines)
    result = {
      accepted = accepted,
      lines = lines,
    }
  end)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
  vim.cmd("doautocmd TextChanged")
  assert_equal(vim.bo.modified, false, "review buffer should stay quit-safe after edit")
  vim.cmd("q")

  assert_true(result ~= nil, "review callback should run")
  assert_equal(result.accepted, false, "edited review should still be denied by :q")
end)

run("diff review opens in normal mode", function()
  package.loaded["omniac.diff"] = nil
  local diff = require("omniac.diff")

  vim.cmd("startinsert")
  diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {})

  assert_true(not vim.fn.mode():match("^i"), "diff review should leave insert mode when it opens")
end)

run("diff review jumps to the first changed line", function()
  package.loaded["omniac.diff"] = nil
  local diff = require("omniac.diff")

  diff.open_review("/tmp/omniac-test.txt", { "keep", "old", "tail" }, { "keep", "new", "tail" }, {})

  local cursor = vim.api.nvim_win_get_cursor(0)
  assert_equal(cursor[1], 2, "diff review should place the cursor on the first changed line")
  assert_equal(cursor[2], 0, "diff review cursor should start at column 0")
end)

run("session dialog flattens multiline session titles", function()
  package.loaded["omniac.session_dialog"] = nil
  local dialog = require("omniac.session_dialog")
  local result

  dialog.open({
    {
      sessionId = "sess_1",
      title = "first line\n\nCurrent file: omniac://input",
      cwd = "/tmp/project",
      updatedAt = "2026-06-04T13:03:55.000Z",
    },
  }, {
    list_supported = true,
  }, function(selection)
    result = selection
  end)

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local rendered = table.concat(lines, "\n")
  assert_true(rendered:match("current file") ~= nil, "session title metadata should preserve regular letters")
  assert_true(rendered:match("%[LOAD%]") == nil, "session rows should not repeat the load action label")
  assert_true(rendered:match("sess_1") ~= nil, "session item should render after flattening multiline text")
  assert_true(rendered:match("전") ~= nil, "session metadata should include relative time")
  local footer_rendered = ""
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "omniac-session-footer" then
      footer_rendered = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      break
    end
  end
  assert_true(footer_rendered:match("%[n%] new") ~= nil, "new session action should render in the footer")

  feed("q")
  assert_equal(result, nil, "closing the dialog without selection should not choose a session")
end)

run("input focus returns to end of wrapped message", function()
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

run("input cursor is clamped away from prompt marker", function()
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

run("input padding cursor is remapped safely", function()
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

run("tab switches between Omniac input and chat windows", function()
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

run("tab navigation works from explicitly focused activity window", function()
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

run("input ctrl-v attaches clipboard image and submits it", function()
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

run("input allows greater-than as user text", function()
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

run("normal i inside input prompt starts at content column", function()
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

run("input height shrinks back to three display lines", function()
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

run("input line background does not override border foreground", function()
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

run("activity text keeps horizontal padding when truncated", function()
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

run("tool result output is collapsed and toggled", function()
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

run("completed tool results return activity to working", function()
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
  assert_true(activity:match("Working") ~= nil, "completed tool result should return to working activity")
  assert_true(activity:match("Completed execute: run tests") == nil, "completed tool activity should not linger")
end)

run("compact tool results hide noisy completed output", function()
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

run("chat buffer uses markdown renderer when available", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
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

  local ui = require("omniac.ui")
  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  ui.handle_notification({
    method = "omniac/response_chunk",
    params = {
      text = "```markdown\n| A | B |\n| - | - |\n| 1 | 2 |\n```\n\n```lua\nprint('x')\n```",
    },
  }, { ui = { chat_width = 48 } })
  ui.handle_notification({ method = "omniac/response_completed", params = {} }, { ui = { chat_width = 48 } })

  local chat_buf = vim.fn.bufnr("omniac")
  local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  local chat_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == chat_buf then
      chat_win = win
      break
    end
  end
  assert_true(chat_buf ~= -1, "chat buffer should exist")
  assert_true(chat_win ~= nil, "chat window should exist")
  assert_equal(vim.wo[chat_win].signcolumn, "no", "chat window should not use signcolumn for padding")
  assert_equal(vim.bo[chat_buf].filetype, "markdown", "chat buffer should use markdown filetype")
  assert_true(chat:match("```markdown") == nil, "markdown fences should be unwrapped before display")
  assert_true(chat:match("| A | B |") ~= nil, "markdown fence contents should remain visible")
  assert_true(chat:match("```lua") ~= nil, "non-markdown code fences should remain intact")
  assert_true(chat:match("\n| A | B |\n") ~= nil, "markdown table rows should be inserted without padding")
  assert_true(chat:match("\n  | A | B |") == nil, "markdown table rows should not receive leading UI padding")
  assert_true(chat:match("| A | B |  \n") == nil, "markdown table rows should not receive trailing UI padding")
  assert_true(#render_calls > 0, "render-markdown should be called for chat rendering")
  assert_equal(render_calls[#render_calls].buf, chat_buf, "render-markdown should receive the chat buffer")
  assert_equal(render_calls[#render_calls].event, "OmniacRender", "render-markdown should receive an Omniac event")
  assert_equal(
    render_calls[#render_calls].config.pipe_table.style,
    "normal",
    "chat tables should use compact markdown rendering"
  )
  assert_equal(
    render_calls[#render_calls].config.pipe_table.border_virtual,
    true,
    "chat table borders should avoid consuming empty buffer lines"
  )

  package.preload["render-markdown"] = nil
  package.loaded["render-markdown"] = nil
end)

run("streaming response defers markdown rendering until complete", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
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

  local ui = require("omniac.ui")
  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  local initial_calls = #render_calls

  ui.handle_notification({
    method = "omniac/response_chunk",
    params = {
      text = "| A | B |\n| - | - |\n| 1 | 2 |\n",
    },
  }, { ui = { chat_width = 48 } })
  assert_equal(#render_calls, initial_calls, "streaming chunks should not invoke markdown rendering")

  ui.handle_notification({ method = "omniac/response_completed", params = {} }, { ui = { chat_width = 48 } })
  assert_true(#render_calls > initial_calls, "completed responses should invoke markdown rendering")

  package.preload["render-markdown"] = nil
  package.loaded["render-markdown"] = nil
end)

run("response stop reasons render only actionable UI", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)

  ui.handle_notification(
    { method = "omniac/response_chunk", params = { text = "short answer" } },
    { ui = { chat_width = 48 } }
  )
  ui.handle_notification(
    { method = "omniac/response_completed", params = { stopReason = "max_tokens" } },
    { ui = { chat_width = 48 } }
  )

  local chat_buf = vim.fn.bufnr("omniac")
  local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  assert_true(chat:match("short answer") ~= nil, "response text should render")
  assert_true(chat:match("Stopped: token limit") ~= nil, "token limit stop reason should render as footer")

  ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
  ui.handle_notification(
    { method = "omniac/response_completed", params = { stopReason = "cancelled" } },
    { ui = { chat_width = 48 } }
  )

  local activity_buf = vim.fn.bufnr("omniac://activity")
  local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
  assert_true(activity:match("Turn cancelled%.") ~= nil, "cancelled stop reason should render as activity")

  ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
  ui.handle_notification({ method = "omniac/response_chunk", params = { text = "done" } }, { ui = { chat_width = 48 } })
  ui.handle_notification(
    { method = "omniac/response_completed", params = { stopReason = "end_turn" } },
    { ui = { chat_width = 48 } }
  )

  chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  assert_true(chat:match("Stopped: end_turn") == nil, "normal end_turn should not render as chat noise")
end)

run("assistant prose keeps chat padding", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  ui.handle_notification({
    method = "omniac/response_chunk",
    params = {
      text = "plain assistant line",
    },
  }, { ui = { chat_width = 48 } })

  local chat_buf = vim.fn.bufnr("omniac")
  local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  assert_true(chat:match("\n  plain assistant line%s+\n") ~= nil, "assistant prose should keep horizontal padding")
end)

run("assistant prose wraps instead of ellipsizing", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  ui.handle_notification({
    method = "omniac/response_chunk",
    params = {
      text = "this assistant response is intentionally long enough to wrap across more than one visible chat line",
    },
  }, { ui = { chat_width = 48 } })

  local chat_buf = vim.fn.bufnr("omniac")
  local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local prose_lines = 0
  local prose_text = {}
  for _, line in ipairs(lines) do
    if line:match("^  %S") and not line:match("^  [─]+%s*$") then
      prose_lines = prose_lines + 1
      table.insert(prose_text, line)
    end
  end

  assert_true(table.concat(prose_text, "\n"):match("…") == nil, "assistant prose should not be ellipsized")
  assert_true(prose_lines >= 2, "assistant prose should wrap across multiple padded lines")
end)

run("chat and input redraw after user vertical resize", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
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

  local ui = require("omniac.ui")
  vim.api.nvim_set_option_value("columns", 180, {})
  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 58 },
  }, function(_) end)

  local chat_buf = vim.fn.bufnr("omniac")
  local input_buf = vim.fn.bufnr("omniac://input")
  local status_buf = vim.fn.bufnr("omniac://status")
  local chat_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == chat_buf then
      chat_win = win
      break
    end
  end
  assert_true(chat_win ~= nil, "chat window should exist")

  vim.cmd("vertical resize 100")
  vim.cmd("doautocmd WinResized")
  vim.wait(50, function()
    local chat_line = vim.api.nvim_buf_get_lines(chat_buf, 0, 1, false)[1] or ""
    local input_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
    return vim.fn.strdisplaywidth(chat_line) == 100 and vim.fn.strdisplaywidth(input_line) == 100 and #render_calls >= 2
  end)

  local chat_line = vim.api.nvim_buf_get_lines(chat_buf, 0, 1, false)[1] or ""
  local input_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
  local status_line = vim.api.nvim_buf_get_lines(status_buf, 0, 1, false)[1] or ""
  assert_equal(vim.api.nvim_win_get_width(chat_win), 100, "user resize should keep the chat window width")
  assert_equal(vim.wo[chat_win].signcolumn, "no", "chat should not use signcolumn for padding")
  assert_equal(vim.fn.strdisplaywidth(chat_line), 100, "chat should redraw to the resized width")
  assert_equal(vim.fn.strdisplaywidth(input_line), 100, "input should redraw to the resized width")
  assert_equal(vim.fn.strdisplaywidth(status_line), 100, "status should redraw to the resized width")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 58 },
  }, function(_) end)
  assert_equal(vim.api.nvim_win_get_width(chat_win), 100, "reopening chat should preserve user resize width")

  package.preload["render-markdown"] = nil
  package.loaded["render-markdown"] = nil
end)

run("closing a normal window does not change the preserved omniac width", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil

  local ui = require("omniac.ui")
  vim.api.nvim_set_option_value("columns", 180, {})
  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 58 },
  }, function(_) end)

  local chat_buf = vim.fn.bufnr("omniac")
  local chat_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == chat_buf then
      chat_win = win
      break
    end
  end
  assert_true(chat_win ~= nil, "chat window should exist")

  vim.cmd("vsplit")
  vim.cmd("enew")
  ui.resize(100)
  assert_equal(vim.api.nvim_win_get_width(chat_win), 100, "manual resize should update the omniac width")

  vim.cmd("close")
  vim.cmd("doautocmd WinResized")
  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 58 },
  }, function(_) end)

  assert_equal(
    vim.api.nvim_win_get_width(chat_win),
    100,
    "closing a normal window should not change the preserved width"
  )
end)

run("completed assistant messages keep turn separators after reopen", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  local config = {
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }

  ui.open(config, function(_) end)
  ui.add_message("Omniac", "first answer", config)
  ui.add_message("Omniac", "second answer", config)
  ui.open(config, function(_) end)

  local chat_buf = vim.fn.bufnr("omniac")
  local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local separators = 0
  for _, line in ipairs(lines) do
    if line:match("^  [─]+%s*$") then
      separators = separators + 1
    end
  end

  assert_true(separators >= 2, "completed assistant messages should keep visible turn separators")
end)

run("user messages keep turn separators after reopen", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  local config = {
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }

  ui.open(config, function(_) end)
  ui.add_message("You", "first prompt", config)
  ui.add_message("You", "second prompt", config)
  ui.open(config, function(_) end)

  local chat_buf = vim.fn.bufnr("omniac")
  local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local separators = 0
  for _, line in ipairs(lines) do
    if line:match("^  [─]+%s*$") then
      separators = separators + 1
    end
  end

  assert_true(separators >= 2, "user messages should keep visible turn separators")
end)

run("omniac resize command resizes the side ui as one body", function()
  cleanup_omniac_buffers()
  package.loaded["omniac"] = nil
  package.loaded["omniac.ui"] = nil
  package.loaded["render-markdown"] = nil

  package.preload["render-markdown"] = function()
    return {
      initialized = true,
      render = function(_) end,
    }
  end

  local omniac = require("omniac")
  vim.api.nvim_set_option_value("columns", 180, {})
  omniac.setup({
    backend = { kind = "acp" },
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 58 },
  })
  omniac.open_chat()

  vim.cmd("OmniacResize 100")

  local widths = {}
  for _, name in ipairs({ "omniac", "omniac://activity", "omniac://input", "omniac://status" }) do
    local buf = vim.fn.bufnr(name)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        table.insert(widths, vim.api.nvim_win_get_width(win))
        break
      end
    end
  end

  assert_equal(#widths, 4, "all omniac side windows should be open")
  for _, actual in ipairs(widths) do
    assert_equal(actual, 100, "omniac side windows should share the requested width")
  end

  package.preload["render-markdown"] = nil
  package.loaded["render-markdown"] = nil
end)

run("transport reconnect messages render as activity", function()
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

run("permission request shows JSON-RPC details in chat and selector", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  package.loaded["omniac.approval"] = nil
  package.loaded["omniac.permission_dialog"] = nil
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
      rawInput = {
        command = "stylua lua/omniac/clipboard.lua lua/omniac/backend/acp.lua lua/omniac/init.lua lua/omniac/ui.lua tests/headless.lua",
        cwd = "/Users/nolleh/Documents/workspace_github/omniac.nvim",
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
  dialog_text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
  feed("1")
  vim.wait(50, function()
    return replied ~= nil
  end)

  ui.handle_notification(
    { method = "omniac/response_chunk", params = { text = "after" } },
    { ui = { chat_width = 48 } }
  )
  ui.handle_notification({ method = "omniac/response_completed", params = {} }, { ui = { chat_width = 48 } })

  local chat_buf = vim.fn.bufnr("omniac")
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
  assert_true(chat:match("cwd:") ~= nil, "permission chat should show cwd")
  assert_true(chat:match("Options:") == nil, "permission chat should leave options to the selector")
  assert_true(chat:match("Details:") == nil, "permission chat should not expose protocol-ish detail labels")
  assert_true(dialog_text:match("Permission requested: execute") ~= nil, "selector prompt should stay compact")
  assert_equal(replied.outcome.optionId, "allow_once", "permission reply should select the chosen option")

  local activity_buf = vim.fn.bufnr("omniac://activity")
  local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
  assert_true(activity:match("Permission requested") == nil, "permission activity should clear after decision")
end)

run("permission selector leaves insert mode and stays read-only", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.permission_dialog"] = nil
  local dialog = require("omniac.permission_dialog")

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

run("permission profile requests require a user choice", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.approval"] = nil
  package.loaded["omniac.permission_dialog"] = nil
  local approval = require("omniac.approval")

  local decided = nil
  approval.review_permission_request({
    kind = "permissions",
    description = "Grant turn permissions for this request?",
  }, function(accepted)
    decided = accepted
  end, { ui = { chat_width = 48 } })

  vim.wait(50, function()
    return vim.fn.bufnr("omniac://permission") ~= -1
  end)
  assert_equal(decided, nil, "permission request should wait for explicit input")

  feed("q")
  vim.wait(50, function()
    return decided ~= nil
  end)
  assert_equal(decided, false, "rejecting the permission request should deny it")
end)

run("edit permission without diff falls back to selector", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  package.loaded["omniac.approval"] = nil
  package.loaded["omniac.permission_dialog"] = nil
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

run("late edit permission diff replaces fallback selector", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  package.loaded["omniac.approval"] = nil
  package.loaded["omniac.permission_dialog"] = nil
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

run("permission dialog ignores escape without cancelling", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.permission_dialog"] = nil
  local dialog = require("omniac.permission_dialog")
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

run("permission dialog replaces an existing dialog", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.permission_dialog"] = nil
  local dialog = require("omniac.permission_dialog")

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

run("status renders ACP session mode", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function() end)

  ui.handle_notification({
    method = "omniac/session_mode_update",
    params = {
      currentModeId = "code",
      currentModeName = "Code",
    },
  }, {
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  })

  local status_buf = vim.fn.bufnr("omniac://status")
  local line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
  assert_true(line:match("Code") ~= nil, "status should include the current ACP mode")
end)

run("ACP protocol file logs follow debug option", function()
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
  local on_logs = vim.fn.globpath(on_dir, "acp-*.jsonl", false, true)
  assert_equal(#on_logs, 1, "debug=true should write ACP protocol files")

  pcall(vim.fn.delete, off_dir, "rf")
  pcall(vim.fn.delete, on_dir, "rf")
end)

run("ACP mode config options cycle with set_config_option", function()
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

run("ACP permission-like config modes are ignored", function()
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

run("ACP legacy planning modes cycle with set_mode", function()
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

run("ACP cancel sends session cancel request", function()
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

  client:cancel(function(err)
    assert_equal(err, nil, "cancel should succeed")
  end)

  assert_equal(request.method, "session/cancel", "cancel should use the ACP cancel method")
  assert_equal(request.params.sessionId, "sess_1", "cancel should target the active session")
end)

run("ACP completed tool call emits tool result output", function()
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

run("ACP prompt sends image content blocks when advertised", function()
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

run("ACP prompt response emits stop reason", function()
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

run("ACP empty prompt result still emits response_completed", function()
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

run("ACP edit diff emits permission diff for new files", function()
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

run("ACP edit add emits permission diff for created files", function()
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

run("ACP prompt rejects image content blocks without capability", function()
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

run("ACP list sessions requests even without advertised capability", function()
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

run("ACP list sessions stops on JSON null cursor", function()
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
      if #requests == 1 then
        callback(nil, {
          sessions = {
            { sessionId = "sess_1" },
          },
          nextCursor = "cursor_2",
        })
        return
      end

      callback(nil, {
        sessions = {
          { sessionId = "sess_2" },
        },
        nextCursor = vim.NIL,
      })
    end,
  }

  client:list_sessions(function(err, sessions)
    assert_equal(err, nil, "list_sessions should not fail on JSON null cursor")
    listed = sessions
  end)

  assert_equal(#requests, 2, "JSON null nextCursor should terminate pagination")
  assert_equal(requests[2].params.cursor, "cursor_2", "second page should use the first cursor")
  assert_equal(#listed, 2, "sessions from both pages should be collected")
  assert_equal(listed[2].sessionId, "sess_2", "second page sessions should be included")
end)

run("ACP select session falls back when list request fails", function()
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

run("ACP mode state can be nested in session result", function()
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

run("ACP fs/read_text_file prefers unsaved buffer content", function()
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

run("ACP fs/write_text_file writes disk and updates loaded buffer", function()
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

run("slash input opens command suggestions below chat", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  ui.set_available_commands({
    { name = "test", description = "Run project tests" },
    { name = "plan", description = "Create a plan" },
  })

  feed("i/<Esc>")
  vim.cmd("redraw")

  local command_buf
  local command_win
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
      command_buf = buf
      break
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if command_buf and vim.api.nvim_win_get_buf(win) == command_buf then
      command_win = win
      break
    end
  end

  assert_true(command_buf ~= nil, "commands buffer should be created")
  assert_true(command_win ~= nil, "commands window should be visible")
  assert_true(vim.api.nvim_win_get_height(command_win) <= 5, "commands window should show up to five rows")

  local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
  assert_true(lines:match("/exit") ~= nil, "local exit command should be listed")
  assert_true(lines:match("/resume") ~= nil, "local resume command should be listed")
  assert_true(lines:match("/plan") ~= nil, "agent command should be listed")
  assert_true(lines:match("@README") == nil, "slash suggestions should not include file mentions")

  feed("a<BS>hello<Esc>")
  vim.cmd("redraw")

  assert_equal(vim.api.nvim_win_is_valid(command_win), false, "commands window should close for non-slash input")
end)

run("slash command suggestions tolerate null input metadata", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  ui.set_available_commands({
    { name = "compact", description = vim.NIL, input = vim.NIL },
  })

  feed("i/com<Esc>")
  vim.cmd("redraw")

  local command_buf
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
      command_buf = buf
      break
    end
  end

  assert_true(command_buf ~= nil, "commands buffer should be available")
  local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
  assert_true(lines:match("/compact") ~= nil, "command with null metadata should be listed")
end)

run("dollar input opens agent skill suggestions", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  ui.set_available_commands({
    { name = "skills", description = "List skills" },
    { name = "$imagegen", description = "Generate images" },
    { name = "$openai-docs", description = "OpenAI docs" },
  })

  feed("i$im<Esc>")
  vim.cmd("redraw")

  local command_buf
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
      command_buf = buf
      break
    end
  end

  assert_true(command_buf ~= nil, "skill suggestions should use the commands buffer")
  local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
  assert_true(lines:match("%$imagegen") ~= nil, "dollar-prefixed skill should be listed")
  assert_true(lines:match("/skills") == nil, "dollar suggestions should not include slash commands")
end)

run("at input opens file mention suggestions", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)

  feed("i@READ<Esc>")
  vim.cmd("redraw")

  local command_buf
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
      command_buf = buf
      break
    end
  end

  assert_true(command_buf ~= nil, "mentions should reuse the suggestions buffer")
  local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
  assert_true(lines:match("@README.md") ~= nil, "file mention suggestions should use @")
  assert_true(lines:match("/resume") == nil, "mention suggestions should not include slash commands")
end)

run("enter completes best slash command candidate", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")
  local submitted

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(text)
    submitted = text
  end)

  feed("i/res<CR>")
  vim.cmd("redraw")

  assert_equal(submitted, "/resume", "enter should complete the best slash command candidate")
end)

run("slash exit closes chat without submitting", function()
  cleanup_omniac_buffers()
  package.loaded["omniac"] = nil
  package.loaded["omniac.ui"] = nil
  for _, name in ipairs({
    "Omniac",
    "OmniacConnect",
    "OmniacDisconnect",
    "OmniacExit",
    "OmniacSession",
    "OmniacSessionNew",
    "OmniacSessionLoad",
    "OmniacSessionResume",
    "OmniacAsk",
    "OmniacDebug",
    "OmniacAskFiles",
    "OmniacDiff",
    "OmniacDiffAccept",
    "OmniacDiffDeny",
  }) do
    pcall(vim.api.nvim_del_user_command, name)
  end

  local omniac = require("omniac")
  omniac.setup({
    backend = { kind = "codex" },
    agent = { cmd = { "codex" } },
    ui = { chat_width = 48 },
  })
  local submitted = false
  omniac.ask = function()
    submitted = true
  end

  omniac.open_chat()
  assert_true(has_window_for_buffer_name("omniac://input"), "input window should open")

  feed("i/exit<CR>")
  vim.cmd("redraw")

  assert_equal(submitted, false, "exit should not submit a prompt")
  assert_equal(has_window_for_buffer_name("omniac://input"), false, "input window should close")
  assert_equal(has_window_for_buffer_name("omniac"), false, "chat window should close")
end)

run("enter completes file mention without submitting", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")
  local submitted

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(text)
    submitted = text
  end)

  feed("i@READ<CR>")
  vim.cmd("redraw")

  local input_buf = vim.fn.bufnr("omniac://input")
  local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
  assert_true(lines:match("@README.md") ~= nil, "enter should complete the file mention in the input")
  assert_equal(submitted, nil, "enter completion should not submit file mentions")
end)

run("tab completes slash input without submitting", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")
  local submitted

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(text)
    submitted = text
  end)

  feed("i/res<Tab><Esc>")
  vim.cmd("redraw")

  local input_buf = vim.fn.bufnr("omniac://input")
  local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
  assert_true(lines:match("/resume") ~= nil, "tab should complete the slash command input text")
  assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "tab completion should keep input focused")
  assert_equal(submitted, nil, "tab completion should not submit")
end)

run("tab completes file mention input without submitting", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")
  local submitted

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(text)
    submitted = text
  end)

  feed("i@READ<Tab><Esc>")
  vim.cmd("redraw")

  local input_buf = vim.fn.bufnr("omniac://input")
  local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
  assert_true(lines:match("@README.md") ~= nil, "tab should complete the file mention input text")
  assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "tab completion should keep input focused")
  assert_equal(submitted, nil, "tab completion should not submit")
end)

run("tab completes dollar skill input without submitting", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")
  local submitted

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(text)
    submitted = text
  end)
  ui.set_available_commands({
    { name = "$imagegen", description = "Generate images" },
  })

  feed("i$im<Tab><Esc>")
  vim.cmd("redraw")

  local input_buf = vim.fn.bufnr("omniac://input")
  local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
  assert_true(lines:match("%$imagegen") ~= nil, "tab should complete the dollar skill input text")
  assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "tab completion should keep input focused")
  assert_equal(submitted, nil, "tab completion should not submit")
end)

run("enter completes and submits dollar skill", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")
  local submitted

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(text)
    submitted = text
  end)
  ui.set_available_commands({
    { name = "$imagegen", description = "Generate images" },
  })

  feed("i$im<CR>")
  vim.cmd("redraw")

  assert_equal(submitted, "$imagegen", "enter should complete and submit the dollar skill")
end)

run("esc cancels active turn once", function()
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
  feed("i<Esc><Esc><Esc>")
  vim.cmd("redraw")
  vim.wait(50, function()
    return cancels > 0
  end)

  assert_equal(cancels, 1, "esc should send one cancel request while working")
end)

run("cancel failure allows retry", function()
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

run("cancelled turn restores working activity on restart", function()
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

run("late cancelled completion from old turn is ignored", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function() end)

  ui.handle_notification({ method = "omniac/prompt_started", params = { turnId = 1 } }, { ui = { chat_width = 48 } })
  ui.handle_notification({ method = "omniac/prompt_cancelled", params = { turnId = 1 } }, { ui = { chat_width = 48 } })
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

run("cancel suppresses late current-turn tool output", function()
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
  feed("i<Esc>")
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

run("shift tab switches to chat without cycling session mode", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")
  local count = 0

  ui.set_mode_cycle_handler(function()
    count = count + 1
  end)
  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function() end)

  feed("i<S-Tab><Esc>")
  vim.cmd("redraw")

  assert_equal(count, 0, "shift-tab should not call the mode cycle handler")
  assert_equal(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "omniac", "shift-tab should focus chat")
end)

run("command suggestions do not drift input window", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)

  local input_win = vim.api.nvim_get_current_win()
  local initial_row = vim.api.nvim_win_get_position(input_win)[1]

  for _ = 1, 3 do
    feed("i/<Esc>")
    vim.cmd("redraw")
    feed("a<BS><Esc>")
    vim.cmd("redraw")
  end

  vim.wait(20)
  vim.cmd("redraw")
  assert_equal(vim.api.nvim_win_get_position(input_win)[1], initial_row, "input window row should not drift")
end)

run("shrinking command suggestions stay below input", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)
  ui.set_available_commands({
    { name = "alpha", description = "one" },
    { name = "alpine", description = "two" },
    { name = "apply", description = "three" },
    { name = "archive", description = "four" },
    { name = "banana", description = "five" },
  })

  local input_win = vim.api.nvim_get_current_win()
  local initial_row = vim.api.nvim_win_get_position(input_win)[1]

  feed("i/a<Esc>")
  vim.cmd("redraw")
  assert_equal(vim.api.nvim_win_get_position(input_win)[1], initial_row, "input row should stay while suggestions open")

  feed("arch<Esc>")
  vim.cmd("redraw")
  assert_equal(
    vim.api.nvim_win_get_position(input_win)[1],
    initial_row,
    "input row should stay when suggestions shrink"
  )
end)

run("omniac ui buffers are named and unlisted", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 42 },
  }, function(_) end)

  local expected = {
    ["omniac"] = false,
    ["omniac://input"] = false,
    ["omniac://activity"] = false,
    ["omniac://status"] = false,
  }

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local basename = vim.fn.fnamemodify(name, ":t")
    local key = expected[name] ~= nil and name or basename
    if expected[key] ~= nil then
      expected[key] = true
      assert_equal(vim.bo[buf].buflisted, false, key .. " should be hidden from buffer list")
    end
  end

  for name, seen in pairs(expected) do
    assert_true(seen, name .. " buffer should exist")
  end
end)

if failures > 0 then
  report(string.format("%d test(s) failed", failures))
  vim.cmd("cquit")
else
  report("all tests passed")
  vim.cmd("qa")
end
