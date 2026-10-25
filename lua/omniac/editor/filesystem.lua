local M = {}

local function json_error(code, message, data)
  local err = {
    code = code,
    message = message,
  }
  if data ~= nil then
    err.data = data
  end
  return err
end

local function is_absolute_path(path)
  return type(path) == "string" and path:match("^/") ~= nil
end

local function validate_path(params)
  local path = params and params.path
  if not is_absolute_path(path) then
    return nil, json_error(-32602, "fs path must be absolute")
  end
  return path, nil
end

local function path_buffer(path)
  local normalized = vim.fn.fnamemodify(path, ":p")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == normalized then
      return buf
    end
  end
  return nil
end

local function buffer_endofline(buf)
  if vim.api.nvim_get_option_value then
    local ok, value = pcall(vim.api.nvim_get_option_value, "endofline", { buf = buf })
    if ok then
      return value
    end
  end

  local ok, value = pcall(function()
    return vim.bo[buf].endofline
  end)
  return ok and value or false
end

local function lines_to_content(lines, append_eol)
  lines = lines or {}
  if #lines == 0 then
    return ""
  end
  if #lines == 1 and lines[1] == "" then
    return ""
  end

  local content = table.concat(lines, "\n")
  if append_eol then
    content = content .. "\n"
  end
  return content
end

local function content_to_lines(content)
  if content == "" then
    return { "" }
  end

  local lines = vim.split(content, "\n", { plain = true })
  if content:sub(-1) == "\n" then
    table.remove(lines)
  end
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function slice_lines(lines, line, limit)
  local start = tonumber(line) or 1
  local count = tonumber(limit)
  if start < 1 then
    start = 1
  end

  local stop = #lines
  if count and count >= 0 then
    stop = math.min(stop, start + count - 1)
  end

  local result = {}
  for index = start, stop do
    table.insert(result, lines[index])
  end
  return result
end

local function read_disk_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, json_error(-32001, "file is not readable", {
      path = path,
    })
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, json_error(-32001, "failed to read file", {
      path = path,
      error = lines,
    })
  end
  return lines, nil
end

function M.read_disk_content(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return content
end

local function write_disk_content(path, content)
  local fd, open_err = vim.loop.fs_open(path, "w", 438)
  if not fd then
    return json_error(-32002, "failed to open file for writing", {
      path = path,
      error = open_err,
    })
  end

  local ok, write_err = vim.loop.fs_write(fd, content, 0)
  local _, close_err = vim.loop.fs_close(fd)
  if not ok then
    return json_error(-32002, "failed to write file", {
      path = path,
      error = write_err,
    })
  end
  if close_err then
    return json_error(-32002, "failed to close file after writing", {
      path = path,
      error = close_err,
    })
  end

  return nil
end

local function update_loaded_buffer_lines(path, lines)
  local buf = path_buffer(path)
  if not buf then
    return
  end

  local was_modifiable = vim.bo[buf].modifiable
  if not was_modifiable then
    vim.bo[buf].modifiable = true
  end

  local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  if ok then
    vim.bo[buf].modified = false
  end

  if not was_modifiable and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = false
  end
end

local function update_loaded_buffer(path, content)
  update_loaded_buffer_lines(path, content_to_lines(content))
end

function M.write_file_lines(path, lines)
  if type(path) ~= "string" or path == "" then
    return false
  end

  lines = type(lines) == "table" and lines or {}
  vim.fn.writefile(lines, path)
  update_loaded_buffer_lines(path, lines)
  return true
end

function M.read_text_file(params)
  local path, path_err = validate_path(params)
  if path_err then
    return nil, path_err
  end

  local buf = path_buffer(path)
  local lines
  local read_err
  local append_eol = true
  if buf then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    append_eol = buffer_endofline(buf)
  else
    lines, read_err = read_disk_lines(path)
    if read_err then
      return nil, read_err
    end
  end

  local selected = slice_lines(lines, params and params.line, params and params.limit)
  return {
    content = lines_to_content(selected, append_eol and #selected > 0),
  }, nil
end

function M.write_text_file(params)
  local path, path_err = validate_path(params)
  if path_err then
    return nil, path_err
  end
  if type(params.content) ~= "string" then
    return nil, json_error(-32602, "fs/write_text_file content must be a string")
  end

  local write_err = write_disk_content(path, params.content)
  if write_err then
    return nil, write_err
  end

  update_loaded_buffer(path, params.content)
  return vim.NIL, nil
end

function M.handle_request(method, params)
  if method == "fs/read_text_file" then
    return M.read_text_file(params or {})
  end
  if method == "fs/write_text_file" then
    return M.write_text_file(params or {})
  end
  return nil, json_error(-32601, "unsupported filesystem method: " .. tostring(method))
end

return M
