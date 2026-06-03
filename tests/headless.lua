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

run("input focus returns to end of wrapped message", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 42 },
  }, function(_) end)

  vim.api.nvim_feedkeys(string.rep("a", 80), "xt", false)
  vim.cmd("stopinsert")
  vim.cmd("wincmd p")
  vim.api.nvim_feedkeys("i", "xt", false)
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
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i><Esc>", true, false, true), "xt", false)
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
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ix<Esc>", true, false, true), "xt", false)
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
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i" .. text .. "<Esc>", true, false, true), "xt", false)
  vim.cmd("redraw")

  assert_equal(vim.api.nvim_win_get_height(0), 7, "input window should grow with input lines")

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<BS><BS><BS><BS><Esc>", true, false, true), "xt", false)
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

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i/<Esc>", true, false, true), "xt", false)
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
  assert_true(lines:match("/resume") ~= nil, "local resume command should be listed")
  assert_true(lines:match("/plan") ~= nil, "agent command should be listed")
  assert_true(lines:match("@README") == nil, "slash suggestions should not include file mentions")

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("a<BS>hello<Esc>", true, false, true), "xt", false)
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

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i/com<Esc>", true, false, true), "xt", false)
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

run("at input opens file mention suggestions", function()
  cleanup_omniac_buffers()
  package.loaded["omniac.ui"] = nil
  local ui = require("omniac.ui")

  ui.open({
    agent = { cmd = { "codex-acp" } },
    ui = { chat_width = 48 },
  }, function(_) end)

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i@READ<Esc>", true, false, true), "xt", false)
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

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i/res<CR>", true, false, true), "xt", false)
  vim.cmd("redraw")

  assert_equal(submitted, "/resume", "enter should complete the best slash command candidate")
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

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i@READ<CR>", true, false, true), "xt", false)
  vim.cmd("redraw")

  local input_buf = vim.fn.bufnr("omniac://input")
  local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
  assert_true(lines:match("@README.md") ~= nil, "enter should complete the file mention in the input")
  assert_equal(submitted, nil, "enter completion should not submit file mentions")
end)

run("tab completes slash command without submitting", function()
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

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i/res<Tab><Esc>", true, false, true), "xt", false)
  vim.cmd("redraw")

  local input_buf = vim.fn.bufnr("omniac://input")
  local lines
  vim.wait(50, function()
    lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
    return lines:match("/resume") ~= nil
  end)
  assert_true(lines:match("/resume") ~= nil, "tab should complete the slash command in the input")
  assert_equal(submitted, nil, "tab completion should not submit")
end)

run("tab completes file mention without submitting", function()
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

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i@READ<Tab><Esc>", true, false, true), "xt", false)
  vim.cmd("redraw")

  local input_buf = vim.fn.bufnr("omniac://input")
  local lines
  vim.wait(50, function()
    lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
    return lines:match("@README.md") ~= nil
  end)
  assert_true(lines:match("@README.md") ~= nil, "tab should complete the file mention in the input")
  assert_equal(submitted, nil, "tab completion should not submit")
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
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i/<Esc>", true, false, true), "xt", false)
    vim.cmd("redraw")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("a<BS><Esc>", true, false, true), "xt", false)
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

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i/a<Esc>", true, false, true), "xt", false)
  vim.cmd("redraw")
  assert_equal(vim.api.nvim_win_get_position(input_win)[1], initial_row, "input row should stay while suggestions open")

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("arch<Esc>", true, false, true), "xt", false)
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
