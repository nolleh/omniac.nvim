local M = {}

local function current_filetype()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype
end

function M.get_selected_paths()
  local filetype = current_filetype()

  if filetype == "NvimTree" then
    local ok, api = pcall(require, "nvim-tree.api")
    if not ok then
      return nil, "nvim-tree is not available"
    end
    local node = api.tree.get_node_under_cursor()
    if node and node.absolute_path and node.type ~= "directory" then
      return { node.absolute_path }
    end
    return nil, "No file selected in nvim-tree"
  elseif filetype == "neo-tree" then
    local ok, manager = pcall(require, "neo-tree.sources.manager")
    local state = ok and manager.get_state("filesystem")
    local node = state and state.tree and state.tree:get_node()
    if node and node.path and node.type ~= "directory" then
      return { node.path }
    end
    return nil, "No file selected in neo-tree"
  elseif filetype == "oil" then
    local ok, oil = pcall(require, "oil")
    local entry = ok and oil.get_cursor_entry()
    local bufnr = vim.api.nvim_get_current_buf()
    local dir = ok and oil.get_current_dir(bufnr)
    if entry and entry.name and entry.name ~= ".." and dir then
      return { dir .. entry.name }
    end
    return nil, "No file selected in oil"
  elseif filetype == "minifiles" then
    local ok, mini_files = pcall(require, "mini.files")
    local entry = ok and mini_files.get_fs_entry(vim.api.nvim_get_current_buf())
    if entry and entry.path and entry.path ~= "" then
      local path = entry.path:gsub("^minifiles://[^/]*/", "")
      return { path }
    end
    return nil, "No file selected in mini.files"
  end

  return nil, "Tree references support nvim-tree, neo-tree, oil, and mini.files"
end

return M
