local M = {}

local function get_visual_marks()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil
  end

  return {
    start_line = start_pos[2],
    start_col = start_pos[3],
    end_line = end_pos[2],
    end_col = end_pos[3],
  }
end

function M.get_visual_text()
  local marks = get_visual_marks()
  if not marks then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(0, marks.start_line - 1, marks.end_line, false)
  if #lines == 0 then
    return ""
  end

  lines[1] = string.sub(lines[1], marks.start_col)
  lines[#lines] = string.sub(lines[#lines], 1, math.max(marks.end_col, 0))

  return table.concat(lines, "\n")
end

function M.get_context()
  return {
    bufname = vim.api.nvim_buf_get_name(0),
    filetype = vim.bo.filetype,
    selection = M.get_visual_text(),
  }
end

return M

