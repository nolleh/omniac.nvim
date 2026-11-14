local M = {}
local prefix = "[@image](data:image/"

-- Session replay can split the Markdown link anywhere, including its prefix.
-- Keep only a possible prefix between chunks, never the image payload.
function M.push(state, chunk, final)
  local value = (state.pending or "") .. chunk
  state.pending = ""
  local result = {}
  local position = 1
  while position <= #value do
    if state.image then
      local closing = value:find(")", position, true)
      if not closing then
        return table.concat(result)
      end
      state.image = false
      position = closing + 1
    else
      local opening = value:find(prefix, position, true)
      if opening then
        table.insert(result, value:sub(position, opening - 1))
        table.insert(result, "[Image attachment]")
        state.image = true
        position = opening + #prefix
      else
        local tail = value:sub(position)
        if not final then
          for length = math.min(#prefix - 1, #tail), 1, -1 do
            if tail:sub(-length) == prefix:sub(1, length) then
              state.pending = tail:sub(-length)
              tail = tail:sub(1, #tail - length)
              break
            end
          end
        end
        table.insert(result, tail)
        break
      end
    end
  end
  return table.concat(result)
end

return M
