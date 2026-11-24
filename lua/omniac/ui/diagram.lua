local M = {}
local active

local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

local function window_config()
  local width = math.max(1, math.min(240, vim.o.columns - 4, math.floor(vim.o.columns * 0.9)))
  local height = math.max(1, math.min(180, vim.o.lines - 6, math.floor(vim.o.lines * 0.8)))
  return {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    zindex = 100,
    title = " Mermaid ",
    title_pos = "center",
    footer = " +/- zoom  hjkl move  f fit  w width  1 reset  q close ",
    footer_pos = "center",
  }
end

local function viewport(view)
  local width = vim.api.nvim_win_get_width(view.win)
  local height = vim.api.nvim_win_get_height(view.win)
  local padding_x = math.min(4, math.floor((width - 1) / 2))
  local padding_y = math.min(2, math.floor((height - 1) / 2))
  return width - padding_x * 2, height - padding_y * 2
end

local function geometry(view)
  local size = view.placement.img.info.size
  local cell = view.image.terminal.size()
  local available_width, available_height = viewport(view)
  local width = math.min(available_width, math.ceil(size.width / cell.cell_width * view.zoom))
  local height = math.min(available_height, math.ceil(size.height / cell.cell_height * view.zoom))
  local crop_width = math.min(size.width, math.ceil(width * cell.cell_width / view.zoom))
  local crop_height = math.min(size.height, math.ceil(height * cell.cell_height / view.zoom))
  view.x = clamp(math.floor(view.x), 0, size.width - crop_width)
  view.y = clamp(math.floor(view.y), 0, size.height - crop_height)
  return {
    width = width,
    height = height,
    x = view.x,
    y = view.y,
    w = crop_width,
    h = crop_height,
    left = math.floor((vim.api.nvim_win_get_width(view.win) - width) / 2),
    top = math.floor((vim.api.nvim_win_get_height(view.win) - height) / 2),
  }
end

local function render(view)
  local placement = view.placement
  if active ~= view or not vim.api.nvim_win_is_valid(view.win) or not placement:ready() then
    return
  end
  local rect = geometry(view)
  local terminal = view.image.terminal
  -- Use a separate placement of the cached image. Cropping is in source pixels;
  -- c/r specify the display size, so neither pan nor zoom changes the chat image.
  placement.img:place(placement)
  terminal.request({ a = "d", d = "i", i = placement.img.id, p = placement.id })
  local request = {
    a = "p",
    i = placement.img.id,
    p = placement.id,
    C = 1,
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
    c = rect.width,
    r = rect.height,
  }
  vim.api.nvim_buf_clear_namespace(view.buf, view.image.placement.ns, 0, -1)
  placement.eids = {}
  vim.api.nvim_win_set_config(
    view.win,
    { title = string.format(" Mermaid · %d%% ", math.floor(view.zoom * 100 + 0.5)) }
  )
  vim.api.nvim_win_set_cursor(view.win, { 1, 0 })
  vim.api.nvim_win_call(view.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, leftcol = 0 })
  end)
  vim.cmd("redraw")
  -- Unicode placeholder placements are templates for full-image rendering;
  -- changing a crop on that template does not update the visible source region
  -- reliably. A fixed viewer can use an ordinary placement with explicit crop
  -- coordinates instead, independently of the chat's inline template.
  local pos = vim.api.nvim_win_get_position(view.win)
  terminal.set_cursor({ pos[1] + 1 + rect.top, pos[2] + 1 + rect.left })
  terminal.request(request)
end

local function fit(view, width_only)
  local size = view.placement.img.info.size
  local cell = view.image.terminal.size()
  local width, height = viewport(view)
  local scale = width * cell.cell_width / size.width
  view.minimum_zoom = math.min(0.05, scale, height * cell.cell_height / size.height)
  if not width_only then
    scale = math.min(1, scale, height * cell.cell_height / size.height)
  end
  view.zoom = math.min(8, scale)
  view.x, view.y = 0, 0
  view.mode = width_only and "width" or "fit"
  render(view)
end

local function zoom(view, factor)
  local before = geometry(view)
  view.zoom = clamp(view.zoom * factor, view.minimum_zoom, 8)
  local after = geometry(view)
  view.x = before.x + (before.w - after.w) / 2
  view.y = before.y + (before.h - after.h) / 2
  view.mode = "manual"
  render(view)
