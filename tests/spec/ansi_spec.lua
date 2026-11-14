local helpers = require("tests.helpers")
local ansi = require("omniac.ui.ansi")
local result = require("omniac.ui.chat.tool_result")
local esc = string.char(27)

local function definition(mark)
  return vim.api.nvim_get_hl(0, { name = mark.group, link = false })
end

local function colored_text(rendered)
  local chunks = {}
  for _, mark in ipairs(rendered.marks) do
    if mark.group:match("^OmniacAnsi_") then
      table.insert(chunks, rendered.lines[mark.line]:sub(mark.from + 1, mark.to))
    end
  end
  return chunks
end

describe("ANSI display", function()
  after_each(helpers.cleanup_after_test)

  it("decodes the SGR output seen in test logs and resets without leaking color", function()
    local plain, marks = ansi.parse(esc .. "[32mSuccess" .. esc .. "[0m | " .. esc .. "[31mFailed" .. esc .. "[m plain")
    assert.equals("Success | Failed plain", plain)
    assert.equals(2, #marks)
    assert.equals("Success", plain:sub(marks[1].from + 1, marks[1].to))
    assert.equals("Failed", plain:sub(marks[2].from + 1, marks[2].to))
    local expected = vim.g.terminal_color_2 or "#00cd00"
    assert.equals(tonumber(expected:sub(2), 16), definition(marks[1]).fg)
  end)

  it("supports bright, indexed and RGB colors with independently reset attributes", function()
    local plain, marks =
      ansi.parse(esc .. "[1;3;4;91mA" .. esc .. "[22;23;24;38;5;196;48;2;1;2;3mB" .. esc .. "[39;49mC")
    assert.equals("ABC", plain)
    local first, second, third = definition(marks[1]), definition(marks[2]), definition(marks[3])
    assert.is_true(first.bold)
    assert.is_true(first.italic)
    assert.is_true(first.underline)
    assert.equals(0xff0000, second.fg)
    assert.equals(0x010203, second.bg)
    assert.is_not_true(second.bold)
    assert.is_not_true(second.italic)
    assert.is_not_true(second.underline)
    assert.is_nil(third.fg)
    assert.is_nil(third.bg)
  end)

  it("removes cursor and OSC controls while preserving hyperlink labels and ordinary brackets", function()
    local value = esc
      .. "]0;window title\7"
      .. esc
      .. "[?25l"
      .. esc
      .. "[2K"
      .. esc
      .. "]8;;https://example.com"
      .. esc
      .. "\\label"
      .. esc
      .. "]8;;\7"
      .. esc
      .. "[?25h\r\n[32m] literal "
      .. esc
      .. "(Bdone"
    local plain = ansi.parse(value)
    assert.equals("label\n[32m] literal done", plain)
    assert.equals("partial", ansi.parse("partial" .. esc .. "[38;"))
    assert.equals("partial", ansi.parse("partial" .. esc .. "]8;;unfinished"))
  end)

  it("keeps colors aligned through Korean wrapping, newlines and folded output tails", function()
    local message = {
      kind = "execute",
      status = "completed",
      command = "./test.sh",
      title = esc .. "[36m검증" .. esc .. "[0m",
      output = esc .. "[32m가나다라마바\nsecond\nthird\nlast" .. esc .. "[0m!",
      output_preview_lines = 2,
    }
    for _, width in ipairs({ 12, 30 }) do
      local rendered = result.render(message, width)
      assert.is_nil(table.concat(rendered.lines):find(esc, 1, true))
      local colored = colored_text(rendered)
      assert.equals("검증", colored[1])
      assert.equals("last", colored[#colored])
      for _, mark in ipairs(rendered.marks) do
        if mark.group:match("^OmniacAnsi_") then
          assert.is_true(mark.from >= 2)
          assert.is_true(mark.to <= #rendered.lines[mark.line] - 2)
        end
      end
      message.expanded = true
      local expanded = result.render(message, width)
      assert.is_truthy(table.concat(colored_text(expanded)):find("가나다라마바", 1, true))
      assert.is_nil(table.concat(expanded.lines):find(esc, 1, true))
      message.expanded = false
    end
  end)

  it("maps styles across blank rows and resets before the next message", function()
    local lines, marks = ansi.wrapped(esc .. "[32m가나다라\n\n끝" .. esc .. "[0m", 4)
    assert.same({ "가나", "다라", "", "끝" }, lines)
    assert.same({ "가나", "다라", "끝" }, colored_text({ lines = lines, marks = marks }))
    local _, next_marks = ansi.parse("plain")
    assert.same({}, next_marks)
    local clipped = result.render({
      title = "abcdefgh" .. esc .. "[31mi" .. esc .. "[0mjklmnop",
      output = "plain",
    }, 10)
    assert.same({}, colored_text(clipped), "color from hidden title text must not land inside the ellipsis")
  end)

  it("recreates generated highlight definitions after a colorscheme change", function()
    local _, marks = ansi.parse(esc .. "[38;2;11;22;33mcolored")
    vim.api.nvim_set_hl(0, marks[1].group, {})
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    assert.equals(0x0b1621, definition(marks[1]).fg)
  end)

  it("renders ACP terminal chunks as actual buffer colors after expansion and resize", function()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 60 } }
    local state = ui.open(config, function() end)
    local client = require("omniac.backend.acp").new({})
    client.session_id = "session"
    client.active_turn_id = 7
    client:on_notification(function(message)
      ui.handle_notification(message, config)
    end)
    ui.handle_notification({ method = "omniac/prompt_started", params = { turnId = 7 } }, config)
    local function update(value)
      client:_handle_notification({ method = "session/update", params = { sessionId = "session", update = value } })
    end
    update({
      sessionUpdate = "tool_call",
      toolCallId = "test",
      kind = "execute",
      status = "in_progress",
      title = "Tests",
      rawInput = { command = "./test.sh" },
    })
    update({
      sessionUpdate = "tool_call_update",
      toolCallId = "test",
      _meta = { terminal_output_delta = { data = esc .. "[3" } },
    })
    update({
      sessionUpdate = "tool_call_update",
      toolCallId = "test",
      _meta = {
        terminal_output_delta = {
          data = "2mSuccess" .. esc .. "[0m\n2\n3\n4\n5\n" .. esc .. "[31mFailed" .. esc .. "[0m",
        },
      },
    })
    update({ sessionUpdate = "tool_call_update", toolCallId = "test", status = "completed" })
    vim.wait(50, function()
      return false
    end)
    local raw = state.messages[#state.messages].output
    assert.is_truthy(raw:find(esc .. "[32mSuccess", 1, true))
    local function check()
      local lines = vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)
      assert.is_nil(table.concat(lines):find(esc, 1, true))
      local found = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.chat_buf, -1, 0, -1, { details = true })) do
        local details = mark[4]
        if (details.hl_group or ""):match("^OmniacAnsi_") then
          found[lines[mark[2] + 1]:sub(mark[3] + 1, details.end_col)] = true
        end
      end
      assert.is_true(found.Success)
      assert.is_true(found.Failed)
    end
    check()
    helpers.feed("<C-t>")
    check()
    ui.resize(42)
    check()
  end)

  it("decodes split assistant escape sequences and colored activity titles", function()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 60 } }
    local state = ui.open(config, function() end)
    local function send(method, params)
      ui.handle_notification({ method = "omniac/" .. method, params = params or {} }, config)
    end
    send("prompt_started", { turnId = 7 })
    send("tool_activity", { title = esc .. "[32m검증 중" .. esc .. "[0m", kind = "execute", status = "in_progress" })
    local activity = table.concat(vim.api.nvim_buf_get_lines(state.activity_buf, 0, -1, false))
    assert.is_nil(activity:find(esc, 1, true))
    assert.is_truthy(activity:find("검증 중", 1, true))
    local activity_colored = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.activity_buf, -1, 0, -1, { details = true })) do
      local details = mark[4]
      if (details.hl_group or ""):match("^OmniacAnsi_") then
        table.insert(activity_colored, activity:sub(mark[3] + 1, details.end_col))
      end
    end
    assert.same({ "검증 중" }, activity_colored)
    send("response_chunk", { turnId = 7, text = "Result " .. esc .. "[3" })
    vim.wait(40, function()
      return false
    end)
    assert.is_nil(table.concat(vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)):find("[3", 1, true))
    send("response_chunk", { turnId = 7, text = "2m성공\n계속" .. esc .. "[0m plain" })
    send("response_completed", { turnId = 7 })
    local lines = vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)
    assert.is_nil(table.concat(lines):find(esc, 1, true))
    local colored = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.chat_buf, -1, 0, -1, { details = true })) do
      local details = mark[4]
      if (details.hl_group or ""):match("^OmniacAnsi_") then
        table.insert(colored, lines[mark[2] + 1]:sub(mark[3] + 1, details.end_col))
      end
    end
    assert.same({ "성공", "계속" }, colored)
  end)
end)
