local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim status", function()
  after_each(helpers.cleanup_after_test)

  it("status shows the agent's mode name and plan without redundant idle labels", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({
      method = "omniac/session_config_update",
      params = {
        configOptions = {
          { id = "mode", currentValue = "agent-full-access" },
          { id = "collaboration_mode", currentValue = "plan" },
        },
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    })
    ui.set_session_mode({
      currentModeId = "agent-full-access",
      currentModeName = "Unrestricted Agent",
    })

    local status_buf = vim.fn.bufnr("omniac://status")
    local line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    local plan_hl = vim.api.nvim_get_hl(0, { name = "OmniacStatusPlan" })
    local plan_edge_hl = vim.api.nvim_get_hl(0, { name = "OmniacStatusPlanEdge" })
    assert_true(line:find("Unrestricted Agent", 1, true) ~= nil, "agent-provided mode name should be visible")
    assert_true(line:find("Plan", 1, true) ~= nil, "plan mode should be visible")
    assert_true(line:find("Unrestricted Agent", 1, true) < line:find("Plan", 1, true), "Plan should follow the mode")
    assert_equal(plan_hl.bg, tonumber("cba6f7", 16), "Plan should use the purple capsule")
    assert_equal(plan_edge_hl.fg, tonumber("cba6f7", 16), "Plan capsule edges should be purple")
    assert_true(line:find("Omniac", 1, true) == nil, "plugin name should not take status space")
    assert_true(line:find("ready", 1, true) == nil, "idle state should not take status space")

    ui.set_session_mode({ currentModeId = "agent-full-access" })
    line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    assert_true(line:find("agent-full-access", 1, true) ~= nil, "mode ID should be visible when name is absent")

    ui.set_session_config({
      { id = "mode", currentValue = "agent-full-access" },
      { id = "collaboration_mode", currentValue = "default" },
    })
    line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    assert_true(line:find("Plan", 1, true) == nil, "Plan should disappear when collaboration mode returns to default")
  end)

  it("status renders the current ACP session model", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({
      method = "omniac/session_model_update",
      params = {
        currentModelId = "gpt-5-mini",
        currentModelName = "GPT-5 Mini",
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    })

    local status_buf = vim.fn.bufnr("omniac://status")
    local line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    ui.handle_notification({
      method = "omniac/session_config_update",
      params = { configOptions = { { id = "reasoning_effort", currentValue = "medium" } } },
    }, {})
    line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    assert_true(line:find("GPT-5 Mini · Medium", 1, true) ~= nil, "model and effort should share a capsule")
  end)

  it("status renders ACP context usage as a percentage", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }, function() end)

    ui.handle_notification({
      method = "omniac/session_model_update",
      params = {
        currentModelId = "gpt-5-mini",
        currentModelName = "GPT-5 Mini",
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    })
    ui.handle_notification({
      method = "omniac/usage_update",
      params = {
        used = 75000,
        size = 100000,
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    })

    local status_buf = vim.fn.bufnr("omniac://status")
    local line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    local model_start = line:find("GPT-5 Mini", 1, true)
    local usage_start = line:find("ctx 75%", 1, true)
    local usage_hl = vim.api.nvim_get_hl(0, { name = "OmniacStatusUsage" })
    assert_true(line:match("ctx 75%%") ~= nil, "status should include context-window usage")
    assert_true(model_start < usage_start, "context usage should render after the model")
    assert_equal(usage_hl.bg, tonumber("89b4fa", 16), "context usage should use its own capsule color")
  end)
end)