end

local function pan(view, dx, dy)
  local cell = view.image.terminal.size()
  view.x = view.x + dx * cell.cell_width / view.zoom
  view.y = view.y + dy * cell.cell_height / view.zoom
  view.mode = "manual"
  render(view)
end

function M.close()
  local view = active
  if not view then
    return
  end
  active = nil
  pcall(vim.api.nvim_del_augroup_by_id, view.group)
  view.image.terminal.request({ a = "d", d = "i", i = view.placement.img.id, p = view.placement.id })
  view.placement:close()
  local restore = vim.api.nvim_get_current_win() == view.win
  if vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_close(view.win, true)
  end
  if vim.api.nvim_buf_is_valid(view.buf) then
    vim.api.nvim_buf_delete(view.buf, { force = true })
  end
  if restore and vim.api.nvim_win_is_valid(view.origin_win) then
    vim.api.nvim_set_current_win(view.origin_win)
  end
end

function M.open(source, image)
  if not source.img or not source:ready() or not source.img.info or not source.img.info.size then
    vim.notify("Diagram is still rendering. Try again shortly.", vim.log.levels.INFO, { title = "Omniac" })
    return false
  end
  M.close()
  local view = { image = image, origin_win = vim.api.nvim_get_current_win(), zoom = 1, x = 0, y = 0 }
  view.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[view.buf].bufhidden = "wipe"
  vim.bo[view.buf].swapfile = false
  vim.bo[view.buf].filetype = "omniac-diagram"
  vim.bo[view.buf].modifiable = false
  view.win = vim.api.nvim_open_win(view.buf, true, window_config())
  vim.wo[view.win].wrap = false
  vim.wo[view.win].cursorline = false
  vim.wo[view.win].scrolloff = 0
  view.group = vim.api.nvim_create_augroup("omniac.diagram", { clear = true })
  view.placement = image.placement.new(view.buf, source.img.src, { inline = true, pos = { 1, 0 } })
  -- Snacks may update a placement after conversion completes. Route those updates
  -- through this viewport renderer rather than its whole-image fitting logic.
  view.placement.update = function()
    render(view)
  end
  active = view

  local function bind(keys, callback, description)
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, callback, { buffer = view.buf, nowait = true, desc = description })
    end
  end
  bind({ "+", "=", "<ScrollWheelUp>" }, function()
    zoom(view, 1.25)
  end, "Zoom diagram in")
  bind({ "-", "<ScrollWheelDown>" }, function()
    zoom(view, 1 / 1.25)
  end, "Zoom diagram out")
  bind({ "h", "<Left>" }, function()
    pan(view, -4, 0)
  end, "Move diagram viewport left")
  bind({ "l", "<Right>" }, function()
    pan(view, 4, 0)
  end, "Move diagram viewport right")
  bind({ "k", "<Up>" }, function()
    pan(view, 0, -3)
  end, "Move diagram viewport up")
  bind({ "j", "<Down>" }, function()
    pan(view, 0, 3)
  end, "Move diagram viewport down")
  bind({ "f" }, function()
    fit(view, false)
  end, "Fit entire diagram")
  bind({ "w" }, function()
    fit(view, true)
  end, "Fit diagram width")
  bind({ "1" }, function()
    view.zoom, view.x, view.y, view.mode = 1, 0, 0, "manual"
    render(view)
  end, "Reset diagram to native size")
  bind({ "q", "<Esc>" }, M.close, "Close diagram viewer")

  vim.api.nvim_create_autocmd("VimResized", {
    group = view.group,
    callback = function()
      if active ~= view then
        return
      end
      vim.api.nvim_win_set_config(view.win, window_config())
      if view.mode == "fit" or view.mode == "width" then
        fit(view, view.mode == "width")
      else
        render(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = view.group,
    pattern = { tostring(view.win), tostring(view.origin_win) },
    callback = M.close,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = view.group,
    buffer = source.buf,
    callback = M.close,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
    group = view.group,
    buffer = view.buf,
    callback = M.close,
  })
  fit(view, false)
  return true
end

return M
