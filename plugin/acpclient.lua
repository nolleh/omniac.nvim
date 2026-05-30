if vim.g.loaded_acpclient then
  return
end

vim.g.loaded_acpclient = 1

require("acpclient").setup()

