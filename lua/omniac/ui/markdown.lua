local M = {}

local filetypes = { "omniac", "omniac-permission" }
vim.treesitter.language.register("markdown", filetypes)

local config = {
  pipe_table = {
    border_virtual = true,
    style = "normal",
  },
}

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function reset_children(parser)
  if parser and parser.children and parser.remove_child then
    for lang in pairs(parser:children()) do
      parser:remove_child(lang)
    end
  end
end

local function included_regions(buf, excluded)
  local result = {}
  local cursor = 0
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, range in ipairs(excluded or {}) do
    local from = math.min(math.max(range.from or 0, cursor), line_count)
    local to = math.min(math.max(range.to or from, from), line_count)
    if cursor < from then
      table.insert(result, { { cursor, 0, from, 0 } })
    end
    cursor = to
  end
  if cursor < line_count then
    table.insert(result, { { cursor, 0, line_count, 0 } })
  end
  return result
end

function M.suspend(buf)
  if not valid_buf(buf) then
    return
  end
  vim.b[buf].omniac_markdown_generation = (vim.b[buf].omniac_markdown_generation or 0) + 1
  if vim.b[buf].omniac_markdown_suspended and not vim.b[buf].omniac_markdown_parsing then
    return
  end
  vim.b[buf].omniac_markdown_suspended = true
  vim.b[buf].omniac_markdown_parsing = false
  if vim.treesitter and vim.treesitter.stop then
    pcall(vim.treesitter.stop, buf)
  end
  local ok, renderer = pcall(require, "render-markdown")
  if ok and type(renderer.buf_disable) == "function" then
    pcall(vim.api.nvim_buf_call, buf, renderer.buf_disable)
  end
  if vim.treesitter and vim.treesitter.get_parser then
    local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
    if ok_parser then
      reset_children(parser)
      pcall(parser.set_included_regions, parser, {})
    end
  end
end

function M.start(buf, excluded)
  if not valid_buf(buf) or not (vim.treesitter and vim.treesitter.start) then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if ok and parser then
    pcall(parser.set_included_regions, parser, included_regions(buf, excluded))
  end
end

function M.clear(buf, from)
  if not valid_buf(buf) then
    return
  end
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if type(name) == "string" and name:match("render.markdown") then
      pcall(vim.api.nvim_buf_clear_namespace, buf, id, from or 0, -1)
    end
  end
end

local function attach_images(buf)
  local snacks = rawget(_G, "Snacks")
  local image_config = type(snacks) == "table" and snacks.config and snacks.config.image
  if
    vim.bo[buf].filetype ~= "omniac"
    or type(image_config) ~= "table"
    or image_config.enabled ~= true
    or (type(image_config.doc) == "table" and image_config.doc.enabled == false)
  then
    return
  end

  local ok, image = pcall(require, "snacks.image")
  if not ok then
    return
  end
  -- Scratch chat buffers do not trigger the file-read events that initialize
  -- Snacks images. Attach after parsing, so Mermaid queries see complete trees.
  -- Both setup and doc.attach are idempotent and retain the user's settings.
  pcall(function()
    image.setup()
    image.doc.attach(buf)
  end)
end

local function render(buf, win, event)
  if not valid_buf(buf) then
    return
  end

  attach_images(buf)

  local ok, renderer = pcall(require, "render-markdown")
  if not ok or type(renderer) ~= "table" then
    return
  end

  if renderer.initialized == false and type(renderer.setup) == "function" then
    pcall(
      renderer.setup,
      vim.tbl_deep_extend("force", {
        file_types = { "markdown", unpack(filetypes) },
      }, config)
    )
  end

  local ok_state, renderer_state = pcall(require, "render-markdown.state")
  if ok_state and type(renderer_state) == "table" then
    -- Register only our filetypes when the user has already set up the
    -- renderer. Re-running setup would replace their settings and callbacks.
    if type(renderer_state.file_types) == "table" then
      for _, filetype in ipairs(filetypes) do
        if not vim.tbl_contains(renderer_state.file_types, filetype) then
          table.insert(renderer_state.file_types, filetype)
        end
      end
    end
    if type(renderer_state.cache) == "table" then
      local cached = renderer_state.cache[buf]
      if vim.tbl_contains(filetypes, vim.bo[buf].filetype) and cached then
        -- Already queued renderer updates retain this config object. Release
        -- Omniac's temporary suspension before replacing it, so an old clear
        -- update cannot erase the newly rendered buffer.
        cached.enabled = renderer_state.enabled
      end
      renderer_state.cache[buf] = nil
    end
  end

  if vim.tbl_contains(filetypes, vim.bo[buf].filetype) then
    -- The FileType event may precede renderer initialization. Attach its usual
    -- scroll/cursor handlers explicitly, after Omniac's async parse is ready.
    local ok_manager, manager = pcall(require, "render-markdown.core.manager")
    if ok_manager and type(manager.attach) == "function" then
      pcall(manager.attach, buf)
    end
  end

  if type(renderer.render) == "function" then
    pcall(renderer.render, {
      buf = buf,
      win = win,
      event = event or "OmniacRender",
      config = config,
    })
  elseif type(renderer.buf_enable) == "function" then
    pcall(vim.api.nvim_buf_call, buf, renderer.buf_enable)
  end
end

function M.render(buf, win, event)
  if not valid_buf(buf) then
    return
  end
  if not vim.b[buf].omniac_markdown_suspended then
    render(buf, win, event)
    return
  end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local generation = (vim.b[buf].omniac_markdown_generation or 0) + 1
  vim.b[buf].omniac_markdown_generation = generation
  vim.b[buf].omniac_markdown_parsing = true
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  local completed = false
  local function complete(err)
    if completed then
      return
    end
    completed = true
    if
      not valid_buf(buf)
      or generation ~= vim.b[buf].omniac_markdown_generation
      or tick ~= vim.api.nvim_buf_get_changedtick(buf)
    then
      return
    end
    vim.b[buf].omniac_markdown_parsing = false
    if err then
      reset_children(parser)
      if parser and parser.invalidate then
        pcall(parser.invalidate, parser, true)
      end
      return
    end
    vim.b[buf].omniac_markdown_suspended = false
    pcall(vim.treesitter.start, buf, "markdown")
    render(buf, win, event)
  end
  if ok and parser and parser.parse then
    -- Parse injections before redraw or render-markdown can request a synchronous
    -- parse. The callback API yields to Neovim and observes its redrawtime budget.
    local parsed, result = pcall(parser.parse, parser, true, complete)
    if not parsed then
      complete(result)
    elseif type(result) == "table" then
      complete()
    end
  else
    complete()
  end
end

return M
