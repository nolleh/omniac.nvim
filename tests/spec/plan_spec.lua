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

  it("expands the live plan in place and keeps input focus and text", function()
    local state, send, activity = setup()
    local entries = {
      { content = "Inspect", status = "completed" },
      { content = "Implement", status = "in_progress" },
      { content = "Verify", status = "pending" },
      { content = "Obsolete", status = "cancelled" },
    }
    send("omniac/plan_update", { turnId = 7, entries = entries })
    assert.is_truthy(activity():find("[Ctrl-P] Expand plan", 1, true))
    assert.is_nil(activity():find("Verify", 1, true))
    local input = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local count = #vim.api.nvim_list_wins()
    vim.api.nvim_set_current_win(state.input_win)
    helpers.feed("<C-p>")
    assert.equals(state.input_win, vim.api.nvim_get_current_win())
    assert.same(input, vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false))
    assert.equals(count, #vim.api.nvim_list_wins())
    assert.is_truthy(activity():find("[x] 1. Inspect", 1, true))
    assert.is_truthy(activity():find("[~] 2. Implement", 1, true))
    assert.is_truthy(activity():find("[ ] 3. Verify", 1, true))
    assert.is_truthy(activity():find("[-] 4. Obsolete", 1, true))
    assert.equals(6, state.activity_height)
    entries[3].status = "in_progress"
    send("omniac/plan_update", { turnId = 7, entries = entries })
    assert.is_truthy(activity():find("[~] 3. Verify", 1, true))
    helpers.feed("<C-k>")
    assert.equals(state.activity_win, vim.api.nvim_get_current_win())
    helpers.feed("<C-p>")
    assert.is_false(state.plan_expanded)
    assert.equals(2, state.activity_height)
    assert.is_nil(activity():find("Obsolete", 1, true))
    helpers.feed("<C-p>")
    send("omniac/response_completed", { turnId = 7 })
    assert.is_false(state.plan_expanded)
    assert.is_nil(activity():find("Ctrl-P", 1, true))
    assert.equals(1, state.activity_height)
  end)

  it("wraps full plan details and keeps long lists scrollable in a bounded bar", function()
    local state, send, activity = setup()
    local entries = {}
    for index = 1, 30 do
      entries[index] = { content = string.rep("한글", 35) .. " end " .. index, status = "pending" }
    end
    send("omniac/plan_update", { turnId = 7, plan = { type = "items", planId = "work", entries = entries } })
    helpers.feed("<C-p>")
    assert.is_truthy(activity():find("end 30", 1, true))
    assert.is_nil(activity():find("…", activity():find("[ ] 1.", 1, true), true))
    assert.is_true(state.activity_height <= math.floor(vim.o.lines / 3))
    assert.is_true(vim.api.nvim_buf_line_count(state.activity_buf) > state.activity_height)
    vim.api.nvim_set_current_win(state.activity_win)
    helpers.feed("G")
    local cursor = vim.api.nvim_win_get_cursor(state.activity_win)
    send("omniac/tool_activity", { title = "Tests", status = "in_progress" })
    assert.same(cursor, vim.api.nvim_win_get_cursor(state.activity_win))
    send("omniac/session_loading")
    assert.is_false(state.plan_expanded)
  end)

  it("expands the latest Markdown document and falls back after removal", function()
    local state, send, activity = setup()
    send("omniac/plan_update", { turnId = 7, entries = { { content = "Legacy", status = "pending" } } })
    send("omniac/plan_update", {
      turnId = 7,
      plan = { type = "markdown", planId = "design", content = "# Design\nDetailed proposal" },
    })
    helpers.feed("<C-p>")
    assert.is_truthy(activity():find("Detailed proposal", 1, true))
    send("omniac/plan_update", { turnId = 7, removedPlanId = "design" })
    assert.is_truthy(activity():find("[ ] 1. Legacy", 1, true))
    send("omniac/plan_update", { turnId = 7, entries = {} })
    assert.is_nil(activity():find("Ctrl-P", 1, true))
  end)

  it("advertises plan support as a JSON object in configured and minimal clients", function()
    for _, config in ipairs({ {}, require("omniac.config").merge({}) }) do
      local client = require("omniac.backend.acp").new(config)
      local capabilities
      client.transport = {
        request = function(_, method, params, callback)
          assert.equals("initialize", method)
          capabilities = params.clientCapabilities
          callback(nil, { protocolVersion = 1 })
        end,
      }
      client:_initialize(function(err)
        assert.is_nil(err)
      end)
      assert.equals("{}", vim.json.encode(capabilities.plan))
    end
  end)

  it("preserves explicitly supplied client capabilities", function()
    local client = require("omniac.backend.acp").new({ client = { capabilities = { terminal = false } } })
    client.transport = {
      request = function(_, _, params, callback)
        assert.is_nil(params.clientCapabilities.plan)
        callback(nil, {})
      end,
    }
    client:_initialize(function() end)
  end)

  it("routes negotiated plan documents and replaces them independently by ID", function()
    local state, send, activity = setup()
    local client = require("omniac.backend.acp").new({})
    client.session_id = "session"
    client.active_turn_id = 7
    client:on_notification(function(message)
      send(message.method, message.params)
    end)
    local function update(value)
      client:_handle_notification({ method = "session/update", params = { sessionId = "session", update = value } })
      vim.wait(30, function()
        return false
      end)
    end
    update({
      sessionUpdate = "plan_update",
      plan = { type = "markdown", planId = "proposal", content = "# Design\nFirst draft" },
    })
    local proposal = state.plan_documents.proposal.notice_index
    assert.is_truthy(activity():find("Plan: Design", 1, true))
    update({
      sessionUpdate = "plan_update",
      plan = { type = "markdown", planId = "proposal", content = "# Final design\nRevised draft" },
    })
    assert.equals(proposal, state.plan_documents.proposal.notice_index)
    assert.equals("# Final design\nRevised draft", state.messages[proposal].text)
    update({
      sessionUpdate = "plan_update",
      plan = {
        type = "items",
        planId = "work",
        entries = {
          { content = "Inspect", status = "completed", priority = "medium" },
          { content = "Implement", status = "in_progress", priority = "medium" },
        },
      },
    })
    local work = state.plan_documents.work.notice_index
    assert.is_truthy(activity():find("Plan 1/2: Implement", 1, true))
    assert.equals("# Final design\nRevised draft", state.messages[proposal].text)
    update({ sessionUpdate = "plan_removed", planId = "work" })
    assert.is_nil(state.plan_documents.work)
    assert.equals("Plan removed.", state.messages[work].text)
    assert.is_truthy(activity():find("Plan: Final design", 1, true))
    send("omniac/response_completed", { turnId = 7, stopReason = "cancelled" })
    assert.is_truthy(state.messages[proposal].text:find("Turn cancelled.", 1, true))
    assert.is_nil(state.plan_documents)
  end)

  it("replaces changed plan types, handles files and rejects malformed or stale documents", function()
    local state, send, activity = setup()
    send("omniac/plan_update", { turnId = 6, plan = { type = "markdown", planId = "old", content = "Stale" } })
    assert.is_nil(state.plan_documents)
    send("omniac/plan_update", { turnId = 7, plan = { type = "markdown", planId = "doc" } })
    assert.is_nil(state.plan_documents)
    send("omniac/plan_update", { turnId = 7, plan = { type = "file", planId = "doc", uri = "file:///tmp/plan.md" } })
    local index = state.plan_documents.doc.notice_index
    assert.equals("Plan file: file:///tmp/plan.md", state.messages[index].text)
    send("omniac/plan_update", { turnId = 7, plan = { type = "_future", planId = "doc" } })
    assert.equals(index, state.plan_documents.doc.notice_index)
    assert.equals("Unsupported plan content: _future", state.messages[index].text)
    assert.is_nil(activity():find("/tmp/plan.md", 1, true))
    send("omniac/plan_update", { turnId = 7, plan = { type = "items", planId = "doc", entries = {} } })
    assert.equals("Plan cleared.", state.messages[index].text)
    assert.is_truthy(activity():find("Working", 1, true))
    send("omniac/session_loading")
    assert.is_nil(state.plan_documents)
  end)

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
