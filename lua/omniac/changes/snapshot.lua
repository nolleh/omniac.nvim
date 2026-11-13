local filesystem = require("omniac.editor.filesystem")
local uv = vim.uv or vim.loop
local M = {}

-- Change previews are text-only. Keep large/generated files out of memory.
local max_size = 2 * 1024 * 1024

local function text_file(path)
  local stat = uv.fs_lstat(path)
  if not stat or stat.type ~= "file" or stat.size > max_size then
    return false
  end
  local value = filesystem.read_disk_content(path)
  return value and not value:find("\0", 1, true) and value or false
end

local function git(cwd, args)
  local command = { "git", "-C", cwd }
  vim.list_extend(command, args)
  local ok, result = pcall(function()
    return vim.system(command, { text = false }):wait(5000)
  end)
  return ok and result.code == 0 and result.stdout or nil
end

function M.capture(cwd)
  cwd = vim.fn.fnamemodify(cwd, ":p"):gsub("/$", "")
  if cwd == "" then
    cwd = "/"
  end
  local snapshot = { cwd = cwd, files = {} }
  local listing = git(cwd, { "ls-files", "--stage", "--cached", "--others", "--exclude-standard", "-z" })
  if listing then
    local modified = git(cwd, { "ls-files", "--modified", "--deleted", "-z" })
    if not modified then
      return nil
    end
    for entry in listing:gmatch("([^%z]+)%z") do
      local mode, oid, stage, path = entry:match("^(%d+) (%x+) (%d)\t(.*)$")
      if not path then
        snapshot.files[entry] = { text = text_file(cwd .. "/" .. entry) }
      elseif stage == "0" and mode:match("^100") then
        -- Clean tracked contents stay in Git until a changed file needs a preview.
        snapshot.files[path] = { oid = oid }
      end
    end
    for path in modified:gmatch("([^%z]+)%z") do
      if not uv.fs_lstat(cwd .. "/" .. path) then
        snapshot.files[path] = nil
      else
        snapshot.files[path] = { text = text_file(cwd .. "/" .. path) }
      end
    end
  else
    local function walk(directory, prefix)
      local scan = uv.fs_scandir(directory)
      if not scan then
        return
      end
      while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then
          break
        end
        local path = prefix .. name
        if name ~= ".git" then
          if kind == "directory" then
            walk(directory .. "/" .. name, path .. "/")
          elseif kind == "file" then
            snapshot.files[path] = { text = text_file(directory .. "/" .. name) }
          end
        end
      end
    end
    walk(cwd, "")
  end
  return snapshot
end

function M.content(snapshot, path)
  if not snapshot then
    return nil
  end
  path = vim.fs.normalize(path)
  local prefix = snapshot.cwd:gsub("/$", "") .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local entry = snapshot.files[path:sub(#prefix + 1)]
  if not entry then
    return ""
  end
  if entry.oid then
    local size = tonumber(git(snapshot.cwd, { "cat-file", "-s", entry.oid }))
    local value = size and size <= max_size and git(snapshot.cwd, { "cat-file", "blob", entry.oid })
    entry.text = value and not value:find("\0", 1, true) and value or false
    entry.oid = nil
  end
  return entry.text
end

function M.diff(before, after)
  local result = {}
  if not before or not after then
    return result
  end
  local paths = {}
  for path in pairs(before.files) do
    paths[path] = true
  end
  for path in pairs(after.files) do
    paths[path] = true
  end
  for _, path in ipairs(vim.tbl_keys(paths)) do
    local first, last = before.files[path], after.files[path]
    if not (first and last and first.oid and first.oid == last.oid) then
      local absolute = before.cwd:gsub("/$", "") .. "/" .. path
      local old, new = M.content(before, absolute), M.content(after, absolute)
      if type(old) == "string" and type(new) == "string" and old ~= new then
        table.insert(result, { path = absolute, oldText = old, newText = new })
      end
    end
  end
  table.sort(result, function(a, b)
    return a.path < b.path
  end)
  return result
end

return M
