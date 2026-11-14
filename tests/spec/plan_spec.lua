local helpers = require("tests.helpers")

describe("omniac.nvim agent plans", function()
  after_each(helpers.cleanup_after_test)

  local function setup()
    helpers.cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { agent = { cmd = { "codex-acp" } }, ui = { chat_width = 60 } }
    local state = ui.open(config, function() end)
    local function send(method, params)
      ui.handle_notification({ method = method, params = params or {} }, config)
    end
    local function activity()
      return table.concat(vim.api.nvim_buf_get_lines(state.activity_buf, 0, -1, false), "\n")
    end
    send("omniac/prompt_started", { turnId = 7 })
    return state, send, activity
  end

  it("routes ACP plans and replaces the full list without duplicating chat notices", function()
    local state, send, activity = setup()
    local client = require("omniac.backend.acp").new({})
    client.session_id = "session"
    client.active_turn_id = 7
    client:on_notification(function(message)
      send(message.method, message.params)
    end)
    local function update(entries)
      client:_handle_notification({
        method = "session/update",
        params = {
          sessionId = "session",
          update = { sessionUpdate = "plan", entries = entries },
        },
      })
      vim.wait(30, function()
        return false
      end)
    end
    update({
      { content = "Inspect", status = "completed", priority = "high" },
      { content = "Implement", status = "in_progress", priority = "medium" },
      { content = "Obsolete", status = "pending", priority = "low" },
    })
    assert.is_truthy(activity():find("Plan 1/3: Implement", 1, true))
    local index = state.plan_notice_index
    assert.is_truthy(state.messages[index].text:find("[x] Inspect", 1, true))
    send("omniac/tool_activity", { kind = "execute", title = "Tests", status = "in_progress" })
    assert.is_truthy(activity():find("Plan 1/3", 1, true))
    assert.is_truthy(activity():find("Tests", 1, true))
    update({ { content = "Verify", status = "in_progress", priority = "high" } })
    assert.equals(index, state.plan_notice_index)
    assert.equals(1, #state.plan_entries)
    assert.is_nil(state.messages[index].text:find("Obsolete", 1, true))
    assert.is_truthy(activity():find("Plan 0/1: Verify", 1, true))
    update({ { content = "Verify", status = "completed", priority = "high" } })
    assert.is_truthy(activity():find("Plan 1/1", 1, true))
    send("omniac/response_completed", { turnId = 7 })
    assert.is_nil(state.plan_entries)
    assert.is_truthy(state.messages[index].text:find("[x] Verify", 1, true))
  end)

  it("keeps streamed replies intact while updating the plan", function()
    local state, send = setup()
    send("omniac/plan_update", { turnId = 7, entries = { { content = "Work", status = "in_progress" } } })
    send("omniac/response_chunk", { turnId = 7, text = "First " })
    local index = state.streaming_message_index
    send("omniac/plan_update", { turnId = 7, entries = { { content = "Work", status = "completed" } } })
    send("omniac/response_chunk", { turnId = 7, text = "second" })
    assert.equals(index, state.streaming_message_index)
    send("omniac/response_completed", { turnId = 7 })
    assert.equals("First second", state.messages[index].text)
  end)

  it("ignores stale and malformed updates and accepts an explicitly empty plan", function()
    local state, send, activity = setup()
    send("omniac/plan_update", { turnId = 6, entries = { { content = "Stale", status = "pending" } } })
    assert.is_nil(state.plan_entries)
    send("omniac/plan_update", { turnId = 7, entries = "bad" })
    assert.is_nil(state.plan_entries)
    send("omniac/plan_update", { turnId = 7, entries = { false, {}, { content = "Valid", status = "pending" } } })
    assert.equals(1, #state.plan_entries)
    local index = state.plan_notice_index
    send("omniac/plan_update", { turnId = 7, entries = {} })
    assert.equals("Plan cleared.", state.messages[index].text)
    assert.is_truthy(activity():find("Working", 1, true))
  end)

  it("preserves unfinished steps on cancellation or error and starts each turn fresh", function()
    for _, method in ipairs({ "omniac/prompt_cancelled", "omniac/error" }) do
      local state, send, activity = setup()
      send("omniac/plan_update", { turnId = 7, entries = { { content = "Unfinished", status = "in_progress" } } })
      local index = state.plan_notice_index
      send(method, { turnId = 7 })
      assert.is_truthy(state.messages[index].text:find("[~] Unfinished", 1, true))
      assert.is_truthy(
        state.messages[index].text:find(method == "omniac/error" and "Turn failed." or "Turn cancelled.", 1, true)
      )
      assert.is_nil(state.plan_entries)
      send("omniac/prompt_started", { turnId = 8 })
      assert.is_truthy(activity():find("Working", 1, true))
      send("omniac/plan_update", { turnId = 7, entries = { { content = "Late", status = "completed" } } })
      assert.is_nil(state.plan_entries)
    end
  end)

  it("clears plan state on session replacement", function()
    local state, send = setup()
    send("omniac/plan_update", { turnId = 7, entries = { { content = "Old", status = "pending" } } })
    send("omniac/session_loading")
    assert.is_nil(state.plan_entries)
    assert.is_nil(state.plan_notice_index)
    send("omniac/session_started", { clearChat = true })
    assert.is_nil(state.plan_notice_index)
  end)

  it("suppresses late plan updates during cancellation and clears state on disconnect", function()
    local state, send = setup()
    send("omniac/plan_update", { turnId = 7, entries = { { content = "Current", status = "pending" } } })
    state.suppress_current_turn = true
    send("omniac/plan_update", { turnId = 7, entries = { { content = "Late", status = "completed" } } })
    assert.equals("Current", state.plan_entries[1].content)
    require("omniac.ui").set_status("closed")
    assert.is_nil(state.plan_entries)
    assert.is_nil(state.plan_notice_index)
  end)
end)
