local M = {}

function M.center(text, size)
  local display_width = vim.fn.strdisplaywidth(text)
  local pad = math.max(0, math.floor((size - display_width) / 2))
  return string.rep(" ", pad) .. text
end

function M.fit(text, size)
  local value = tostring(text or "")
  local current = vim.fn.strdisplaywidth(value)
  if current > size then
    local out = ""
    for char in M.chars(value) do
      if vim.fn.strdisplaywidth(out .. char) > size - 1 then
        return out .. "…"
      end
      out = out .. char
    end
    return out
  end
  return value .. string.rep(" ", size - current)
end

function M.chars(text)
  return tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

function M.box_line(left, fill, right, size)
  return left .. string.rep(fill, math.max(0, size - 2)) .. right
end

function M.boxed_text(text, size)
  return "│" .. M.fit(M.center(text, size - 2), size - 2) .. "│"
end

function M.wrapped(text, max_width)
  local result = {}
  for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      table.insert(result, "")
    else
      local current = ""
      for char in M.chars(raw) do
        if vim.fn.strdisplaywidth(current .. char) > max_width and current ~= "" then
          table.insert(result, current)
          current = char
        else
          current = current .. char
        end
      end
      if current ~= "" then
        table.insert(result, current)
      end
    end
  end
  if result[#result] == "" then
    table.remove(result)
  end
  return result
end

function M.split_lines(text)
  local result = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    table.insert(result, line)
  end
  if #result > 0 and result[#result] == "" then
    table.remove(result)
  end
  return result
end

return M
