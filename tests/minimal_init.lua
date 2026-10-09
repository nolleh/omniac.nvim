local project_root = vim.fn.getcwd()
local plenary_dir = vim.env.PLENARY_DIR

assert(plenary_dir and vim.fn.isdirectory(plenary_dir) == 1, "PLENARY_DIR must point to a plenary.nvim checkout")

vim.opt.runtimepath:prepend(project_root)
vim.opt.runtimepath:prepend(plenary_dir)
vim.opt.showmode = false
vim.opt.swapfile = false

vim.api.nvim_echo = function() end
vim.notify = function() end
