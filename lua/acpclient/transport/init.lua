local M = {}

function M.new(config)
  local stdio = require("acpclient.transport.stdio")
  return stdio.new(config)
end

return M

