local M = {}
local active_reviews = {}
local next_review_id = 1
local augroup = vim.api.nvim_create_augroup("omniac.diff", { clear = false })

local fixed_width_filetypes = {
  ["omniac"] = true,
  ["omniac-input"] = true,
  ["omniac-activity"] = true,
  ["omniac-status"] = true,
  ["NvimTree"] = true,
  ["neo-tree"] = true,
}

local function is_omniac_buffer(name)
  return name:match("omniac$") or name:match("omniac://")
end

local function is_review_candidate(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  local buftype = vim.bo[buf].buftype
  local filetype = vim.bo[buf].filetype

  if vim.w[win].omniac_ui or is_omniac_buffer(name) then
    return false
  end

  if buftype ~= "" then
    return false
  end

  if filetype == "NvimTree" or filetype == "neo-tree" or filetype == "qf" then
    return false
  end

  return true
end

local function is_regular_window(win)
  local ok, config = pcall(vim.api.nvim_win_get_config, win)
  return ok and (not config.relative or config.relative == "")
end

local function should_fix_width(win)
  if not is_regular_window(win) then
    return false
  end

  if vim.w[win].omniac_ui then
    return true
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local filetype = vim.bo[buf].filetype
  local name = vim.api.nvim_buf_get_name(buf)
  return fixed_width_filetypes[filetype]
    or name:match("Omniac Chat$")
    or name:match("Omniac Input$")
    or name:match("Omniac Activity$")
    or name:match("Omniac Status$")
end

local function collect_fixed_widths()
  local fixed = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if should_fix_width(win) then
      vim.wo[win].winfixwidth = true
      fixed[win] = vim.api.nvim_win_get_width(win)
    end
  end
  return fixed
end

local function restore_fixed_widths(fixed)
  for win, width in pairs(fixed or {}) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winfixwidth = true
      pcall(vim.api.nvim_win_set_width, win, width)
    end
  end
end

local function equalize_review_windows(before_win, after_win, fixed_widths)
  restore_fixed_widths(fixed_widths)
  if not vim.api.nvim_win_is_valid(before_win) or not vim.api.nvim_win_is_valid(after_win) then
    return
  end

  local total = vim.api.nvim_win_get_width(before_win) + vim.api.nvim_win_get_width(after_win)
  local width = math.max(1, math.floor(total / 2))
  pcall(vim.api.nvim_win_set_width, before_win, width)
  pcall(vim.api.nvim_win_set_width, after_win, total - width)
end

local function capture_window_options(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local options = {}
  for _, name in ipairs({
    "diff",
    "scrollbind",
    "cursorbind",
    "wrap",
    "foldmethod",
    "foldcolumn",
    "signcolumn",
    "winhighlight",
  }) do
    local ok, value = pcall(vim.api.nvim_get_option_value, name, { win = win })
    if ok then
      options[name] = value
    end
  end
  return options
end

local function restore_window_options(win, options)
  if not options or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  for name, value in pairs(options) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end
end

local function cleanup_diff_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  pcall(vim.api.nvim_win_call, win, function()
    pcall(vim.fn.clearmatches)
    vim.cmd("silent! diffoff!")
    vim.wo.diff = false
  end)
end

local function enable_diff_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_call(win, function()
    vim.cmd("diffthis")
  end)
end

local function detect_filetype(path, fallback_buf)
  if fallback_buf and vim.api.nvim_buf_is_valid(fallback_buf) then
    local filetype = vim.bo[fallback_buf].filetype
    if filetype and filetype ~= "" then
      return filetype
    end
  end

  if type(path) == "string" and path ~= "" and vim.filetype and vim.filetype.match then
    local ok, filetype = pcall(vim.filetype.match, { filename = path })
    if ok and filetype and filetype ~= "" then
      return filetype
    end
  end

  return nil
end

local function close_review_windows(review)
  cleanup_diff_window(review.before_win)
  cleanup_diff_window(review.after_win)

  if review.separate_tab then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == review.before_buf or buf == review.after_buf then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  else
    if review.after_win and vim.api.nvim_win_is_valid(review.after_win) then
      pcall(vim.api.nvim_win_close, review.after_win, true)
    end

    if review.before_win and vim.api.nvim_win_is_valid(review.before_win) then
      vim.api.nvim_win_call(review.before_win, function()
        vim.cmd("diffoff")
      end)

      if review.origin_buf and vim.api.nvim_buf_is_valid(review.origin_buf) then
        pcall(vim.api.nvim_win_set_buf, review.before_win, review.origin_buf)
      else
        pcall(vim.api.nvim_win_call, review.before_win, function()
          vim.cmd("enew")
        end)
      end
      restore_window_options(review.before_win, review.origin_win_options)
    end

    restore_fixed_widths(review.fixed_widths)
  end

  for _, buf in ipairs({ review.before_buf, review.after_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

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
    review.callback(accepted, accepted_lines)
  end
  close_review_windows(review)
end

local function close_stale_reviews()
  local reviews = {}
  for _, review in pairs(active_reviews) do
    table.insert(reviews, review)
  end

  for _, review in ipairs(reviews) do
    close_review(review, false)
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    pcall(vim.api.nvim_win_call, win, function()
      pcall(vim.fn.clearmatches)
      vim.cmd("silent! diffoff!")
    end)
  end
end

local function stop_insert()
  if vim.fn.mode():match("^[iR]") then
    pcall(vim.cmd, "stopinsert")
  end
end

local function first_diff_line(before_lines, after_lines)
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
  if vim.api.nvim_win_is_valid(current) and is_review_candidate(current) then
    return current
  end

  local best_win = nil
  local best_width = -1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_review_candidate(win) then
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

  local before_buf = vim.api.nvim_create_buf(false, true)
  local after_buf = vim.api.nvim_create_buf(false, true)
  local origin_win = opts.origin_win
  if not origin_win or not vim.api.nvim_win_is_valid(origin_win) then
    origin_win = vim.api.nvim_get_current_win()
  end
  local origin_buf = vim.api.nvim_win_get_buf(origin_win)
  local origin_win_options = capture_window_options(origin_win)

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

  local filetype = opts.filetype or detect_filetype(opts.path, origin_buf)
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
    vim.api.nvim_win_set_buf(before_win, before_buf)
    enable_diff_window(before_win)

    vim.cmd("vnew")
    after_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(after_win, after_buf)
    enable_diff_window(after_win)
  else
    fixed_widths = collect_fixed_widths()
    vim.api.nvim_set_current_win(origin_win)
    vim.api.nvim_win_set_buf(origin_win, before_buf)
    before_win = origin_win
    enable_diff_window(before_win)

    vim.cmd("rightbelow vnew")
    after_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(after_win, after_buf)
    enable_diff_window(after_win)
    equalize_review_windows(before_win, after_win, fixed_widths)
  end
  vim.bo[after_buf].modifiable = true

  if opts.title then
    vim.api.nvim_buf_set_name(after_buf, opts.title)
  end

  stop_insert()
  local cursor_line = first_diff_line(before_lines or {}, after_lines or {})
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
  }

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
          close_review(review, false)
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
  }

  for _, buf in ipairs({ handles.before_buf, handles.after_buf }) do
    vim.api.nvim_create_autocmd("QuitPre", {
      group = augroup,
      buffer = buf,
      callback = function()
        local review = active_reviews[review_id]
        if review then
          close_review(review, false)
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
