local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true

describe("chat tail following", function()
  local ui, config, buf, win

  local function at_bottom()
    return vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      return vim.api.nvim_win_text_height(win, {
        start_row = view.topline - 1,
        start_vcol = view.skipcol,
      }).all <= vim.api.nvim_win_get_height(win)
    end)
  end

  local function append(value)
    ui.append_response_chunk("\n" .. value .. "\n", config)
    assert_true(
      vim.wait(300, function()
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find(value, 1, true) ~= nil
      end),
      "streamed content should render"
    )
  end

  before_each(function()
    helpers.cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    ui = require("omniac.ui")
    config = { ui = { chat_width = 48, mascot_motion = false } }
    ui.open(config, function() end)
    ui.add_message(
      "Omniac",
      table.concat(
        vim.tbl_map(function(index)
          return "history " .. index
        end, vim.fn.range(1, 60)),
        "\n"
      ),
      config
    )
    buf = vim.fn.bufnr("omniac")
    win = vim.fn.bufwinid(buf)
    vim.wait(30, function()
      return false
    end)
    vim.cmd("stopinsert")
    vim.cmd("redraw")
    assert_true(at_bottom())
  end)

  after_each(helpers.cleanup_after_test)

  it("follows with the cursor above the last line while the tail is visible", function()
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf) - 3, 0 })
    assert_true(at_bottom())
    append("cursor above tail")
    assert_true(at_bottom(), "visible tail should continue following")
    assert_equal(vim.api.nvim_win_get_cursor(win)[1], vim.api.nvim_buf_line_count(buf))
  end)

  it("continues following with an editor window focused", function()
    for _, other in ipairs(vim.api.nvim_list_wins()) do
      if not vim.w[other].omniac_ui then
        vim.api.nvim_set_current_win(other)
        break
      end
    end
    local active = vim.api.nvim_get_current_win()
    assert_true(active ~= win)
    append("editor focus tail")
    assert_true(at_bottom())
    assert_equal(vim.api.nvim_get_current_win(), active, "following must preserve focus")
  end)

  it("preserves a scrolled view across chunks and resumes on returning to the bottom", function()
    vim.api.nvim_set_current_win(win)
    helpers.feed("ggzt")
    local before = vim.fn.winsaveview()
    append("first paused chunk")
    append("second paused chunk")
    assert_equal(vim.fn.winsaveview().topline, before.topline)
    assert_equal(vim.api.nvim_win_get_cursor(win)[1], before.lnum)
    helpers.feed("Gzb")
    append("resumed tail")
    assert_true(at_bottom(), "returning to the bottom should resume following")
  end)

  it("detects scrolling away and back between streamed renders", function()
    vim.api.nvim_set_current_win(win)
    helpers.feed("ggzt")
    helpers.feed("Gzb")
    append("tail after round trip")
    assert_true(at_bottom())
  end)

  it("keeps a paused view paused after resizing", function()
    vim.api.nvim_set_current_win(win)
    helpers.feed("ggzt")
    ui.resize(56)
    local before = vim.fn.winsaveview()
    append("paused after resize")
    assert_equal(vim.fn.winsaveview().topline, before.topline)
    assert_equal(vim.api.nvim_win_get_cursor(win)[1], before.lnum)
  end)

  it("keeps following after resizing", function()
    ui.resize(56)
    append("following after resize")
    assert_true(at_bottom())
  end)

  it("keeps the end of a long wrapped table visible while streaming", function()
    append("| " .. string.rep("wide table cell ", 120) .. " |")
    assert_true(at_bottom(), "the full wrapped tail should remain visible")
    append("after wrapped table")
    assert_true(at_bottom())
  end)

  it("recognizes scrolling within a single wrapped buffer line", function()
    local follow = require("omniac.ui.chat.follow")
    vim.api.nvim_set_current_win(win)
    vim.wo[win].smoothscroll = true
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("wrapped text ", 200) })
    vim.bo[buf].modifiable = false
    vim.cmd("normal! G$zb")
    local state = { chat_buf = buf, chat_win = win, chat_following = true }
    follow.remember(state)
    vim.cmd("normal! gg0zt")
    follow.observe(state)
    assert_equal(state.chat_following, false, "seeing the last buffer line does not mean its end is visible")
    vim.cmd("normal! G$zb")
    follow.observe(state)
    assert_equal(state.chat_following, true)
  end)

  it("preserves a visual selection at the tail", function()
    vim.api.nvim_set_current_win(win)
    helpers.feed("Gv")
    local cursor = vim.api.nvim_win_get_cursor(win)
    append("tail while selecting")
    assert_equal(vim.api.nvim_win_get_cursor(win)[1], cursor[1])
    helpers.feed("<Esc>")
    append("tail after selecting")
    assert_true(at_bottom())
  end)
end)
