if vim.g.loaded_omniac then
  return
end

vim.g.loaded_omniac = 1

require("omniac").setup()

