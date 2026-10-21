local M = {}

local config = {
  pipe_table = {
    border_virtual = true,
    style = "normal",
  },
}

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.start(buf)
  if not valid_buf(buf) or not (vim.treesitter and vim.treesitter.start) then
    return
  end
  pcall(vim.treesitter.start, buf, "markdown")
end

function M.clear(buf)
  if not valid_buf(buf) then
    return
  end
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if type(name) == "string" and name:match("render.markdown") then
      pcall(vim.api.nvim_buf_clear_namespace, buf, id, 0, -1)
    end
  end
end

function M.render(buf, win, event)
  if not valid_buf(buf) then
    return
  end

  local ok, renderer = pcall(require, "render-markdown")
  if not ok or type(renderer) ~= "table" then
    return
  end

  if renderer.initialized == false and type(renderer.setup) == "function" then
    pcall(
      renderer.setup,
      vim.tbl_deep_extend("force", {
        file_types = { "markdown" },
      }, config)
    )
  end

  if type(renderer.render) == "function" then
    local ok_state, renderer_state = pcall(require, "render-markdown.state")
    if ok_state and type(renderer_state) == "table" and type(renderer_state.cache) == "table" then
      renderer_state.cache[buf] = nil
    end
    pcall(renderer.render, {
      buf = buf,
      win = win,
      event = event or "OmniacRender",
      config = config,
    })
  elseif type(renderer.buf_enable) == "function" then
    pcall(renderer.buf_enable)
  end
end

return M
