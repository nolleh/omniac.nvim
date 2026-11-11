local helpers = require("tests.helpers")
local layout = require("omniac.ui.layout")

describe("omniac.nvim sidebar width", function()
  local columns

  before_each(function()
    columns = vim.o.columns
    vim.o.columns = 200
    package.loaded["omniac.ui"] = nil
  end)

  after_each(function()
    helpers.cleanup_after_test()
    vim.o.columns = columns
  end)

  local function assert_sidebar_width(state, expected)
    for _, name in ipairs({ "chat_win", "activity_win", "input_win", "status_win", "card_win" }) do
      local win = state[name]
      if win and vim.api.nvim_win_is_valid(win) then
        assert.are.equal(expected, vim.api.nvim_win_get_width(win), name .. " width")
      end
    end
  end

  local function resize_screen(state, size, expected)
    vim.o.columns = size
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.is_true(
      vim.wait(1000, function()
        return vim.api.nvim_win_get_width(state.chat_win) == expected
      end),
      "sidebar should follow the screen width"
    )
    assert_sidebar_width(state, expected)
  end

  it("resolves column counts, ratios, percentages, and size limits", function()
    assert.are.equal(72, layout.resolve_width(72))
    assert.are.equal(72, layout.resolve_width("72"))
    assert.are.equal(70, layout.resolve_width(0.35))
    assert.are.equal(70, layout.resolve_width("35%"))
    assert.are.equal(67, layout.resolve_width("33.75%"))
    assert.are.equal(42, layout.resolve_width("1%"))
    assert.are.equal(180, layout.resolve_width("100%"))
    assert.are.equal(180, layout.resolve_width(300))
    for _, value in ipairs({ "0%", "101%", "bad", {}, math.huge, -math.huge }) do
      assert.is_nil(layout.resolve_width(value))
    end
    assert.is_nil(layout.resolve_width(0 / 0))
    assert.are.equal(70, layout.target_width({ config = { ui = { chat_width = "bad" } } }))
    assert.are.equal(70, layout.target_width({}))
  end)

  for _, width in ipairs({ 0.35, "35%" }) do
    it("keeps relative width " .. tostring(width) .. " across screen changes and reopening", function()
      local ui = require("omniac.ui")
      local config = { ui = { chat_width = width, mascot_motion = false } }
      local state = ui.open(config, function() end)
      assert_sidebar_width(state, 70)
      assert.is_nil(state.user_width, "opening must preserve the configured ratio")

      resize_screen(state, 140, 49)
      resize_screen(state, 100, 42)
      resize_screen(state, 240, 84)
      ui.open(config, function() end)
      resize_screen(state, 200, 70)

      ui.close()
      vim.o.columns = 240
      state = ui.open(config, function() end)
      assert_sidebar_width(state, 84)
      resize_screen(state, 200, 70)
    end)
  end

  it("switches between relative and fixed widths through OmniacResize", function()
    package.loaded["omniac"] = nil
    require("omniac").setup({ keymaps = false })
    local ui = require("omniac.ui")
    local state = ui.open({ ui = { chat_width = 58, mascot_motion = false } }, function() end)

    vim.cmd("OmniacResize 35%")
    assert_sidebar_width(state, 70)
    resize_screen(state, 240, 84)
    assert.is_false(ui.resize("101%"))
    assert_sidebar_width(state, 84)

    vim.cmd("OmniacResize 72")
    resize_screen(state, 200, 72)
    vim.cmd("OmniacResize 0.35")
    resize_screen(state, 240, 84)
  end)
end)
