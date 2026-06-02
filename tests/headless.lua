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
    fail(string.format("%s: expected %s, got %s", message or "assert_equal", vim.inspect(expected), vim.inspect(actual)))
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

if failures > 0 then
  report(string.format("%d test(s) failed", failures))
  vim.cmd("cquit")
else
  report("all tests passed")
  vim.cmd("qa")
end
