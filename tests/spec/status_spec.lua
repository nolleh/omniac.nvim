local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim status", function()
  after_each(helpers.cleanup_after_test)

  it("merges partial usage updates while ignoring missing and invalid fields", function()
    local session = require("omniac.ui.session")
    local state = {}
    local function render() end
    session.set_usage(state, { used = 10, size = 100, cost = { amount = 1, currency = "USD" } }, render)
    session.set_usage(state, { used = 20 }, render)
    assert_equal(state.session_usage.used, 20)
    assert_equal(state.session_usage.size, 100)
    assert_equal(state.session_usage.cost.amount, 1)
    session.set_usage(state, { cost = { amount = 2 } }, render)
    assert_equal(state.session_usage.used, 20)
    assert_equal(state.session_usage.cost.amount, 2)
    assert_equal(state.session_usage.cost.currency, "USD")
    session.set_usage(state, { used = vim.NIL, size = 0, cost = { currency = "bad" } }, render)
    assert_equal(state.session_usage.used, 20)
    assert_equal(state.session_usage.size, 100)
    assert_equal(state.session_usage.cost.currency, "USD")
    session.set_usage(state, { used = 0, cost = { amount = 0 } }, render)
    assert_equal(state.session_usage.used, 0)
    assert_equal(state.session_usage.cost.amount, 0)
    session.set_usage(state, nil, render)
    assert_equal(state.session_usage, nil)
  end)

  it("renders context when cost arrives first and preserves it after cost-only updates", function()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local state = ui.open({ ui = { chat_width = 58 } }, function() end)
    ui.set_session_usage({ cost = { amount = 1 } })
    ui.set_session_usage({ used = 50 })
    ui.set_session_usage({ size = 100 })
    ui.set_session_usage({ cost = { amount = 2 } })
    local status = table.concat(vim.api.nvim_buf_get_lines(state.status_buf, 0, -1, false), "\n")
    assert_true(status:find("ctx 50%", 1, true) ~= nil)
    ui.handle_notification({ method = "omniac/session_started", params = { clearChat = true } }, {})
    assert_equal(state.session_usage, nil)
  end)

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

  it("clears context usage when a new session clears the conversation", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }
    ui.open(config, function() end)
    local status_buf = vim.fn.bufnr("omniac://status")
    local function status_text()
      return table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    end

    ui.handle_notification({
      method = "omniac/usage_update",
      params = { used = 75000, size = 100000 },
    }, config)
    assert_true(status_text():find("ctx 75%", 1, true) ~= nil, "previous session usage should be visible")

    ui.handle_notification({
      method = "omniac/session_started",
      params = { sessionId = "new-session", method = "session/new", clearChat = true },
    }, config)
    assert_true(status_text():find("ctx", 1, true) == nil, "new session should discard previous context usage")

    ui.handle_notification({
      method = "omniac/usage_update",
      params = { used = 1000, size = 100000 },
    }, config)
    assert_true(status_text():find("ctx 1%", 1, true) ~= nil, "new session usage should appear when reported")
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
