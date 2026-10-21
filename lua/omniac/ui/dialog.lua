local text = require("omniac.ui.text")

local M = {}

function M.valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.stop_insert()
  if vim.fn.mode():match("^[iR]") then
    pcall(vim.cmd, "stopinsert")
  end
end

function M.normalize_inline(value)
  return tostring(value or ""):gsub("[\r\n]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.fit_inline(value, size)
  return text.fit(M.normalize_inline(value), size)
end

function M.create_buffer(opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  if opts.name then
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = opts.filetype or ""
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  return buf
end

function M.open_list_frame(buf, footer_buf, opts)
  opts = opts or {}
  local width = math.min(math.max(72, math.floor(vim.o.columns * 0.58)), math.max(50, vim.o.columns - 8))
  local total_height = math.min(math.max(14, math.floor(vim.o.lines * 0.58)), math.max(12, vim.o.lines - 8))
  local height = math.max(8, total_height - 3)
  local row = math.max(0, math.floor((vim.o.lines - total_height - 4) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = "center",
  })
  local footer_win = vim.api.nvim_open_win(footer_buf, false, {
    relative = "editor",
    width = width,
    height = 1,
    row = row + height + 3,
    col = col,
    style = "minimal",
    border = "rounded",
  })

  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winhighlight = "FloatBorder:" .. opts.border_group .. ",FloatTitle:" .. opts.title_group
  vim.wo[footer_win].cursorline = false
  vim.wo[footer_win].wrap = false
  vim.wo[footer_win].signcolumn = "no"
  vim.wo[footer_win].winhighlight = "FloatBorder:" .. opts.border_group

  return win, footer_win
end

function M.set_lines(buf, lines)
  if not M.valid_buf(buf) then
    return false
  end
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  return true
end

function M.release(state, window_keys, buffer_keys)
  for _, key in ipairs(window_keys or {}) do
    local win = state[key]
    if M.valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    state[key] = nil
  end
  for _, key in ipairs(buffer_keys or {}) do
    local buf = state[key]
    if M.valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    state[key] = nil
  end
end

return M
