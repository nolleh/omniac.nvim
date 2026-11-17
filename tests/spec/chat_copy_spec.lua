local helpers = require("tests.helpers")
local text = require("omniac.ui.text")

describe("chat source copying", function()
  local ui, state, config, registers, selection

  before_each(function()
    registers = {}
    for _, name in ipairs({ "z", "0", '"' }) do
      registers[name] = vim.fn.getreginfo(name)
    end
    selection = vim.o.selection
    vim.o.selection = "inclusive"
    package.loaded["omniac.ui"] = nil
    ui = require("omniac.ui")
    config = { ui = { chat_width = 48, mascot_motion = false } }
    state = ui.open(config, function() end)
  end)

  after_each(function()
    helpers.cleanup_after_test()
    vim.o.selection = selection
    for _, name in ipairs({ "z", "0", '"' }) do
      vim.fn.setreg(name, registers[name])
    end
  end)

  local function row_of(value)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)) do
      if line == value then
        return row
      end
    end
    error("missing unmodified source line: " .. value)
  end

  local function assert_copy(source)
    local source_lines = text.split_lines(source)
    local first = row_of(source_lines[1])
    local last = first + #source_lines - 1
    assert.are.same(source_lines, vim.api.nvim_buf_get_lines(state.chat_buf, first - 1, last, false))
    vim.api.nvim_win_call(state.chat_win, function()
      vim.cmd("stopinsert")
      -- Ordinary linewise yank, with no plugin copy handler or trimming.
      vim.cmd(string.format("%d,%dyank z", first, last))
      assert.are.same(source_lines, vim.fn.getreg("z", 1, true))
      -- Characterwise Visual selection must preserve real whitespace too.
      vim.cmd(string.format("normal! %dG0v", first))
      vim.api.nvim_win_set_cursor(state.chat_win, { last, math.max(0, #source_lines[#source_lines] - 1) })
      vim.cmd('normal! "zy')
      assert.are.equal(source, vim.fn.getreg("z"))
    end)
  end

  for _, role in ipairs({ "You", "Omniac" }) do
    it("copies " .. role .. " text with indentation, tabs, Unicode and long lines across resizes", function()
      local source = "  leading spaces stay  \n\t탭과 한글 👩‍💻 é\n\n"
        .. string.rep("long line with spaces ", 30)
        .. "end"
      ui.add_message(role, source, config)
      for _, width in ipairs({ 42, 60, 48 }) do
        ui.resize(width)
        assert_copy(source)
      end
    end)
  end

  it("preserves trailing blank lines and whitespace-only lines in linewise copies", function()
    local source = "first line\n\n  \n\n"
    for _, role in ipairs({ "You", "Omniac" }) do
      ui.clear_conversation()
      ui.add_message(role, source, config)
      local lines = text.split_lines(source)
      assert.are.same(lines, vim.api.nvim_buf_get_lines(state.chat_buf, 0, #lines, false))
      vim.api.nvim_win_call(state.chat_win, function()
        vim.cmd(string.format("1,%dyank z", #lines))
      end)
      assert.are.equal(source, vim.fn.getreg("z"))
    end
  end)

  it("copies Markdown structure and fenced code without changing syntax or string literals", function()
    local source = "# Heading\n\n- first item\n  - nested item\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n"
      .. "```python\ndef example():\n\treturn '"
      .. string.rep("literal ", 40)
      .. "'  \n\n```\n> quotation"
    ui.add_message("Omniac", source, config)
    assert_copy(source)
    ui.resize(42)
    assert_copy(source)
  end)

  it("keeps previously rendered messages copyable while streaming, finishing and reopening", function()
    local earlier = "First answer " .. string.rep("stable ", 30)
    local streamed = "Streaming answer " .. string.rep("내용 ", 40) .. "\n\tindented tail  "
    ui.add_message("Omniac", earlier, config)
    for _, chunk in ipairs({ streamed:sub(1, 12), streamed:sub(13) }) do
      ui.handle_notification({ method = "omniac/response_chunk", params = { text = chunk } }, config)
    end
    assert.is_true(vim.wait(500, function()
      return table.concat(vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false), "\n"):find("indented tail", 1, true)
        ~= nil
    end))
    assert_copy(earlier)
    assert_copy(streamed)
    ui.handle_notification({ method = "omniac/response_completed", params = {} }, config)
    ui.resize(42)
    ui.open(config, function() end)
    assert_copy(earlier)
    assert_copy(streamed)
  end)

  it("copies readable ANSI text with correct byte highlights and no UI spaces", function()
    local esc = string.char(27)
    local colored = "초록 " .. string.rep("long ", 25)
    local source = "prefix " .. colored .. "\n\tplain tail  "
    ui.add_message("Omniac", "prefix " .. esc .. "[32m" .. colored .. esc .. "[0m\n\tplain tail  ", config)
    assert_copy(source)
    local lines = vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)
    local found = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.chat_buf, -1, 0, -1, { details = true })) do
      if (mark[4].hl_group or ""):match("^OmniacAnsi_") then
        assert.are.equal(colored, lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col))
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("copies expanded shell heredocs and output without inserting display newlines", function()
    local command = "cat <<'COPY_EOF'\n\t" .. string.rep("literal argument ", 30) .. "  \n\nCOPY_EOF"
    local output = "output " .. string.rep("가나다 ", 40) .. "\n  indented output  \n\nlast output"
    ui.add_tool_result({ kind = "execute", title = "Copy source", command = command, output = output }, config)
    helpers.feed("<C-t>")
    assert_copy(command)
    assert_copy(output)
    ui.resize(42)
    assert_copy(command)
    assert_copy(output)
    helpers.feed("<C-t>")
    helpers.feed("<C-t>")
    assert_copy(command)
    assert_copy(output)
  end)

  it("keeps real and wrapped first characters aligned with visual padding", function()
    local source = string.rep("x", 100)
    ui.add_message("Omniac", source, config)
    local row = row_of(source)
    for _, width in ipairs({ 42, 60 }) do
      ui.resize(width)
      vim.api.nvim_win_call(state.chat_win, function()
        vim.api.nvim_win_set_cursor(state.chat_win, { row, 0 })
        vim.cmd("normal! zt")
      end)
      vim.cmd("redraw")
      local first = vim.fn.screenpos(state.chat_win, row, 1)
      local continuation = vim.fn.screenpos(state.chat_win, row, width - 1)
      assert.are.equal(vim.fn.win_screenpos(state.chat_win)[2] + 2, first.curscol)
      assert.are.equal(first.row + 1, continuation.row)
      assert.are.equal(first.curscol, continuation.curscol)
      assert_copy(source)
    end
  end)
end)
