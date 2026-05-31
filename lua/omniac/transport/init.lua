local M = {}

function M.new(config)
  local stdio = require("omniac.transport.stdio")
  return stdio.new(config)
end

return M
