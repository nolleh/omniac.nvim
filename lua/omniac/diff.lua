local M = {}
local active_reviews = {}
local next_review_id = 1

function M.open(before_lines, after_lines, opts)
  opts = opts or {}

  local before_buf = vim.api.nvim_create_buf(false, true)
  local after_buf = vim.api.nvim_create_buf(false, true)
  local origin_win = opts.origin_win or vim.api.nvim_get_current_win()

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
  vim.bo[before_buf].modified = false
  vim.bo[after_buf].modified = false

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

function M.open_review(path, before_lines, after_lines, opts, callback)
  opts = opts or {}
  local review_id = tostring(next_review_id)
  next_review_id = next_review_id + 1

  local handles = M.open(before_lines, after_lines, {
    title = opts.title or ("Omniac review: " .. (path or "change")),
    origin_win = opts.origin_win,
  })

  vim.b[handles.before_buf].omniac_diff_review_id = review_id
  vim.b[handles.after_buf].omniac_diff_review_id = review_id
  vim.b[handles.after_buf].omniac_diff_path = path

  active_reviews[review_id] = {
    id = review_id,
    path = path,
    before_buf = handles.before_buf,
    after_buf = handles.after_buf,
    callback = callback,
  }

  vim.notify("Review Omniac changes, then run :OmniacDiffAccept or :OmniacDiffDeny", vim.log.levels.INFO, {
    title = "omniac approval",
  })

  return handles
end

local function close_review_windows(review)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf == review.before_buf or buf == review.after_buf then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs({ review.before_buf, review.after_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function current_review()
  local buf = vim.api.nvim_get_current_buf()
  local review_id = vim.b[buf].omniac_diff_review_id
  if not review_id then
    for id, review in pairs(active_reviews) do
      if review.before_buf == buf or review.after_buf == buf then
        review_id = id
        break
      end
    end
  end

  return review_id and active_reviews[review_id] or nil
end

function M.accept_current_review()
  local review = current_review()
  if not review then
    vim.notify("No Omniac diff approval is active in this buffer", vim.log.levels.WARN)
    return
  end

  active_reviews[review.id] = nil
  if review.callback then
    review.callback(true)
  end
  close_review_windows(review)
end

function M.deny_current_review()
  local review = current_review()
  if not review then
    vim.notify("No Omniac diff approval is active in this buffer", vim.log.levels.WARN)
    return
  end

  active_reviews[review.id] = nil
  if review.callback then
    review.callback(false)
  end
  close_review_windows(review)
end

return M
