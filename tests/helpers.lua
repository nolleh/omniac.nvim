local function assert_equal(actual, expected, message)
  assert.are.equal(expected, actual, message)
end

local function assert_true(value, message)
  assert.is_true(not not value, message)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(tostring(keys or ""), true, false, true), "xt", false)
  vim.wait(20, function()
    return true
  end)
  vim.cmd("redraw")
end

local function cleanup_omniac_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local basename = vim.fn.fnamemodify(name, ":t")
    if basename == "omniac" or name:match("omniac://") then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function has_window_for_buffer_name(name)
  local target = vim.fn.bufnr(name)
  if target == -1 then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == target then
      return true
    end
  end
  return false
end

local function cleanup_after_test()
  cleanup_omniac_buffers()
  pcall(vim.api.nvim_del_user_command, "OmniacReferenceBuffer")
  package.preload["render-markdown"] = nil
  package.loaded["render-markdown"] = nil
  package.loaded["omniac.clipboard"] = nil
end

return {
  assert_equal = assert_equal,
  assert_true = assert_true,
  feed = feed,
  cleanup_omniac_buffers = cleanup_omniac_buffers,
  cleanup_after_test = cleanup_after_test,
  has_window_for_buffer_name = has_window_for_buffer_name,
}
