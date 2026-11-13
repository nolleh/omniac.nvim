local helpers = require("tests.helpers")

describe("Omniac filetype isolation", function()
  after_each(helpers.cleanup_after_test)

  it("does not run Markdown document hooks for chat or permission buffers", function()
    local group = vim.api.nvim_create_augroup("OmniacFiletypeIsolationTest", { clear = true })
    local document_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "markdown",
      callback = function(args)
        vim.b[args.buf].markdown_document_hook = true
        vim.api.nvim_buf_create_user_command(args.buf, "MarkdownDocumentPreview", function() end, {})
      end,
    })

    local ok, err = xpcall(function()
      package.loaded["omniac.ui"] = nil
      local state = require("omniac.ui").open({ ui = { chat_width = 48 } }, function() end)
      require("omniac.ui.choice_dialog").open({ { optionId = "allow", name = "Allow" } }, {
        prompt = "Permission requested",
        body = "**Markdown body**",
      }, function() end)
      local permission_buf = vim.fn.bufnr("omniac://permission")
      for _, buf in ipairs({ state.chat_buf, permission_buf }) do
        assert.is_nil(vim.b[buf].markdown_document_hook)
        assert.is_nil(vim.api.nvim_buf_get_commands(buf, {}).MarkdownDocumentPreview)
      end
      vim.bo[document_buf].filetype = "markdown"
      assert.is_true(vim.b[document_buf].markdown_document_hook, "normal Markdown documents must be unaffected")
    end, debug.traceback)

    vim.api.nvim_del_augroup_by_id(group)
    vim.api.nvim_buf_delete(document_buf, { force = true })
    if not ok then
      error(err)
    end
  end)

  it("keeps existing renderer settings while registering and attaching Omniac filetypes", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original_state = package.loaded["render-markdown.state"]
    local original_manager = package.loaded["render-markdown.core.manager"]
    local callback = function() end
    local cached = { enabled = false }
    local state =
      { enabled = true, file_types = { "markdown", "quarto" }, cache = { [buf] = cached }, on = { render = callback } }
    local attached, rendered = {}, {}
    package.loaded["render-markdown.state"] = state
    package.loaded["render-markdown.core.manager"] = {
      attach = function(target)
        table.insert(attached, target)
      end,
    }
    package.loaded["render-markdown"] = {
      initialized = true,
      setup = function()
        error("an existing renderer setup must not be replaced")
      end,
      render = function(ctx)
        table.insert(rendered, ctx.buf)
      end,
    }

    local ok, err = xpcall(function()
      for _, filetype in ipairs({ "omniac", "omniac-permission", "omniac" }) do
        vim.bo[buf].filetype = filetype
        require("omniac.ui.markdown").render(buf)
        assert.are.equal("markdown", vim.treesitter.language.get_lang(filetype))
      end
      assert.are.same({ "markdown", "quarto", "omniac", "omniac-permission" }, state.file_types)
      assert.are.equal(callback, state.on.render)
      assert.is_true(cached.enabled, "queued updates must not retain Omniac's temporary suspension")
      assert.are.same({ buf, buf, buf }, attached)
      assert.are.same({ buf, buf, buf }, rendered)
    end, debug.traceback)

    package.loaded["render-markdown.state"] = original_state
    package.loaded["render-markdown.core.manager"] = original_manager
    package.loaded["render-markdown"] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
    if not ok then
      error(err)
    end
  end)
end)
