local helpers = require("tests.helpers")
local result = require("omniac.ui.chat.tool_result")

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
    assert.are.same({ "first", "second", "third", "fourth" }, section(rendered, "OmniacToolCommand"))
    assert.are.same({ "PASS" }, section(rendered, "OmniacToolOutput"))
    assert.is_truthy(table.concat(section(rendered, "OmniacToolSummary")):find("Verify turn isolation", 1, true))
    assert.is_truthy(table.concat(rendered.lines):find("+2 lines", 1, true))
    assert.is_true(result.can_expand(message, 60))

    message.expanded = true
    rendered = result.render(message, 60)
    assert.are.same({ "first", "second", "third", "fourth", "fifth", "sixth" }, section(rendered, "OmniacToolCommand"))
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
      assert.are.equal(4, #section(rendered, "OmniacToolCommand"))
      assert.are.equal(4, #section(rendered, "OmniacToolOutput"))
      for _, line in ipairs(rendered.lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= width, "preview rows should fit the viewport")
      end
      assert.is_true(result.can_expand(message, width))
    end
  end)

  it("does not duplicate a raw command title as a summary", function()
    local command = "cat > /tmp/check.lua <<'LUA'\nlocal value = 1\nLUA\nnvim -l /tmp/check.lua"
    for _, title in ipairs({ command, "cat > /tmp/check.lua <<'LUA'" }) do
      local rendered = result.render({ kind = "execute", title = title, command = command, output = "PASS" }, 60)
      assert.are.same({ "✓ Command execution" }, section(rendered, "OmniacToolSummary"))
      assert.are.equal(4, #section(rendered, "OmniacToolCommand"))
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
    assert.are.same({
      {
        from = state.chat_render_cache.ranges[1].from,
        to = state.chat_render_cache.ranges[1].to - 1,
      },
    }, state.chat_render_cache.excluded)
    helpers.feed("<C-t>")
    assert.are.same(before, vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false))
  end)
end)
