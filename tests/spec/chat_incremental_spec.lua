local helpers = require("tests.helpers")
local chat_render = require("omniac.ui.chat.render")
local chat_view = require("omniac.ui.chat.view")
local messages = require("omniac.ui.chat.messages")
local text = require("omniac.ui.text")

describe("incremental chat rendering", function()
  local state, handlers, render, chat_handlers, changes
  local original_wrapped = text.wrapped

  before_each(function()
    state = require("omniac.ui.state").new()
    state.chat_buf = vim.api.nvim_create_buf(false, true)
    state.card_pinned = true
    state.config = {}
    handlers = {
      valid_buf = vim.api.nvim_buf_is_valid,
      valid_win = function()
        return false
      end,
      width = function()
        return 48
      end,
      namespace = vim.api.nvim_create_namespace("omniac.incremental-test"),
      header = function() end,
      agent_name = function()
        return "test"
      end,
    }
    handlers.add_hl = function(buf, line, from, to, group)
      vim.api.nvim_buf_add_highlight(buf, handlers.namespace, group, line - 1, from, to)
    end
    render = function(opts)
      chat_view.render(state, state.config, opts, handlers)
    end
    chat_handlers = {
      request_render = function(_, opts)
        render(opts)
      end,
      render_activity = function() end,
      focus_input_if_active = function() end,
      set_activity = function() end,
    }
    changes = {}
    vim.api.nvim_buf_attach(state.chat_buf, false, {
      on_lines = function(_, _, _, first, last, new_last)
        table.insert(changes, { first = first, last = last, new_last = new_last })
      end,
    })
  end)

  after_each(function()
    text.wrapped = original_wrapped
    pcall(vim.api.nvim_buf_delete, state.chat_buf, { force = true })
  end)

  local function assert_full_render()
    local expected = chat_render.build({
      state = state,
      width = handlers.width(),
      header = handlers.header,
      agent_name = handlers.agent_name,
    })
    assert.are.same(expected.lines, vim.api.nvim_buf_get_lines(state.chat_buf, 0, -1, false))
    assert.are.same(expected.markdown_excluded_ranges, state.chat_render_cache.excluded)
  end

  it("appends new messages without wrapping or replacing completed history", function()
    messages.add_message(state, "You", "completed history", nil, nil, chat_handlers)
    local previous_count = vim.api.nvim_buf_line_count(state.chat_buf)
    local markdown_ns = vim.api.nvim_create_namespace("render-markdown.incremental-test")
    local mark = vim.api.nvim_buf_set_extmark(state.chat_buf, markdown_ns, 0, 0, {})
    text.wrapped = function(value, width)
      assert.is_nil(value:find("completed history", 1, true), "completed text must not be wrapped again")
      return original_wrapped(value, width)
    end
    changes = {}
    messages.add_message(state, "Omniac", "new reply", nil, nil, chat_handlers)
    assert.are.equal(1, #changes)
    assert.are.equal(previous_count, changes[1].first)
    assert.are.same({ 0, 0 }, vim.api.nvim_buf_get_extmark_by_id(state.chat_buf, markdown_ns, mark, {}))
    text.wrapped = original_wrapped
    assert_full_render()
  end)

  it("only replaces the changing lines at the end of a streaming message", function()
    messages.add_message(state, "Omniac", "earlier message", nil, nil, chat_handlers)
    messages.append_response_chunk(state, "stable first line\npartial", nil, chat_handlers)
    local from = state.chat_render_cache.ranges[2].from
    changes = {}
    messages.append_response_chunk(state, " second line", nil, chat_handlers)
    assert.are.equal(1, #changes)
    assert.are.equal(from + 1, changes[1].first)
    assert.are.equal(from + 2, changes[1].last)
    assert_full_render()
    messages.complete_response(state, nil, { stop_footer = "Stopped: token limit" }, chat_handlers)
    assert_full_render()
  end)

  it("does not touch the buffer when only the status changes", function()
    messages.add_message(state, "Omniac", "completed reply", nil, nil, chat_handlers)
    changes = {}
    state.status = "working"
    render()
    assert.are.equal(0, #changes)
  end)

  it("updates an earlier approval and keeps later message offsets correct", function()
    local index = messages.add_notice(state, "Permission", "Run command?", nil, chat_handlers)
    messages.add_message(state, "You", "[Image 1] literal", nil, nil, chat_handlers)
    messages.add_message(state, "Omniac", "later reply", nil, nil, chat_handlers)
    messages.update_notice(
      state,
      index,
      "Run command?\nDecision: approved",
      nil,
      { permission_status = "approved" },
      chat_handlers
    )
    assert_full_render()
    messages.append_response_chunk(state, "another reply", nil, chat_handlers)
    assert_full_render()
    local marks = vim.api.nvim_buf_get_extmarks(state.chat_buf, handlers.namespace, 0, -1, { details = true })
    local approved = false
    for _, mark in ipairs(marks) do
      local virt = mark[4].virt_text
      approved = approved or (virt and virt[1][1] == "✓ Approved")
    end
    assert.is_true(approved)
  end)

  it("finishes a streamed message before appending and expanding tool output", function()
    messages.append_response_chunk(state, "before tool", nil, chat_handlers)
    local tools = require("omniac.ui.tools")
    tools.add_result(
      state,
      { status = "completed", command = "test", output = "1\n2\n3\n4\n5\n6" },
      { ui = { tool_results = "all" } },
      {
        request_chat_render = function(_, opts)
          render(opts)
        end,
        focus_input_if_active = function() end,
      }
    )
    assert_full_render()
    tools.toggle_output(state, nil, {
      render_chat = function()
        render()
      end,
      focus_input = function() end,
    })
    assert_full_render()
  end)

  it("reflows history on resize and rebuilds after clearing or replacing the buffer", function()
    messages.add_message(state, "You", string.rep("long history ", 20), nil, nil, chat_handlers)
    messages.add_message(state, "Omniac", "reply", nil, nil, chat_handlers)
    handlers.width = function()
      return 70
    end
    render()
    assert_full_render()
    local old_buf = state.chat_buf
    state.chat_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(old_buf, { force = true })
    render()
    assert_full_render()
    state.messages = {}
    render()
    assert_full_render()
  end)
end)

describe("session history rendering", function()
  local ui, config, chat_buf, writes, markdown_calls

  before_each(function()
    helpers.cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    markdown_calls = 0
    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function()
          markdown_calls = markdown_calls + 1
        end,
      }
    end
    package.loaded["render-markdown"] = nil
    ui = require("omniac.ui")
    config = { ui = { chat_width = 48, mascot_motion = false, mascot_follow_cursor = false } }
    ui.open(config, function() end)
    chat_buf = vim.fn.bufnr("omniac")
    writes = 0
    vim.api.nvim_buf_attach(chat_buf, false, {
      on_lines = function()
        writes = writes + 1
      end,
    })
    ui.handle_notification({ method = "omniac/session_loading", params = {} }, config)
    markdown_calls = 0
  end)

  after_each(helpers.cleanup_after_test)

  it("coalesces a burst of history events and cancels the pending render on completion", function()
    for index = 1, 100 do
      ui.append_response_chunk("history " .. index .. "\n", config)
      ui.add_tool_result({ status = "completed", command = "read", output = "file " .. index }, config)
    end
    ui.append_response_chunk("final reply", config)
    assert.are.equal(0, writes)
    assert.are.equal(0, markdown_calls)
    ui.handle_notification({ method = "omniac/session_started", params = { method = "session/load" } }, config)
    assert.are.equal(1, writes)
    assert.is_true(vim.wait(500, function()
      return markdown_calls == 1
    end))
    assert.are.equal(1, markdown_calls)
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert.is_truthy(chat:find("history 1", 1, true))
    assert.is_truthy(chat:find("file 100", 1, true))
    assert.is_truthy(chat:find("final reply", 1, true))
    vim.wait(100, function()
      return false
    end)
    assert.are.equal(1, writes, "a cancelled timer must not rewrite the restored chat")
  end)

  it("renders intermediate batches and appends later batches below them", function()
    ui.append_response_chunk("first batch", config)
    assert.is_true(vim.wait(200, function()
      return writes > 0
    end))
    assert.are.equal(0, markdown_calls)
    local first_count = vim.api.nvim_buf_line_count(chat_buf)
    local starts = {}
    vim.api.nvim_buf_attach(chat_buf, false, {
      on_lines = function(_, _, _, first)
        table.insert(starts, first)
      end,
    })
    ui.add_tool_result({ status = "completed", command = "read", output = "second batch" }, config)
    assert.is_true(vim.wait(200, function()
      return writes > 1
    end))
    assert.is_true(starts[1] > 0, "later batches must preserve earlier lines")
    assert.is_true(vim.api.nvim_buf_line_count(chat_buf) > first_count)
    ui.handle_notification({ method = "omniac/session_started", params = {} }, config)
    assert.are.equal(1, markdown_calls, "completion must render markdown even after a batch was flushed")
  end)

  it("restores immediate rendering after a load failure", function()
    ui.append_response_chunk("partial history", config)
    ui.handle_notification({ method = "omniac/error", params = { message = "load failed" } }, config)
    assert.is_true(writes > 0)
    local before = writes
    ui.add_message("You", "next prompt", config)
    assert.is_true(writes > before)
    before = writes
    vim.wait(100, function()
      return false
    end)
    assert.are.equal(before, writes)
  end)
end)
