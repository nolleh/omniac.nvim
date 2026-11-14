local text = require("omniac.ui.text")

local M = {}
local palette = {
  "#000000",
  "#cd0000",
  "#00cd00",
  "#cdcd00",
  "#0000ee",
  "#cd00cd",
  "#00cdcd",
  "#e5e5e5",
  "#7f7f7f",
  "#ff0000",
  "#00ff00",
  "#ffff00",
  "#5c5cff",
  "#ff00ff",
  "#00ffff",
  "#ffffff",
}
local groups = {}
local attributes = { "fg", "bg", "bold", "italic", "underline", "reverse", "strikethrough" }

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("OmniacAnsi", { clear = true }),
  callback = function()
    for name, definition in pairs(groups) do
      vim.api.nvim_set_hl(0, name, definition)
    end
  end,
})

local function color(index)
  if index < 0 or index > 255 then
    return nil
  end
  if index < 16 then
    return vim.g["terminal_color_" .. index] or palette[index + 1]
  end
  if index >= 232 then
    local level = 8 + (index - 232) * 10
    return string.format("#%02x%02x%02x", level, level, level)
  end
  local cube = { 0, 95, 135, 175, 215, 255 }
  local value = index - 16
  return string.format(
    "#%02x%02x%02x",
    cube[math.floor(value / 36) + 1],
    cube[math.floor(value / 6) % 6 + 1],
    cube[value % 6 + 1]
  )
end

local function highlight(style)
  local parts = {}
  for _, key in ipairs(attributes) do
    if style[key] ~= nil then
      table.insert(parts, key .. tostring(style[key]):gsub("#", ""))
    end
  end
  if #parts == 0 then
    return nil
  end
  local name = "OmniacAnsi_" .. table.concat(parts, "_")
  if not groups[name] then
    groups[name] = vim.deepcopy(style)
    vim.api.nvim_set_hl(0, name, style)
  end
  return name
end

local function sgr(style, params)
  local codes = {}
  for code in (params .. ";"):gmatch("(.-);") do
    table.insert(codes, tonumber(code) or 0)
  end
  local i = 1
  while i <= #codes do
    local code = codes[i]
    if code == 0 then
      style = {}
    elseif code == 1 then
      style.bold = true
    elseif code == 3 then
      style.italic = true
    elseif code == 4 then
      style.underline = true
    elseif code == 7 then
      style.reverse = true
    elseif code == 9 then
      style.strikethrough = true
    elseif code == 22 then
      style.bold = false
    elseif code == 23 then
      style.italic = false
    elseif code == 24 then
      style.underline = false
    elseif code == 27 then
      style.reverse = false
    elseif code == 29 then
      style.strikethrough = false
    elseif code == 39 then
      style.fg = nil
    elseif code == 49 then
      style.bg = nil
    elseif code >= 30 and code <= 37 then
      style.fg = color(code - 30)
    elseif code >= 40 and code <= 47 then
      style.bg = color(code - 40)
    elseif code >= 90 and code <= 97 then
      style.fg = color(code - 90 + 8)
    elseif code >= 100 and code <= 107 then
      style.bg = color(code - 100 + 8)
    elseif code == 38 or code == 48 then
      local key = code == 38 and "fg" or "bg"
      if codes[i + 1] == 5 and codes[i + 2] then
        style[key] = color(codes[i + 2])
        i = i + 2
      elseif codes[i + 1] == 2 and codes[i + 2] and codes[i + 3] and codes[i + 4] then
        local r, g, b = codes[i + 2], codes[i + 3], codes[i + 4]
        if r <= 255 and g <= 255 and b <= 255 then
          style[key] = string.format("#%02x%02x%02x", r, g, b)
        end
        i = i + 4
      else
        break
      end
    end
    i = i + 1
  end
  return style
end

-- Parse whole accumulated messages, so an escape split across transport chunks
-- is completed on the next render. Never modify the stored output or logs.
function M.parse(value)
  value = tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local parts, spans, style = {}, {}, {}
  local pos, length = 1, 0
  local function append(chunk)
    if chunk == "" then
      return
    end
    local group = highlight(style)
    if group then
      table.insert(spans, { from = length, to = length + #chunk, group = group })
    end
    table.insert(parts, chunk)
    length = length + #chunk
  end
  while pos <= #value do
    local first = value:find("[%z\1-\8\11-\31\127]", pos)
    if not first then
      append(value:sub(pos))
      break
    end
    append(value:sub(pos, first - 1))
    pos = first + 1
    if value:byte(first) == 27 then
      local next_char = value:sub(pos, pos)
      if next_char == "[" then
        local last = value:find("[@-~]", pos + 1)
        if not last then
          break
        end
        if value:sub(last, last) == "m" then
          local params = value:sub(pos + 1, last - 1)
          if params:match("^[%d;]*$") then
            style = sgr(style, params)
          end
        end
        pos = last + 1
      elseif next_char == "]" or next_char == "P" or next_char == "_" or next_char == "^" then
        local bell = next_char == "]" and value:find("\7", pos + 1, true) or nil
        local ending = value:find("\27\\", pos + 1, true)
        if bell and (not ending or bell < ending) then
          pos = bell + 1
        elseif ending then
          pos = ending + 2
        else
          break
        end
      else
        -- Other escape sequences may have intermediate bytes (e.g. ESC ( B).
        local last = value:find("[\48-\126]", pos)
        if not last then
          break
        end
        pos = last + 1
      end
    end
  end
  return table.concat(parts), spans
end

-- Intersect source byte ranges with final display rows, after wrapping/trimming.
function M.marks(spans, from, length, line, padding)
  local marks = {}
  local low, high = 1, #spans
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if spans[mid].to <= from then
      low = mid + 1
    else
      high = mid - 1
    end
  end
  for index = low, #spans do
    local span = spans[index]
    if span.from >= from + length then
      break
    end
    local first, last = math.max(from, span.from), math.min(from + length, span.to)
    if first < last then
      table.insert(
        marks,
        { line = line, from = first - from + (padding or 0), to = last - from + (padding or 0), group = span.group }
      )
    end
  end
  return marks
end

function M.retained(source, displayed)
  local length = 0
  for char in text.chars(source) do
    if displayed:sub(length + 1, length + #char) ~= char then
      break
    end
    length = length + #char
  end
  return length
end

function M.wrapped(value, width)
  local plain, spans = M.parse(value)
  local lines = text.wrapped(plain, width)
  local marks, offset = {}, 0
  for index, line in ipairs(lines) do
    vim.list_extend(marks, M.marks(spans, offset, #line, index))
    offset = offset + #line
    if plain:sub(offset + 1, offset + 1) == "\n" then
      offset = offset + 1
    end
  end
  return lines, marks
end

return M
