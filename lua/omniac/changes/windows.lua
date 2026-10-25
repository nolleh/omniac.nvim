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

local function stop_insert()
  if vim.fn.mode():match("^[iR]") then
    pcall(vim.cmd, "stopinsert")
  end
end

local function replace_split_buffer(win, buf, origin_buf)
  local placeholder = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)
  if
    placeholder ~= origin_buf
    and placeholder ~= buf
    and vim.api.nvim_buf_is_valid(placeholder)
    and vim.api.nvim_buf_get_name(placeholder) == ""
    and vim.bo[placeholder].buftype == ""
    and not vim.bo[placeholder].modified
    and vim.api.nvim_buf_line_count(placeholder) == 1
    and vim.api.nvim_buf_get_lines(placeholder, 0, 1, false)[1] == ""
  then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
end

return {
  is_review_candidate = is_review_candidate,
  collect_fixed_widths = collect_fixed_widths,
  equalize = equalize_review_windows,
  capture_options = capture_window_options,
  close = close_review_windows,
  enable_diff = enable_diff_window,
  detect_filetype = detect_filetype,
  stop_insert = stop_insert,
  replace_split_buffer = replace_split_buffer,
}
