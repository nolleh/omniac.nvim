-- Standalone demo configuration; does not load or modify the user's config.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
vim.g.mapleader = " "
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.showmode = false
vim.opt.termguicolors = true
vim.opt.background = "dark"
vim.opt.signcolumn = "no"
vim.opt.laststatus = 2
vim.opt.mouse = "a"
vim.cmd("colorscheme habamax")

for _, entry in ipairs({
  { "OMNIAC_RENDER_MARKDOWN_PATH", "render-markdown.nvim" },
  { "OMNIAC_TREESITTER_PATH", "nvim-treesitter" },
}) do
  local path = vim.env[entry[1]] or vim.fn.expand("~/.local/share/nvim/lazy/" .. entry[2])
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:append(path)
  end
end
pcall(vim.cmd, "runtime plugin/render-markdown.lua")

-- Load the guarded plugin entrypoint before applying the demo options.
vim.cmd("runtime plugin/omniac.lua")
require("omniac").setup({
  debug = false,
  agent = {
    cmd = { "codex-acp" },
    cwd = assert(vim.env.OMNIAC_DEMO_AGENT_CWD, "Launch through scripts/demo/prepare.py"),
    mode_id = "workspace-write",
  },
  ui = { chat_width = 0.44 },
})
