local M = {}

local function disable_autopairs(buf)
  if vim.bo[buf].filetype ~= "omniac-input" then
    return
  end
  local ok, autopairs = pcall(require, "nvim-autopairs")
  if not ok or type(autopairs.config) ~= "table" then
    return
  end
  local excluded = autopairs.config.disable_filetype
  if type(excluded) ~= "table" then
    return
  end
  local filetype = vim.bo[buf].filetype
  if not vim.tbl_contains(excluded, filetype) then
    table.insert(excluded, filetype)
  end
  -- Detach before installing our mappings: autopairs removes its old keymaps
  -- on buffer entry, including keys subsequently replaced by Omniac.
  if type(autopairs.force_attach) == "function" then
    vim.api.nvim_buf_call(buf, function()
      autopairs.force_attach(buf)
    end)
  end
  vim.b[buf].autopairs_keymaps = nil
end

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
  disable_autopairs(buf)
end

return M
