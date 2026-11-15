local helpers = require("tests.helpers")

describe("Omniac window appearance", function()
  local saved
  local source_win
  local source_options
  local option_names = { "laststatus", "statusline", "fillchars", "cursorline", "cursorcolumn", "colorcolumn", "spell" }

  before_each(function()
    saved = {}
    for _, name in ipairs(option_names) do
      saved[name] = vim.o[name]
    end
    source_win = vim.api.nvim_get_current_win()
    source_options = {}
    for _, name in ipairs({ "statusline", "fillchars", "winhighlight", "cursorline", "colorcolumn" }) do
      source_options[name] = vim.wo[source_win][name]
    end
    package.loaded["omniac.ui"] = nil
  end)

  after_each(function()
    helpers.cleanup_after_test()
    for name, value in pairs(saved) do
      vim.o[name] = value
    end
    for name, value in pairs(source_options) do
      vim.wo[source_win][name] = value
    end
  end)

  for _, laststatus in ipairs({ 2, 3 }) do
    it("hides editor chrome with laststatus=" .. laststatus .. " without changing the source window", function()
      vim.o.laststatus = laststatus
      vim.go.statusline = "Global status"
      vim.wo[source_win].statusline = "source %f %l,%c"
      vim.wo[source_win].cursorline = true
      vim.wo[source_win].colorcolumn = "12"
      vim.wo[source_win].fillchars = "eob:~,stl:=,stlnc:-"
      local ui = require("omniac.ui")
      local state = ui.open({ ui = { chat_width = 48, mascot_motion = false } }, function() end)
      assert.is_true(ui.restore_input("/"))
      assert.is_true(vim.api.nvim_win_is_valid(state.command_win))

      for _, name in ipairs({ "card_win", "chat_win", "activity_win", "input_win", "status_win", "command_win" }) do
        local win = state[name]
        if win then
          local line = vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win }).str
          if laststatus == 3 then
            assert.are.equal("Global status", line, name .. " must preserve the global statusline")
            assert.is_nil(vim.wo[win].winhighlight:find("StatusLine:", 1, true))
          else
            assert.is_nil(line:find("%S"), name .. " must not display a filename or ruler")
          end
          assert.is_false(vim.wo[win].cursorline, name)
          assert.are.equal("", vim.wo[win].colorcolumn, name)
          vim.api.nvim_win_call(win, function()
            local fill = vim.opt_local.fillchars:get()
            assert.are.equal(" ", fill.eob, name .. " must not display end-of-buffer tildes")
            assert.are.equal(" ", fill.stl, name)
            assert.are.equal(" ", fill.stlnc, name)
          end)
        end
      end

      ui.close()
      assert.are.equal(laststatus, vim.o.laststatus)
      assert.are.equal("source %f %l,%c", vim.wo[source_win].statusline)
      assert.are.equal("12", vim.wo[source_win].colorcolumn)
      assert.is_true(vim.wo[source_win].cursorline)
      assert.are.equal("eob:~,stl:=,stlnc:-", vim.wo[source_win].fillchars)
    end)
  end

  it("updates internal statuslines when laststatus changes while open", function()
    vim.o.laststatus = 2
    local ui = require("omniac.ui")
    local state = ui.open({ ui = { mascot_motion = false } }, function() end)
    for _, value in ipairs({ 3, 2 }) do
      vim.o.laststatus = value
      vim.api.nvim_exec_autocmds("OptionSet", { pattern = "laststatus" })
      for _, name in ipairs({ "chat_win", "activity_win", "input_win", "status_win" }) do
        local local_value = vim.api.nvim_get_option_value("statusline", { win = state[name], scope = "local" })
        assert.are.equal(value == 3 and "" or " ", local_value)
      end
    end
  end)

  it("restores theme highlights when the colorscheme changes while open", function()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local ui = require("omniac.ui")
    ui.open({ ui = { mascot_motion = false } }, function() end)
    local ok, err = pcall(function()
      for _, background in ipairs({ 0x181818, 0xf0f0f0 }) do
        vim.api.nvim_set_hl(0, "Normal", { fg = 0x888888, bg = background })
        vim.api.nvim_set_hl(0, "OmniacNormal", {})
        vim.api.nvim_set_hl(0, "OmniacBorder", {})
        vim.api.nvim_exec_autocmds("ColorScheme", {})
        assert.are.equal(background, vim.api.nvim_get_hl(0, { name = "OmniacNormal", link = false }).bg)
        assert.are.equal(background, vim.api.nvim_get_hl(0, { name = "OmniacSeparator", link = false }).bg)
        assert.are.equal(0xf38ba8, vim.api.nvim_get_hl(0, { name = "OmniacBorder", link = false }).fg)
      end
      vim.api.nvim_set_hl(0, "Normal", { fg = 0x888888 })
      vim.api.nvim_exec_autocmds("ColorScheme", {})
      assert.is_nil(vim.api.nvim_get_hl(0, { name = "OmniacNormal", link = false }).bg)
      assert.is_nil(vim.api.nvim_get_hl(0, { name = "OmniacSeparator", link = false }).bg)
    end)
    vim.api.nvim_set_hl(0, "Normal", normal)
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    if not ok then
      error(err)
    end
  end)
end)
