local M = {}

function M.format_path(path)
  if not path or path == "" then
    return nil
  end

  return "@" .. vim.fn.fnamemodify(path, ":p")
end

function M.collect(paths)
  local result = {}
  for _, path in ipairs(paths or {}) do
    local mention = M.format_path(path)
    if mention then
      table.insert(result, mention)
    end
  end
  return result
end

return M

