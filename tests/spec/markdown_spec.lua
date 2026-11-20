local markdown = require("omniac.ui.markdown")

describe("chat markdown parsing", function()
  local buf, other, original, parser, callbacks, events

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    other = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "**history**", "partial `code" })
    original = { start = vim.treesitter.start, stop = vim.treesitter.stop, get_parser = vim.treesitter.get_parser }
    original.snacks = rawget(_G, "Snacks")
    original.image = package.loaded["snacks.image"]
    _G.Snacks = { config = { image = { enabled = true } } }
    vim.bo[buf].filetype = "omniac"
    callbacks, events = {}, {}
    package.loaded["snacks.image"] = {
      setup = function()
        events[#events + 1] = { "images_setup" }
      end,
      doc = {
        attach = function(b)
          events[#events + 1] = { "images_attach", b }
        end,
      },
    }
    local children = { markdown_inline = {} }
    parser = {
      children = function()
        return children
      end,
      remove_child = function(_, lang)
        children[lang] = nil
      end,
      set_included_regions = function(_, regions)
        events[#events + 1] = { "regions", regions }
      end,
      invalidate = function()
        events[#events + 1] = { "invalidate" }
      end,
      parse = function(_, range, callback)
        assert.is_true(range, "prepare injected languages before enabling automatic rendering")
        assert.are.equal("function", type(callback), "parsing must provide an async callback")
        callbacks[#callbacks + 1] = callback
      end,
    }
    vim.treesitter.get_parser = function()
      return parser
    end
    vim.treesitter.start = function(b)
      events[#events + 1] = { "start", b }
    end
    vim.treesitter.stop = function(b)
      events[#events + 1] = { "stop", b }
    end
    package.loaded["render-markdown"] = {
      initialized = true,
      buf_disable = function()
        events[#events + 1] = { "disable", vim.api.nvim_get_current_buf() }
      end,
      render = function(ctx)
        events[#events + 1] = { "render", ctx.buf }
      end,
    }
  end)

  after_each(function()
    vim.treesitter.start = original.start
    vim.treesitter.stop = original.stop
    vim.treesitter.get_parser = original.get_parser
    package.loaded["render-markdown"] = nil
    _G.Snacks = original.snacks
    package.loaded["snacks.image"] = original.image
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  local function count(event)
    local total = 0
    for _, entry in ipairs(events) do
      if entry[1] == event then
        total = total + 1
      end
    end
    return total
  end

  it("stops automatic parsers in the chat buffer and resumes after parsing completes", function()
    markdown.suspend(buf)
    assert.are.same({ "stop", buf }, events[1])
    assert.are.same({ "disable", buf }, events[2])
    assert.are.equal(other, vim.api.nvim_get_current_buf())
    assert.are.same({}, parser:children(), "old injected trees must not survive a reflow")
    markdown.start(buf, { { from = 1, to = 2 } })
    markdown.render(buf)
    assert.are.equal(0, count("start"))
    assert.are.equal(0, count("render"))
    assert.are.equal(0, count("images_attach"))
    callbacks[1](nil, {})
    assert.are.equal(1, count("start"))
    assert.are.equal(1, count("render"))
    assert.are.equal(1, count("images_setup"))
    assert.are.equal(1, count("images_attach"))
    assert.are.same({ "images_attach", buf }, events[#events - 1])
    assert.is_false(vim.b[buf].omniac_markdown_suspended)
  end)

  it("ignores a completed parse if a new chunk or resize has suspended rendering again", function()
    markdown.suspend(buf)
    markdown.start(buf)
    markdown.render(buf)
    markdown.suspend(buf)
    callbacks[1](nil, {})
    assert.are.equal(0, count("start"))
    assert.are.equal(0, count("render"))
    assert.are.equal(0, count("images_attach"))
    assert.is_true(vim.b[buf].omniac_markdown_suspended)
    markdown.start(buf)
    markdown.render(buf)
    callbacks[2](nil, {})
    assert.are.equal(1, count("render"))
  end)

  it("preserves disabled image and document settings", function()
    for _, config in ipairs({ { enabled = false }, { enabled = true, doc = { enabled = false } } }) do
      Snacks.config.image = config
      markdown.render(buf)
    end
    assert.are.equal(0, count("images_setup"))
    assert.are.equal(0, count("images_attach"))
    assert.are.equal(2, count("render"))
  end)

  it("renders Markdown without Snacks installed or configured", function()
    _G.Snacks = nil
    markdown.render(buf)
    assert.are.equal(0, count("images_setup"))
    assert.are.equal(1, count("render"))
  end)

  it("does not attach document images to permission buffers", function()
    vim.bo[buf].filetype = "omniac-permission"
    markdown.render(buf)
    assert.are.equal(0, count("images_attach"))
    assert.are.equal(1, count("render"))
  end)

  it("keeps Markdown available if the image integration fails", function()
    package.loaded["snacks.image"].doc.attach = function()
      error("image renderer unavailable")
    end
    assert.has_no.errors(function()
      markdown.render(buf)
    end)
    assert.are.equal(1, count("render"))
  end)

  it("renders once when parsing finishes synchronously", function()
    parser.parse = function(_, _, callback)
      callback(nil, {})
      return {}
    end
    markdown.suspend(buf)
    markdown.start(buf)
    markdown.render(buf)
    assert.are.equal(1, count("start"))
    assert.are.equal(1, count("render"))
  end)

  it("ignores a parse result for an older buffer revision", function()
    markdown.suspend(buf)
    markdown.start(buf)
    markdown.render(buf)
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, { "new content" })
    callbacks[1](nil, {})
    assert.are.equal(0, count("start"))
    assert.are.equal(0, count("render"))
  end)

  it("preserves old and new messages when an older parse finishes after a newer one", function()
    local state = require("omniac.ui.state").new()
    local view = require("omniac.ui.chat.view")
    local messages = require("omniac.ui.chat.messages")
    state.chat_buf = buf
    state.card_pinned = true
    state.messages = {
      { role = "You", text = "previous question" },
      { role = "Omniac", text = "previous answer", complete = true },
    }
    local width = 48
    local handlers = {
      valid_buf = vim.api.nvim_buf_is_valid,
      valid_win = function()
        return false
      end,
      width = function()
        return width
      end,
      namespace = vim.api.nvim_create_namespace("omniac.stale-parse-test"),
      header = function() end,
      agent_name = function()
        return "test"
      end,
      add_hl = function() end,
    }
    local function update(opts)
      view.render(state, {}, opts, handlers)
    end
    local deps = {
      request_render = function(_, opts)
        update(opts)
      end,
      render_activity = function() end,
      focus_input_if_active = function() end,
    }
    update()
    assert.are.equal(1, #callbacks)
    messages.append_response_chunk(state, "new answer ", nil, deps)
    width = 70
    update()
    messages.append_response_chunk(state, "continued", nil, deps)
    messages.complete_response(state, nil, {}, deps)
    assert.are.equal(2, #callbacks)

    local expected_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local expected_messages = vim.deepcopy(state.messages)
    local content = table.concat(expected_lines, "\n")
    assert.is_truthy(content:find("previous question", 1, true))
    assert.is_truthy(content:find("previous answer", 1, true))
    assert.is_truthy(content:find("new answer continued", 1, true))
    local writes = 0
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        writes = writes + 1
      end,
    })

    callbacks[2](nil, {})
    callbacks[1](nil, {})
    assert.are.equal(1, count("render"), "only the latest parse should apply formatting")
    assert.are.equal(0, writes, "parse callbacks must not replace the chat text")
    assert.are.same(expected_lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.same(expected_messages, state.messages)
  end)

  it("keeps text available and releases parser state after a timeout", function()
    markdown.suspend(buf)
    markdown.start(buf)
    markdown.render(buf)
    callbacks[1]("TIMEOUT")
    assert.are.equal(0, count("start"))
    assert.are.equal(0, count("render"))
    assert.are.equal(1, count("invalidate"))
    assert.are.same({ "**history**", "partial `code" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.b[buf].omniac_markdown_parsing)
  end)

  it("ignores a callback after the chat buffer is deleted", function()
    markdown.suspend(buf)
    markdown.start(buf)
    markdown.render(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.has_no.errors(function()
      callbacks[1](nil, {})
    end)
    assert.are.equal(0, count("start"))
  end)
end)
