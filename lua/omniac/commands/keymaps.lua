local M = {}

local default_keymaps = {
  { name = "open", mode = "n", command = "Omniac", desc = "Toggle Omniac" },
  { name = "focus", mode = "n", command = "OmniacFocus", desc = "Focus Omniac" },
  { name = "session", mode = "n", command = "OmniacSession", desc = "Resume Omniac session" },
  { name = "model", mode = "n", command = "OmniacModel", desc = "Select Omniac model" },
  { name = "mode", mode = "n", command = "OmniacMode", desc = "Select Omniac session mode" },
  { name = "buffer", mode = "n", command = "OmniacReferenceBuffer", desc = "Add current buffer to Omniac" },
  { name = "reference", mode = "x", command = "OmniacReference", desc = "Send selection to Omniac" },
  { name = "diff_accept", mode = "n", command = "OmniacDiffAccept", desc = "Accept Omniac diff" },
  { name = "diff_deny", mode = "n", command = "OmniacDiffDeny", desc = "Deny Omniac diff" },
}

local installed_keymaps = {}
local tree_keymap_group

local function clear_installed_keymaps()
  if tree_keymap_group then
    pcall(vim.api.nvim_del_augroup_by_id, tree_keymap_group)
    tree_keymap_group = nil
  end
  for _, mapping in ipairs(installed_keymaps) do
    local current = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if type(current) == "table" and current.desc == mapping.desc then
      pcall(vim.keymap.del, mapping.mode, mapping.lhs)
    end
  end
  installed_keymaps = {}
end

function M.setup(config)
  clear_installed_keymaps()

  local configured = config.keymaps
  if configured == false or type(configured) ~= "table" then
    return
  end

  for _, mapping in ipairs(default_keymaps) do
    local lhs = configured[mapping.name]
    if type(lhs) == "string" and lhs ~= "" and vim.fn.maparg(lhs, mapping.mode) == "" then
      local desc = "Omniac: " .. mapping.desc
      local rhs = mapping.mode == "x" and (":" .. mapping.command .. "<CR>") or ("<cmd>" .. mapping.command .. "<cr>")
      vim.keymap.set(mapping.mode, lhs, rhs, {
        desc = desc,
        silent = true,
      })
      table.insert(installed_keymaps, {
        lhs = lhs,
        mode = mapping.mode,
        desc = desc,
      })
    end
  end

  local tree_lhs = configured.tree_add
  if type(tree_lhs) == "string" and tree_lhs ~= "" and vim.fn.maparg(tree_lhs, "n") == "" then
    tree_keymap_group = vim.api.nvim_create_augroup("OmniacTreeKeymaps", { clear = true })
    local function map_tree_buffer(bufnr)
      vim.api.nvim_buf_call(bufnr, function()
        if vim.fn.maparg(tree_lhs, "n", false, true).buffer ~= 1 then
          vim.keymap.set("n", tree_lhs, "<cmd>OmniacTreeAdd<cr>", {
            buffer = bufnr,
            desc = "Omniac: Add selected tree path",
            silent = true,
          })
        end
      end)
    end
    vim.api.nvim_create_autocmd("FileType", {
      group = tree_keymap_group,
      pattern = { "NvimTree", "neo-tree", "oil", "minifiles" },
      callback = function(event)
        map_tree_buffer(event.buf)
      end,
    })
    local supported_tree_filetypes = { "NvimTree", "neo-tree", "oil", "minifiles" }
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains(supported_tree_filetypes, vim.bo[bufnr].filetype) then
        map_tree_buffer(bufnr)
      end
    end
  end
end

return M
