local M = {}
local windows = require("omniac.changes.windows")
local active_reviews = {}
local next_review_id = 1
local augroup = vim.api.nvim_create_augroup("omniac.diff", { clear = false })

local function close_review(review, accepted)
  if not review or review.closed then
    return
  end
  review.closed = true

  local accepted_lines = nil
  if accepted and vim.api.nvim_buf_is_valid(review.after_buf) then
    accepted_lines = vim.api.nvim_buf_get_lines(review.after_buf, 0, -1, false)
  end

  active_reviews[review.id] = nil
  if review.callback then
    review.callback(accepted, accepted_lines, review.edited == true)
  end
  windows.close(review)
  if review.on_close then
    vim.schedule(review.on_close)
  end
end

local function close_stale_reviews()
  local reviews = {}
  for _, review in pairs(active_reviews) do
    table.insert(reviews, review)
  end
  for _, review in ipairs(reviews) do
    review.on_close = nil
    close_review(review, false)
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    pcall(vim.api.nvim_win_call, win, function()
      pcall(vim.fn.clearmatches)
      vim.cmd("silent! diffoff!")
    end)
  end
end

function M.first_diff_line(before_lines, after_lines)
  local limit = math.max(#before_lines, #after_lines)
  for index = 1, limit do
    if before_lines[index] ~= after_lines[index] then
      return index
    end
  end
  return 1
end

local function set_window_cursor(win, line)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local target_line = math.max(1, math.min(line, line_count))
  pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
end

function M.select_review_window()
  local current = vim.api.nvim_get_current_win()
  for _, review in pairs(active_reviews) do
    if not review.separate_tab and review.before_win and vim.api.nvim_win_is_valid(review.before_win) then
      return review.before_win
    end
  end
  if vim.api.nvim_win_is_valid(current) and windows.is_review_candidate(current) then
    return current
  end

  local best_win = nil
  local best_width = -1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if windows.is_review_candidate(win) then
      local width = vim.api.nvim_win_get_width(win)
      if width > best_width then
        best_win = win
        best_width = width
      end
    end
  end

  if best_win and vim.api.nvim_win_is_valid(best_win) then
    return best_win
  end

  return nil
end

function M.open(before_lines, after_lines, opts)
  opts = opts or {}
  windows.stop_insert()

  local before_buf = vim.api.nvim_create_buf(false, true)
  local after_buf = vim.api.nvim_create_buf(false, true)
  local origin_win = opts.origin_win
  if not origin_win or not vim.api.nvim_win_is_valid(origin_win) then
    origin_win = M.select_review_window()
  end
  if not origin_win then
    vim.cmd("topleft vnew")
    origin_win = vim.api.nvim_get_current_win()
  end
  local origin_buf = vim.api.nvim_win_get_buf(origin_win)
  local origin_win_options = windows.capture_options(origin_win)

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
  vim.bo[before_buf].modifiable = false
  vim.bo[after_buf].modifiable = true

  local filetype = opts.filetype or windows.detect_filetype(opts.path, origin_buf)
  if filetype and filetype ~= "" then
    vim.bo[before_buf].filetype = filetype
    vim.bo[after_buf].filetype = filetype
  end

  local before_win
  local after_win
  local fixed_widths

  if opts.separate_tab then
    vim.cmd("tabnew")
    before_win = vim.api.nvim_get_current_win()
    windows.replace_split_buffer(before_win, before_buf, origin_buf)
    windows.enable_diff(before_win)

    vim.cmd("vnew")
    after_win = vim.api.nvim_get_current_win()
    windows.replace_split_buffer(after_win, after_buf, origin_buf)
    windows.enable_diff(after_win)
  else
    fixed_widths = windows.collect_fixed_widths()
    vim.api.nvim_set_current_win(origin_win)
    vim.api.nvim_win_set_buf(origin_win, before_buf)
    before_win = origin_win
    windows.enable_diff(before_win)

    vim.cmd("rightbelow vnew")
    after_win = vim.api.nvim_get_current_win()
    windows.replace_split_buffer(after_win, after_buf, origin_buf)
    windows.enable_diff(after_win)
    windows.equalize(before_win, after_win, fixed_widths)
  end
  vim.bo[after_buf].modifiable = true

  if opts.title then
    vim.api.nvim_buf_set_name(after_buf, opts.title)
  end

  windows.stop_insert()
  vim.schedule(function()
    if
      vim.api.nvim_win_is_valid(after_win)
      and vim.api.nvim_get_current_win() == after_win
      and vim.api.nvim_win_get_buf(after_win) == after_buf
    then
      windows.stop_insert()
    end
  end)
  local cursor_line = M.first_diff_line(before_lines or {}, after_lines or {})
  set_window_cursor(after_win, cursor_line)
  set_window_cursor(before_win, cursor_line)

  return {
    before_buf = before_buf,
    after_buf = after_buf,
    before_win = before_win,
    after_win = after_win,
    origin_buf = origin_buf,
    origin_win_options = origin_win_options,
    fixed_widths = fixed_widths,
    separate_tab = opts.separate_tab == true,
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
  close_stale_reviews()

  local review_id = tostring(next_review_id)
  next_review_id = next_review_id + 1

  local handles = M.open(before_lines, after_lines, {
    title = opts.title or ("Omniac review: " .. (path or "change")),
    origin_win = opts.origin_win,
    separate_tab = opts.separate_tab,
    path = path,
  })

  vim.b[handles.before_buf].omniac_diff_review_id = review_id
  vim.b[handles.after_buf].omniac_diff_review_id = review_id
  vim.b[handles.after_buf].omniac_diff_path = path

  active_reviews[review_id] = {
    id = review_id,
    path = path,
    before_buf = handles.before_buf,
    after_buf = handles.after_buf,
    before_win = handles.before_win,
    after_win = handles.after_win,
    origin_buf = handles.origin_buf,
    origin_win_options = handles.origin_win_options,
    fixed_widths = handles.fixed_widths,
    separate_tab = handles.separate_tab,
    callback = callback,
    on_close = opts.on_close,
    edited = false,
  }

  vim.api.nvim_buf_attach(handles.after_buf, false, {
    on_lines = function()
      local review = active_reviews[review_id]
      if review then
        review.edited = true
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = handles.after_buf,
    callback = function()
      local review = active_reviews[review_id]
      if not review then
        return
      end
      vim.bo[handles.after_buf].modified = false
      close_review(review, true)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = handles.after_buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(handles.after_buf) then
        vim.bo[handles.after_buf].modified = false
      end
    end,
  })

  for _, buf in ipairs({ handles.before_buf, handles.after_buf }) do
    vim.api.nvim_create_autocmd("QuitPre", {
      group = augroup,
      buffer = buf,
      callback = function()
        local review = active_reviews[review_id]
        if review then
          vim.schedule(function()
            close_review(review, false)
          end)
        end
      end,
    })
  end

  vim.api.nvim_echo({
    { "[omniac approval] review changes, then run :w to accept or :q to deny", "Comment" },
  }, true, {})

  return handles
end

function M.open_preview(path, before_lines, after_lines, opts)
  opts = opts or {}
  close_stale_reviews()

  local review_id = tostring(next_review_id)
  next_review_id = next_review_id + 1
  local handles = M.open(before_lines, after_lines, {
    title = opts.title or ("Omniac changes: " .. (path or "change")),
    origin_win = opts.origin_win,
    separate_tab = opts.separate_tab,
    path = path,
  })

  for _, buf in ipairs({ handles.before_buf, handles.after_buf }) do
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].buftype = "nofile"
    vim.b[buf].omniac_diff_review_id = review_id
  end

  active_reviews[review_id] = {
    id = review_id,
    path = path,
    before_buf = handles.before_buf,
    after_buf = handles.after_buf,
    before_win = handles.before_win,
    after_win = handles.after_win,
    origin_buf = handles.origin_buf,
    origin_win_options = handles.origin_win_options,
    fixed_widths = handles.fixed_widths,
    separate_tab = handles.separate_tab,
    read_only = true,
    on_close = opts.on_close,
  }

  for _, buf in ipairs({ handles.before_buf, handles.after_buf }) do
    vim.api.nvim_create_autocmd("QuitPre", {
      group = augroup,
      buffer = buf,
      callback = function()
        local review = active_reviews[review_id]
        if review then
          vim.schedule(function()
            close_review(review, false)
          end)
        end
      end,
    })
  end

  vim.api.nvim_echo({
    { "[omniac review] read-only change preview; run :q to close", "Comment" },
  }, true, {})
  return handles
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
  if review.read_only then
    vim.notify("This Omniac change preview is read-only", vim.log.levels.INFO)
    return
  end

  close_review(review, true)
end

function M.deny_current_review()
  local review = current_review()
  if not review then
    vim.notify("No Omniac diff approval is active in this buffer", vim.log.levels.WARN)
    return
  end

  close_review(review, false)
end

return M
