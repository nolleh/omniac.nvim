local diagram = require("omniac.ui.diagram")

describe("Mermaid diagram viewer", function()
  local source, image, requests, placement, origin, source_buf, native

  before_each(function()
    origin = vim.api.nvim_get_current_win()
    source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(origin, source_buf)
    vim.bo[source_buf].filetype = "omniac"
    vim.api.nvim_buf_set_name(source_buf, "omniac://diagram-source")
    native = { size = { width = 1200, height = 2400 } }
    source = {
      buf = source_buf,
      img = { src = "diagram.mmd", info = native },
      ready = function()
        return true
      end,
    }
    requests = {}
    image = {
      terminal = {
        size = function()
          return { cell_width = 10, cell_height = 20 }
        end,
        env = function()
          return { placeholders = true }
        end,
        set_cursor = function() end,
        request = function(request)
          if request.a == "p" then
            table.insert(requests, request)
          end
        end,
      },
      placement = {
        ns = vim.api.nvim_create_namespace("omniac.test.diagram"),
        new = function(buf, src, opts)
          assert.equals(source.img.src, src)
          placement = {
            buf = buf,
            opts = opts,
            id = 2,
            eids = {},
            img = { id = 1, info = native, place = function() end },
            ready = function()
              return true
            end,
            render_grid = function(self, loc)
              self.loc = loc
            end,
            close = function(self)
              self.closed = true
            end,
          }
          return placement
        end,
      },
    }
  end)

  after_each(function()
    diagram.close()
    if vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_delete(source_buf, { force = true })
    end
  end)

  local function press(key)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(placement.buf, "n")) do
      if mapping.lhs == key then
        return mapping.callback()
      end
    end
    error("Missing viewer mapping: " .. key)
  end

  local function last()
    return requests[#requests]
  end

  it("opens a dedicated buffer, fits the whole image, and returns to the source on close", function()
    assert.is_true(diagram.open(source, image))
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    assert.equals("omniac-diagram", vim.bo[buf].filetype)
    assert.equals(0, last().x)
    assert.equals(0, last().y)
    assert.equals(native.size.width, last().w)
    assert.equals(native.size.height, last().h)
    assert.is_true(last().c <= vim.api.nvim_win_get_width(win))
    assert.is_true(last().r <= vim.api.nvim_win_get_height(win))
    assert.is_nil(last().U)
    press("q")
    assert.is_true(placement.closed)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.equals(origin, vim.api.nvim_get_current_win())
  end)

  it("zooms around the visible center and pans only within source bounds", function()
    diagram.open(source, image)
    local full = vim.deepcopy(last())
    press("+")
    assert.is_true(last().h < full.h)
    assert.is_true(math.abs(last().y + last().h / 2 - full.h / 2) <= 1)
    press("1")
    assert.is_truthy(vim.api.nvim_win_get_config(0).title[1][1]:find("100%%"))
    press("j")
    press("l")
    assert.is_true(last().x > 0)
    assert.is_true(last().y > 0)
    for _ = 1, 200 do
      press("j")
      press("l")
    end
    assert.equals(native.size.width, last().x + last().w)
    assert.equals(native.size.height, last().y + last().h)
    for _ = 1, 200 do
      press("k")
      press("h")
    end
    assert.equals(0, last().x)
    assert.equals(0, last().y)
    assert.are.same({ width = 1200, height = 2400 }, source.img.info.size)
  end)

  it("fits width for tall diagrams and can restore a full overview", function()
    diagram.open(source, image)
    press("w")
    assert.equals(native.size.width, last().w)
    assert.equals(vim.api.nvim_win_get_width(0) - 8, last().c)
    assert.is_true(last().h < native.size.height)
    press("j")
    assert.is_true(last().y > 0)
    press("f")
    assert.equals(0, last().y)
    assert.equals(native.size.height, last().h)
  end)

  it("updates the source crop after zoom fills the viewport instead of reusing an inline template", function()
    diagram.open(source, image)
    press("1")
    local before = vim.deepcopy(last())
    press("+")
    assert.equals(before.c, last().c)
    assert.equals(before.r, last().r)
    assert.is_true(last().w < before.w)
    assert.is_true(last().h < before.h)
    assert.is_nil(last().U, "cropped viewer images must use ordinary placements even on placeholder terminals")
    local y = last().y
    press("j")
    assert.is_true(last().y > y)
  end)

  it("refits on resize and preserves manual zoom", function()
    diagram.open(source, image)
    press("w")
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.equals(vim.api.nvim_win_get_width(0) - 8, last().c)
    press("1")
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.is_truthy(vim.api.nvim_win_get_config(0).title[1][1]:find("100%%"))
    assert.is_true(last().c <= vim.api.nvim_win_get_width(0))
  end)

  it("closes when leaving the viewer or deleting the source", function()
    diagram.open(source, image)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(origin)
    assert.is_true(placement.closed)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    diagram.open(source, image)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(origin, vim.api.nvim_create_buf(true, false))
    vim.api.nvim_buf_delete(source_buf, { force = true })
    assert.is_true(placement.closed)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("does not open a window before the source image is ready", function()
    source.ready = function()
      return false
    end
    local windows = #vim.api.nvim_list_wins()
    assert.is_false(diagram.open(source, image))
    assert.equals(windows, #vim.api.nvim_list_wins())
  end)

  it("uses cursor-positioned cropped placements with Unicode placeholder support", function()
    local cursor
    image.terminal.set_cursor = function(pos)
      cursor = pos
    end
    diagram.open(source, image)
    press("1")
    press("j")
    assert.is_nil(last().U)
    assert.is_not_nil(cursor)
    assert.is_true(last().y > 0)
  end)

  it("centers the image and keeps padding when zoomed to fill the viewport", function()
    native.size = { width = 160, height = 240 }
    local cursor
    image.terminal.set_cursor = function(pos)
      cursor = pos
    end
    diagram.open(source, image)
    local win = vim.api.nvim_get_current_win()
    local pos = vim.api.nvim_win_get_position(win)
    assert.equals(pos[1] + 1 + math.floor((vim.api.nvim_win_get_height(win) - last().r) / 2), cursor[1])
    assert.equals(pos[2] + 1 + math.floor((vim.api.nvim_win_get_width(win) - last().c) / 2), cursor[2])
    press("w")
    assert.equals(vim.api.nvim_win_get_width(win) - 8, last().c)
    assert.is_true(last().r <= vim.api.nvim_win_get_height(win) - 4)
    assert.is_true(cursor[1] >= pos[1] + 3)
    assert.is_true(cursor[2] >= pos[2] + 5)
  end)
end)
