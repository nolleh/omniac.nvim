local M = {}

function M.open(before_lines, after_lines, opts)
  opts = opts or {}

  local before_buf = vim.api.nvim_create_buf(false, true)
  local after_buf = vim.api.nvim_create_buf(false, true)
  local origin_win = vim.api.nvim_get_current_win()

  vim.bo[before_buf].buftype = "nofile"
  vim.bo[before_buf].bufhidden = "wipe"
  vim.bo[before_buf].swapfile = false
  vim.bo[before_buf].modifiable = true
  vim.bo[after_buf].buftype = "acwrite"
  vim.bo[after_buf].bufhidden = "wipe"
  vim.bo[after_buf].swapfile = false
  vim.bo[after_buf].modifiable = true

  vim.api.nvim_buf_set_lines(before_buf, 0, -1, false, before_lines or {})
  vim.api.nvim_buf_set_lines(after_buf, 0, -1, false, after_lines or {})

  vim.api.nvim_set_current_win(origin_win)
  vim.api.nvim_win_set_buf(origin_win, before_buf)
  vim.wo[origin_win].diff = true

  vim.cmd("vnew")
  local after_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(after_win, after_buf)
  vim.wo[after_win].diff = true

  if opts.title then
    vim.api.nvim_buf_set_name(after_buf, opts.title)
  end

  return {
    before_buf = before_buf,
    after_buf = after_buf,
  }
end

function M.open_file(path, proposed_lines, opts)
  opts = opts or {}

  local before_lines = vim.fn.readfile(path)
  local after_lines = proposed_lines or vim.deepcopy(before_lines)
  local handles = M.open(before_lines, after_lines, opts)

  vim.api.nvim_buf_set_name(handles.after_buf, path)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = handles.after_buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(handles.after_buf, 0, -1, false)
      vim.fn.writefile(lines, path)
      vim.bo[handles.after_buf].modified = false
    end,
  })

  return handles
end

return M
