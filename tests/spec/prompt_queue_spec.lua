local helpers = require("tests.helpers")

describe("omniac.nvim prompt queue", function()
  local app, ui, state, requests

  before_each(function()
    helpers.cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    app = require("omniac")
    ui = require("omniac.ui")
    app.config = require("omniac.config").merge({
      ui = { chat_width = 60, mascot_motion = false, mascot_follow_cursor = false },
    })
    requests = {}
    app.backend = { running = true, session_id = "queue-session" }
    function app.backend:supports_prompt_capability()
      return true
    end
    function app.backend:prompt(text, params, callback)
      local id = #requests + 1
      self.active_turn_id = id
      table.insert(requests, { text = text, params = params, callback = callback })
      ui.handle_notification({ method = "omniac/prompt_started", params = { turnId = id } }, app.config)
    end
    app.open_chat()
    state = ui.open(app.config)
    ui.clear_conversation(app.config)
    vim.v.errmsg = ""
  end)

  after_each(function()
    app.backend = nil
    app.active_submission = nil
    app.failed_submission = nil
    app.queued_submissions = {}
    helpers.cleanup_after_test()
  end)

  local function finish(index, err)
    app.backend.active_turn_id = nil
    ui.handle_notification({
      method = err and "omniac/prompt_failed" or "omniac/response_completed",
      params = { turnId = index },
    }, app.config)
    requests[index].callback(err, err and nil or { stopReason = "end_turn" })
  end

  local function chat()
    return table.concat(vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false), "\n")
  end

  it("queues through the real Tab mapping without textlock errors or interrupting the response", function()
    helpers.feed("ifirst<CR>")
    assert.equals(1, #requests)
    ui.handle_notification({ method = "omniac/response_chunk", params = { turnId = 1, text = "Before " } }, app.config)
    local response_index = state.streaming_message_index
    helpers.feed("iqueued second<Tab>")
    assert.is_true(vim.wait(200, function()
      return #app.queued_submissions == 1 and app.queued_submissions[1].message ~= nil
    end))
    assert.equals("", vim.v.errmsg)
    assert.equals(1, #requests, "a working turn must finish before the queued prompt is sent")
    assert.is_nil(
      table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"):find("queued second", 1, true)
    )
    local item = app.queued_submissions[1]
    assert.is_true(item.message.queued)
    assert.is_truthy(chat():find("Queued · waiting for current turn", 1, true))
    assert.equals(response_index, state.streaming_message_index)
    ui.handle_notification({ method = "omniac/response_chunk", params = { turnId = 1, text = "after" } }, app.config)
    finish(1)
    assert.is_true(vim.wait(200, function()
      return #requests == 2
    end))
    assert.equals("Before after", state.messages[response_index].text)
    assert.equals("queued second", requests[2].text)
    assert.is_false(item.message.queued)
    local count = 0
    for _, message in ipairs(state.messages) do
      if message == item.message then
        count = count + 1
      end
    end
    assert.equals(1, count)
    assert.is_nil(chat():find("Queued · waiting for current turn", 1, true))
    finish(2)
  end)

  it("preserves attachments and sends multiple queued prompts in FIFO order", function()
    state.submit("first", {})
    local attachment = { type = "reference", text = "saved context", path = "/tmp/queue-reference.lua" }
    assert.is_true(state.queue_submit("second", { attachment }))
    assert.is_true(state.queue_submit("third", {}))
    attachment.text = "changed later"
    assert.is_true(vim.wait(200, function()
      return app.queued_submissions[2].message ~= nil
    end))
    local second = app.queued_submissions[1]
    local third = app.queued_submissions[2]
    assert.equals("saved context", second.attachments[1].text)
    finish(1)
    assert.is_true(vim.wait(200, function()
      return #requests == 2
    end))
    assert.equals("second", requests[2].text)
    assert.is_truthy(vim.inspect(requests[2].params):find("saved context", 1, true))
    assert.is_false(second.message.queued)
    assert.is_true(third.message.queued)
    finish(2)
    assert.is_true(vim.wait(200, function()
      return #requests == 3
    end))
    assert.equals("third", requests[3].text)
    assert.is_false(third.message.queued)
    finish(3)
    assert.equals(0, #app.queued_submissions)
    assert.is_nil(app.active_submission)
  end)

  it("handles turn completion before the queued display callback runs", function()
    state.submit("first", {})
    finish(1)
    -- A new prompt can arrive before the already scheduled queue dispatcher.
    state.submit("second", {})
    assert.is_true(state.queue_submit("third", {}))
    finish(2)
    assert.is_true(vim.wait(200, function()
      return #requests == 3
    end))
    assert.equals("third", requests[3].text)
    assert.equals(0, #app.queued_submissions)
    local count = 0
    for _, message in ipairs(state.messages) do
      if message.role == "You" and message.text == "third" then
        count = count + 1
      end
    end
    assert.equals(1, count)
    finish(3)
  end)

  it("stops dispatch after failure and retries without duplicating the queued message", function()
    state.submit("first", {})
    state.queue_submit("second", {})
    state.queue_submit("third", {})
    finish(1)
    assert.is_true(vim.wait(200, function()
      return #requests == 2
    end))
    finish(2, { message = "Prompt rejected" })
    vim.wait(50, function()
      return false
    end)
    assert.equals(2, #requests)
    assert.equals("second", app.failed_submission.text)
    assert.equals(1, #app.queued_submissions)
    assert.is_true(app.queued_submissions[1].message.queued)
    assert.is_true(app.retry_failed_submission())
    assert.equals(3, #requests)
    assert.equals("second", requests[3].text)
    finish(3)
    assert.is_true(vim.wait(200, function()
      return #requests == 4
    end))
    assert.equals("third", requests[4].text)
    local count = 0
    for _, message in ipairs(state.messages) do
      if message.role == "You" and message.text == "second" then
        count = count + 1
      end
    end
    assert.equals(1, count)
    finish(4)
  end)
end)
