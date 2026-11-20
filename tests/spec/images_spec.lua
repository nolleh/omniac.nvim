local images = require("omniac.ui.images")

describe("chat diagram presentation", function()
  local buf, win, other, original, image, placement, previous_calls

  before_each(function()
    other = vim.api.nvim_get_current_buf()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "omniac"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "before", "```mermaid", "graph TD", "A --> B", "```", "after" })
    win = vim.api.nvim_open_win(
      buf,
      false,
      { relative = "editor", row = 0, col = 0, width = 60, height = 20, style = "minimal" }
    )
    original = { snacks = rawget(_G, "Snacks"), image = package.loaded["snacks.image"] }
    previous_calls = 0
    image = {
      placement = { ns = vim.api.nvim_create_namespace("omniac.test.images") },
      config = {
        doc = {
          on_update_pre = function()
            previous_calls = previous_calls + 1
          end,
        },
      },
      setup = function() end,
      doc = { attach = function() end },
    }
    _G.Snacks = { config = { image = { enabled = true } } }
    package.loaded["snacks.image"] = image
    placement = {
      buf = buf,
      opts = { type = "chart", inline = true, max_height = 40, range = { 2, 0, 5, 3 } },
      hide = function(self)
        self.hidden = true
      end,
      show = function(self)
        self.hidden = false
      end,
      update = function(self)
        image.config.doc.on_update_pre(self)
      end,
    }
    images.attach(buf)
  end)

  after_each(function()
    vim.api.nvim_set_current_buf(other)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    _G.Snacks = original.snacks
    package.loaded["snacks.image"] = original.image
  end)

  it("fits diagrams to the chat window without changing document defaults", function()
    image.config.doc.on_update_pre(placement)
    assert.is_true(placement.opts.conceal)
    assert.equals(54, placement.opts.width)
    assert.equals(17, placement.opts.height)
    assert.equals(17, placement.opts.max_height)
    assert.is_true(vim.b[buf].snacks_image_conceal)
    assert.is_nil(image.config.doc.height)
    assert.is_nil(image.config.doc.conceal)
    assert.equals(1, previous_calls)
  end)

  it("keeps images visible outside the block and reveals code inside it", function()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    image.config.doc.on_update_pre(placement)
    assert.is_true(vim.wait(200, function()
      return placement.hidden == false
    end))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    image.config.doc.on_update_pre(placement)
    assert.is_true(vim.wait(200, function()
      return placement.hidden == true
    end))
    vim.api.nvim_set_current_buf(other)
    assert.is_true(
      vim.wait(200, function()
        return placement.hidden == false
      end),
      "leaving chat should restore the image even when its cursor stays inside the code"
    )
  end)

  it("preserves smaller explicit heights and calls existing callbacks once after repeated attachment", function()
    placement.opts.height = 12
    images.attach(buf)
    images.attach(buf)
    image.config.doc.on_update_pre(placement)
    assert.equals(12, placement.opts.height)
    assert.equals(12, placement.opts.max_height)
    assert.equals(1, previous_calls)
  end)

  it("leaves ordinary Markdown and non-chart images unchanged", function()
    vim.bo[buf].filetype = "markdown"
    image.config.doc.on_update_pre(placement)
    assert.is_nil(placement.opts.height)
    assert.equals(40, placement.opts.max_height)
    assert.is_nil(placement.opts.conceal)
    vim.bo[buf].filetype = "omniac"
    placement.opts.type = "image"
    image.config.doc.on_update_pre(placement)
    assert.is_nil(placement.opts.height)
    assert.is_nil(placement.opts.conceal)
    assert.equals(2, previous_calls)
  end)

  it("respects a user-configured maximum diagram height", function()
    Snacks.config.image.doc = { max_height = 10 }
    placement.opts.max_height = 10
    image.config.doc.on_update_pre(placement)
    assert.equals(10, placement.opts.height)
    assert.equals(10, placement.opts.max_height)
  end)

  it("refits existing diagrams when the chat window shrinks and grows", function()
    image.config.doc.on_update_pre(placement)
    vim.api.nvim_win_set_config(win, { width = 40, height = 10 })
    vim.api.nvim_exec_autocmds("WinResized", { group = "omniac.images." .. buf })
    assert.equals(36, placement.opts.width)
    assert.equals(8, placement.opts.height)
    vim.api.nvim_win_set_config(win, { width = 60, height = 20 })
    vim.api.nvim_exec_autocmds("WinResized", { group = "omniac.images." .. buf })
    assert.equals(54, placement.opts.width)
    assert.equals(17, placement.opts.height)
  end)

  it("ignores scheduled updates after a diagram is closed", function()
    image.config.doc.on_update_pre(placement)
    placement.closed = true
    vim.wait(50)
    assert.is_nil(placement.hidden)
  end)

  it("collapses reserved image rows while the source is visible", function()
    local ns = image.placement.ns
    local source = vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {})
    local overflow = vim.api.nvim_buf_set_extmark(buf, ns, 4, 0, {
      virt_lines = { { { "" } }, { { "" } } },
    })
    local concealed = vim.api.nvim_buf_set_extmark(buf, ns, 3, 0, { conceal_lines = "" })
    placement.eids = { source, overflow, concealed }
    local callback_eids
    placement.opts.on_update = function(p)
      callback_eids = vim.deepcopy(p.eids)
    end
    image.config.doc.on_update_pre(placement)
    placement.hidden = false
    placement.opts.on_update(placement)
    assert.equals(3, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    placement.hidden = true
    placement.opts.on_update(placement)
    assert.are.same({ source }, placement.eids)
    assert.are.same({ source }, callback_eids)
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  end)
end)
