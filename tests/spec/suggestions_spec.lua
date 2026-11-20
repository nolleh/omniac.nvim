local helpers = require("tests.helpers")

describe("omniac.nvim suggestion navigation", function()
  local ui, state, submitted, queued, fixture, cwd

  before_each(function()
    helpers.cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    ui = require("omniac.ui")
    submitted, queued = nil, nil
    state = ui.open({ ui = { chat_width = 60 } }, function(value)
      submitted = value
    end, function(value)
      queued = value
    end)
    fixture = vim.fn.tempname()
    vim.fn.mkdir(fixture, "p")
    cwd = vim.fn.getcwd()
    vim.cmd.lcd(vim.fn.fnameescape(fixture))
    local commands = {}
    for index = 1, 7 do
      local name = "nav" .. index
      table.insert(commands, { name = name })
      table.insert(commands, { name = "$" .. name })
      vim.fn.writefile({}, fixture .. "/" .. name)
    end
    ui.set_available_commands(commands)
    vim.v.errmsg = ""
  end)

  after_each(function()
    helpers.cleanup_after_test()
    vim.cmd.lcd(vim.fn.fnameescape(cwd))
    vim.fn.delete(fixture, "rf")
  end)

  local function selected_line()
    local namespace = vim.api.nvim_get_namespaces()["omniac.ui"]
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.command_buf, namespace, 0, -1, { details = true })) do
      if mark[4].line_hl_group == "OmniacCommandSelected" then
        return vim.api.nvim_buf_get_lines(state.command_buf, mark[2], mark[2] + 1, false)[1]
      end
    end
  end

  for _, trigger in ipairs({ "/", "$", "@" }) do
    it("navigates, scrolls, wraps, and accepts " .. trigger .. " suggestions", function()
      local prefix = trigger .. "nav"
      helpers.feed("i" .. prefix .. "<C-n><Esc>")
      assert.is_truthy(selected_line():find("nav2", 1, true))
      assert.equals("omniac://input", vim.api.nvim_buf_get_name(0))
      assert.is_nil(submitted)

      helpers.feed("a<C-p><C-p><Esc>")
      assert.is_truthy(selected_line():find("nav7", 1, true), "previous should wrap and scroll to the last candidate")
      assert.equals(5, vim.api.nvim_buf_line_count(state.command_buf))

      helpers.feed("a<C-n><C-n><CR><Esc>")
      local expected = prefix .. "2"
      if trigger == "@" then
        assert.is_nil(submitted, "Enter should complete a path without submitting")
        assert.is_truthy(
          table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"):find(expected, 1, true)
        )
      else
        assert.equals(expected, submitted, "Enter should submit the selected candidate")
      end
      assert.equals("", vim.v.errmsg)
    end)
  end

  it("Tab completes the selected candidate without queuing it", function()
    helpers.feed("i$nav<C-n><Tab>")
    assert.is_true(vim.wait(200, function()
      return table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"):find("$nav2", 1, true) ~= nil
    end))
    assert.is_nil(queued)
    assert.is_nil(submitted)
    assert.equals("", vim.v.errmsg)
  end)

  it("resets selection when the draft or advertised candidates change", function()
    helpers.feed("i$nav<C-n><C-n><Esc>")
    helpers.feed("a1<Esc>")
    assert.is_truthy(selected_line():find("$nav1", 1, true))
    helpers.feed("a<BS><C-n><Esc>")
    assert.is_truthy(selected_line():find("$nav2", 1, true))
    ui.set_available_commands({ { name = "$nav4" } })
    assert.is_truthy(selected_line():find("$nav4", 1, true))
    helpers.feed("a<CR>")
    assert.equals("$nav4", submitted)
  end)

  it("navigation without suggestions preserves the draft", function()
    helpers.feed("iordinary draft<C-n><C-p><CR>")
    assert.equals("ordinary draft", submitted)
    assert.equals("", vim.v.errmsg)
  end)

  it("preserves selection when submission trims leading spaces", function()
    helpers.feed("i  $nav<C-n><CR>")
    assert.equals("$nav2", submitted)
  end)
end)
