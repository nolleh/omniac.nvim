local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true

describe("omniac.nvim ACP normalization", function()
  local normalize = require("omniac.acp.normalize")

  it("reads camel and snake case response fields", function()
    assert_equal(normalize.stop_reason({ stopReason = "end_turn" }), "end_turn")
    assert_equal(normalize.stop_reason({ stop_reason = "max_tokens" }), "max_tokens")
    assert_equal(normalize.turn_id({ turnId = 3 }), 3)
    assert_equal(normalize.turn_id({ turn_id = 4 }), 4)
    assert_equal(normalize.session_id({ session = { session_id = "session-1" } }), "session-1")
  end)

  it("normalizes equivalent cancellation spellings", function()
    assert_equal(normalize.stop_reason({ stopReason = "canceled" }), "cancelled")
    assert_equal(normalize.stop_reason({ result = { stop_reason = "cancelled" } }), "cancelled")
  end)

  it("normalizes camel case update names", function()
    assert_equal(normalize.update_type({ sessionUpdate = "availableCommandsUpdate" }), "available_commands_update")
    assert_equal(normalize.update_type({ type = "agentMessageChunk" }), "agent_message_chunk")
    assert_equal(normalize.update_type({ sessionUpdate = "tool_call" }), "tool_call")
  end)

  it("reads collections without leaking invalid protocol values", function()
    local content = { { type = "text", text = "hello" } }
    local commands = { { name = "help" } }
    assert_equal(normalize.content_items({ content_items = content }), content)
    assert_equal(normalize.available_commands({ availableCommands = commands }), commands)
    assert_equal(#normalize.content_items({ contentItems = "invalid" }), 0)
    assert_equal(#normalize.available_commands({ available_commands = false }), 0)
  end)

  it("reads capability aliases", function()
    local capabilities = normalize.agent_capabilities({
      agent_capabilities = {
        load_session = true,
        session_capabilities = { resume = false },
        prompt_capabilities = { image = true },
      },
    })
    assert_true(normalize.has_load_session(capabilities))
    assert_true(normalize.session_capability(capabilities, "resume"))
    assert_true(normalize.prompt_capability(capabilities, "image"))
  end)

  it("reads session configuration aliases", function()
    local options = { { id = "mode" } }
    local modes = { { id = "plan" } }
    assert_equal(normalize.config_options({ config_options = options }), options)
    assert_equal(normalize.current_value({ current_value = "plan" }), "plan")
    assert_equal(normalize.mode_id({ mode_id = "plan" }), "plan")
    assert_equal(normalize.current_mode_id({ current_mode_id = "plan" }), "plan")
    assert_equal(normalize.available_modes({ available_modes = modes }), modes)
  end)
end)
