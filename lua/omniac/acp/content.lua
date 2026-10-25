local normalize = require("omniac.acp.normalize")

local M = {}

function M.text(value, seen)
  if type(value) == "string" then
    return value
  end
  if type(value) ~= "table" then
    return nil
  end

  seen = seen or {}
  if seen[value] then
    return nil
  end
  seen[value] = true

  for _, key in ipairs({ "text", "delta", "message", "content", "value" }) do
    local found = M.text(value[key], seen)
    if found and found ~= "" then
      return found
    end
  end

  for _, item in ipairs(normalize.content_items(value)) do
    local found = M.text(item, seen)
    if found and found ~= "" then
      return found
    end
  end

  for _, item in pairs(value) do
    if type(item) == "table" or type(item) == "string" then
      local found = M.text(item, seen)
      if found and found ~= "" then
        return found
      end
    end
  end

  return nil
end

function M.response_text(result)
  if type(result) ~= "table" then
    return nil
  end

  for _, key in ipairs({ "text", "delta", "message", "content", "value" }) do
    local found = M.text(result[key])
    if found and found ~= "" then
      return found
    end
  end

  for _, item in ipairs(normalize.content_items(result)) do
    local found = M.text(item)
    if found and found ~= "" then
      return found
    end
  end

  return nil
end

return M
