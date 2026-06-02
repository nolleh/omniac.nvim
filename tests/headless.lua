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
