local M = {}
local configured = setmetatable({}, { __mode = "k" })
local tracked = {}
local requested_sizes = setmetatable({}, { __mode = "k" })
local compacted = setmetatable({}, { __mode = "k" })

local function compact_hidden(placement, image)
  if compacted[placement] then
    return
  end
  compacted[placement] = true
  local previous = placement.opts.on_update
  placement.opts.on_update = function(item)
    if item.hidden and vim.api.nvim_buf_is_valid(item.buf) then
      local ns = image.placement.ns
      for i = #(item.eids or {}), 1, -1 do
        local id = item.eids[i]
        local mark = vim.api.nvim_buf_get_extmark_by_id(item.buf, ns, id, { details = true })
        local details = mark[3]
        -- Snacks reserves blank image rows even while showing the source.
        -- Remove those rows (and image-only line concealment) until show().
        if details and (details.virt_lines or details.conceal_lines) then
          vim.api.nvim_buf_del_extmark(item.buf, ns, id)
          table.remove(item.eids, i)
        end
      end
    end
    if previous then
      previous(item)
    end
  end
end

local function fit_window(placement, config, image)
  local width
  for _, win in ipairs(vim.fn.win_findbuf(placement.buf)) do
    local w = vim.api.nvim_win_get_width(win)
    width = math.min(width or w, w)
  end
  if not width then
    return
  end
  local requested = requested_sizes[placement]
  if not requested then
    requested = { width = placement.opts.width, height = placement.opts.height }
    requested_sizes[placement] = requested
  end
  local limits = type(config.doc) == "table" and config.doc or {}
  width = math.max(1, math.floor(width * 0.9))
  local size = placement.img and placement.img.info and placement.img.info.size
  if size then
    -- Mermaid's rendered width already includes node sizes and column spacing.
    -- Its PNG includes the terminal render scale, so convert pixels directly
    -- to cells instead of enlarging narrow diagrams to a viewport percentage.
    local terminal = image.terminal.size()
    -- Use 85% of the native size for a more compact inline reading scale.
    local natural_width = math.max(1, math.ceil(size.width / terminal.cell_width * 0.85))
    width = math.min(width, natural_width)
  end
  width = math.min(width, requested.width or width, limits.max_width or width)
  -- Choose a reading width first. Diagram length must not reduce its scale;
  -- Snacks derives the height from the aspect ratio and reserves scroll rows.
  local height = requested.height or math.huge
  placement.opts.width, placement.opts.max_width = width, width
  placement.opts.height, placement.opts.max_height = height, height
end

local function valid_chart(placement)
  return not placement.closed
    and vim.api.nvim_buf_is_valid(placement.buf)
    and vim.bo[placement.buf].filetype == "omniac"
    and placement.opts.inline
    and placement.opts.type == "chart"
end

local function update_visibility(placement)
  if not valid_chart(placement) then
    return
  end
  local range = placement.opts.range
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local editing = vim.api.nvim_get_current_buf() == placement.buf and range and row >= range[1] and row <= range[3]
  if editing then
    placement:hide()
  else
    placement:show()
  end
end

local function track(placement)
  local buf = placement.buf
  if not tracked[buf] then
    tracked[buf] = setmetatable({}, { __mode = "k" })
    local group = vim.api.nvim_create_augroup("omniac.images." .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufLeave" }, {
      group = group,
      buffer = buf,
      callback = function()
        vim.schedule(function()
          for item in pairs(tracked[buf] or {}) do
            update_visibility(item)
          end
        end)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      callback = function()
        tracked[buf] = nil
        vim.api.nvim_del_augroup_by_id(group)
      end,
    })
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      group = group,
      callback = function()
        for item in pairs(tracked[buf] or {}) do
          if valid_chart(item) then
            item:update()
          end
        end
      end,
    })
  end
  tracked[buf][placement] = true
  vim.schedule(function()
    update_visibility(placement)
  end)
end

function M.attach(buf)
  local snacks = rawget(_G, "Snacks")
  local config = type(snacks) == "table" and snacks.config and snacks.config.image
  if
    not vim.api.nvim_buf_is_valid(buf)
    or vim.bo[buf].filetype ~= "omniac"
    or type(config) ~= "table"
    or config.enabled ~= true
    or (type(config.doc) == "table" and config.doc.enabled == false)
  then
    return
  end
  local ok, image = pcall(require, "snacks.image")
  if not ok then
    return
  end
  local attached = pcall(function()
    local doc = image.config and image.config.doc
    if doc and not configured[doc] then
      local previous = doc.on_update_pre
      doc.on_update_pre = function(placement)
        if previous then
          previous(placement)
        end
        if valid_chart(placement) then
          placement.opts.conceal = true
          -- Fit to the chat width and scroll vertically for tall diagrams.
          fit_window(placement, config, image)
          compact_hidden(placement, image)
          track(placement)
        end
      end
      configured[doc] = true
    end
    vim.b[buf].snacks_image_conceal = true
    -- Scratch buffers may never trigger Snacks' file-read initialization.
    image.setup()
    image.doc.attach(buf)
  end)
  return attached
end

return M
