local filesystem = require("omniac.editor.filesystem")
local M = {}

-- Replacement strings describe a fragment, while the review buffer needs the
-- whole file. Only construct a preview when the replacement is unambiguous.
function M.from_input(input, cwd)
  if type(input) ~= "table" then
    return nil
  end
  local path = input.file_path or input.filePath or input.path
  local before = input.old_string or input.oldString
  local after = input.new_string or input.newString
  if type(path) ~= "string" or path == "" or type(before) ~= "string" or type(after) ~= "string" then
    return nil
  end
  if cwd and not path:match("^[/\\]") and not path:match("^%a:") then
    path = cwd .. "/" .. path
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local original = filesystem.read_disk_content(path)
  if original == nil then
    if (vim.uv or vim.loop).fs_lstat(path) then
      return nil
    end
    original = ""
  end
  local proposed
  if before == "" then
    if original ~= "" then
      return nil
    end
    proposed = after
  else
    local matches = {}
    local position = 1
    while true do
      local first, last = original:find(before, position, true)
      if not first then
        break
      end
      table.insert(matches, { first, last })
      position = last + 1
    end
    local replace_all = input.replace_all == true or input.replaceAll == true
    if #matches == 0 or (#matches > 1 and not replace_all) then
      return nil
    end
    local parts = {}
    position = 1
    for _, match in ipairs(matches) do
      table.insert(parts, original:sub(position, match[1] - 1))
      table.insert(parts, after)
      position = match[2] + 1
    end
    table.insert(parts, original:sub(position))
    proposed = table.concat(parts)
  end
  return { type = "diff", path = path, oldText = original, newText = proposed }
end

return M
