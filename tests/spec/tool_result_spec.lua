local helpers = require("tests.helpers")
local result = require("omniac.ui.chat.tool_result")

local function command_lines(rendered)
  local range = rendered.command_range
  local result_lines = {}
  for index = range.from + 1, range.to do
    table.insert(result_lines, rendered.lines[index]:sub(3))
  end
  return result_lines
end

local function section(rendered, group)
  local lines = {}
  for _, mark in ipairs(rendered.marks) do
    if mark.group == group then
      local value = rendered.lines[mark.line]:sub(3):gsub("%s+$", "")
      table.insert(lines, value)
    end
  end
  return lines
end

describe("tool result previews", function()
  after_each(helpers.cleanup_after_test)

  it("shows the agent's task title in a different highlight above four command rows", function()
    local message = {
      kind = "execute",
      title = "Verify turn isolation",
      command = "first\nsecond\nthird\nfourth\nfifth\nsixth",
      output = "PASS",
      status = "completed",
      exitCode = 0,
    }
    local rendered = result.render(message, 60)
    assert.are.same({ "first", "second", "third", "fourth" }, command_lines(rendered))
    assert.are.same({ "PASS" }, section(rendered, "OmniacToolOutput"))
    assert.is_truthy(table.concat(section(rendered, "OmniacToolSummary")):find("Verify turn isolation", 1, true))
    assert.is_truthy(table.concat(rendered.lines):find("+2 lines", 1, true))
    assert.is_true(result.can_expand(message, 60))

    message.expanded = true
    rendered = result.render(message, 60)
    assert.are.same({ "first", "second", "third", "fourth", "fifth", "sixth" }, command_lines(rendered))
    assert.is_truthy(table.concat(rendered.lines):find("Ctrl-T to collapse", 1, true))
  end)

  it("limits long single-line commands and output by display rows at the current width", function()
    local message = {
      kind = "execute",
      command = string.rep("명령", 80),
      output = string.rep("result", 70),
      status = "completed",
    }
    for _, width in ipairs({ 30, 60 }) do
      local rendered = result.render(message, width)
      local command_rows = 0
      for _, line in ipairs(command_lines(rendered)) do
        command_rows = command_rows + math.ceil(vim.fn.strdisplaywidth(line) / (width - 4))
      end
      assert.are.equal(4, command_rows)
      assert.are.equal(4, #section(rendered, "OmniacToolOutput"))
      for index, line in ipairs(rendered.lines) do
        local range = rendered.command_range
        if index <= range.from or index > range.to then
          assert.is_true(vim.fn.strdisplaywidth(line) <= width, "non-command rows should fit the viewport")
        end
      end
      assert.is_true(result.can_expand(message, width))
    end
  end)

  it("does not duplicate a raw command title as a summary", function()
    local command = "cat > /tmp/check.lua <<'LUA'\nlocal value = 1\nLUA\nnvim -l /tmp/check.lua"
    for _, title in ipairs({ command, "cat > /tmp/check.lua <<'LUA'" }) do
      local rendered = result.render({ kind = "execute", title = title, command = command, output = "PASS" }, 60)
      assert.are.same({ "✓ Command execution" }, section(rendered, "OmniacToolSummary"))
      assert.are.equal(4, #command_lines(rendered))
    end
  end)

  it("respects the output preview limit and keeps failure status visible while folded", function()
    local message = {
      status = "failed",
      title = "Run tests",
      command = "./test.sh",
      exitCode = 1,
      output = "one\ntwo\nthree\nfour\nfive",
      output_preview_lines = 2,
    }
    local rendered = result.render(message, 60)
    assert.are.same({ "one", "five" }, section(rendered, "OmniacToolOutput"))
    assert.are.same({ "✗ Run tests (exit 1)" }, section(rendered, "OmniacError"))
    message.expanded = true
    assert.are.same({ "one", "two", "three", "four", "five" }, section(result.render(message, 60), "OmniacToolOutput"))
  end)

  it("uses a sh fence without rewriting shell source or interpreting output as Markdown", function()
    local command = "printf '%s' '" .. string.rep("long argument ", 12) .. "' \\\n  | cat <<'EOF'\n```literal\nEOF"
    local rendered = result.render({
      kind = "execute",
      command = command,
      output = "```bash\n# literal output\n```",
      expanded = true,
    }, 42)
    assert.are.equal(command, table.concat(command_lines(rendered), "\n"))
    local region = rendered.command_markdown
    assert.are.equal("  ````sh", rendered.lines[region.from + 1])
    assert.are.equal("  ````", rendered.lines[region.to])
    assert.is_truthy(table.concat(section(rendered, "OmniacToolOutput")):find("# literal output", 1, true))
    for _, mark in ipairs(rendered.marks) do
      assert.is_true(
        mark.line <= rendered.command_range.from or mark.line > rendered.command_range.to,
        "shell highlighting must come from the Bash parser rather than a uniform command color"
      )
    end
  end)

  it("keeps soft-wrapped command continuations inside the chat padding", function()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 60 } }
    local state = ui.open(config, function() end)
    local command = "printf '%s' '" .. string.rep("argument ", 30) .. "'"
    ui.add_tool_result({ kind = "execute", command = command, output = "PASS" }, config)
    helpers.feed("<C-t>")
    local lines = vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)
    local command_row
    for row, line in ipairs(lines) do
      if line == "  " .. command then
        command_row = row
        break
      end
    end
    assert.is_not_nil(command_row, "the command source must stay intact")
    for _, width in ipairs({ 42, 60 }) do
      vim.api.nvim_win_set_width(state.chat_win, width)
      vim.api.nvim_win_call(state.chat_win, function()
        vim.api.nvim_win_set_cursor(state.chat_win, { command_row, 0 })
        vim.cmd("normal! zt")
      end)
      vim.cmd("redraw")
      local first = vim.fn.screenpos(state.chat_win, command_row, 3)
      local continuation = vim.fn.screenpos(state.chat_win, command_row, width + 1)
      assert.are.equal(first.row + 1, continuation.row)
      assert.are.equal(first.col, continuation.col, "wrapped commands should retain the two-space left padding")
    end
  end)

  it("toggles a long command with short output and preserves literal script syntax", function()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 60 } }
    local state = ui.open(config, function() end)
    ui.add_tool_result({
      kind = "execute",
      status = "completed",
      title = "Check literal script",
      command = "first\nsecond\nthird\nfourth\n[Image 1]\n```lua\nprint('last')",
      output = "PASS",
      exitCode = 0,
    }, config)
    local before = vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)
    assert.is_nil(table.concat(before):find("print('last')", 1, true))
    helpers.feed("<C-t>")
    local expanded = table.concat(vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false), "\n")
    assert.is_truthy(expanded:find("print('last')", 1, true))
    assert.is_truthy(expanded:find("[Image 1]", 1, true))
    assert.is_truthy(expanded:find("Ctrl-T to collapse", 1, true))
    local excluded = state.chat_render_cache.excluded
    assert.are.equal(2, #excluded, "only the fenced command should participate in Markdown parsing")
    local code = table.concat(vim.api.nvim_buf_get_lines(state.chat_buf, excluded[1].to, excluded[2].from, false), "\n")
    assert.is_truthy(code:find("````sh", 1, true), "the outer fence must contain literal triple backticks safely")
    assert.is_truthy(code:find("```lua", 1, true))
    assert.is_nil(code:find("Output", 1, true))
    helpers.feed("<C-t>")
    assert.are.same(before, vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false))
  end)
end)
