local M = {}

local function disable_nvim_cmp(buf)
  local ok, cmp = pcall(require, "cmp")
  if not ok or type(cmp) ~= "table" or type(cmp.setup) ~= "table" or type(cmp.setup.buffer) ~= "function" then
    return
  end

  vim.api.nvim_buf_call(buf, function()
    cmp.setup.buffer({ enabled = false })
    if type(cmp.visible) == "function" and cmp.visible() and type(cmp.close) == "function" then
      cmp.close()
    end
  end)
end

function M.suppress_completion(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.bo[buf].complete = ""
  vim.bo[buf].completefunc = ""
  vim.bo[buf].omnifunc = ""
  vim.bo[buf].thesaurusfunc = ""
  vim.b[buf].omniac_disable_completion = true
  disable_nvim_cmp(buf)
end

return M
