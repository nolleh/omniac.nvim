local M = {}

local function file_uri(path, bufnr)
  if path == "" then
    return "nvim://buffer/" .. tostring(bufnr)
  end

  if vim.uri_from_fname then
    local ok, uri = pcall(vim.uri_from_fname, path)
    if ok and uri then
      return uri
    end
  end

  return "file://" .. path
end

function M.reference_from_range(bufnr, start_line, end_line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "buffer is no longer valid"
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  start_line = math.max(1, tonumber(start_line) or 0)
  end_line = math.min(line_count, tonumber(end_line) or 0)
  if start_line > end_line then
    return nil, "selection range is empty"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil, "selection range is empty"
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local uri = file_uri(path, bufnr) .. string.format("#L%d-L%d", start_line, end_line)

  return {
    type = "reference",
    bufnr = bufnr,
    path = path,
    uri = uri,
    filetype = vim.bo[bufnr].filetype,
    startLine = start_line,
    endLine = end_line,
    text = table.concat(lines, "\n"),
    modified = vim.bo[bufnr].modified,
  }
end

return M
