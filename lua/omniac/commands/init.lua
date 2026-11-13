local selection = require("omniac.editor.selection")
local tree = require("omniac.editor.tree")
local ui = require("omniac.ui")

local M = {}

local function register(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

function M.setup(app)
  local function connect()
    app.connect()
  end

  local function disconnect()
    app.disconnect()
  end

  local function exit()
    app.exit()
  end

  local function ask(cmd)
    app.ask(cmd.args)
  end

  local function debug()
    if not app.config.debug then
      vim.notify("debug is disabled", vim.log.levels.WARN, { title = "omniac debug" })
      return
    end

    if app.backend and app.backend.get_debug_log then
      vim.notify(vim.inspect(app.backend:get_debug_log()), vim.log.levels.INFO, { title = "omniac debug" })
    else
      vim.notify("no active transport", vim.log.levels.WARN, { title = "omniac debug" })
    end
  end

  local function ask_files(cmd)
    local paths = {}
    for path in string.gmatch(cmd.args, "[^,%s]+") do
      table.insert(paths, path)
    end
    app.ask_with_files("", paths)
  end

  local function attach_reference(reference_item)
    app.open_chat()
    ui.attach_reference(reference_item, app.config)
  end

  local function reference(cmd)
    if not cmd.range or cmd.range == 0 then
      vim.notify("OmniacReference requires a visual selection", vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local reference_item, err = selection.reference_from_range(vim.api.nvim_get_current_buf(), cmd.line1, cmd.line2)
    if not reference_item then
      vim.notify(tostring(err or "Unable to capture selection"), vim.log.levels.WARN, { title = "omniac" })
      return
    end

    attach_reference(reference_item)
  end

  local function reference_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if bufname == "omniac" or bufname:match("^omniac://") then
      vim.notify("OmniacReferenceBuffer requires a source buffer", vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local reference_item, err = selection.reference_from_range(bufnr, 1, vim.api.nvim_buf_line_count(bufnr))
    if not reference_item then
      vim.notify(tostring(err or "Unable to capture buffer"), vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local has_disk_file = reference_item.path ~= "" and vim.fn.filereadable(reference_item.path) == 1
    local include_modified_buffer = app.config.references and app.config.references.include_modified_buffer == true

    if not has_disk_file and not include_modified_buffer then
      return
    end

    reference_item.pathOnly = has_disk_file and not (reference_item.modified and include_modified_buffer)
    attach_reference(reference_item)
  end

  local function tree_add()
    local paths, err = tree.get_selected_paths()
    if not paths or #paths == 0 then
      vim.notify(tostring(err or "No file selected in tree"), vim.log.levels.WARN, { title = "omniac" })
      return
    end

    local references = {}
    for _, path in ipairs(paths) do
      local uri = vim.uri_from_fname(path)
      table.insert(references, {
        type = "reference",
        path = path,
        uri = uri,
        filetype = "",
        pathOnly = true,
      })
    end
    app.open_chat()
    for _, reference_item in ipairs(references) do
      ui.attach_reference(reference_item, app.config)
    end
  end

  local function diff(cmd)
    local path = vim.fn.expand(cmd.args)
    if path == "" then
      error("OmniacDiff requires a file path")
    end

    app.open_file_diff(path, nil, { title = app.config.ui.diff_title })
  end

  local function toggle_chat()
    app.toggle_chat()
  end

  local function open_chat()
    app.open_chat()
  end

  local function choose_session()
    if app.backend then
      app.select_session()
    elseif ui.is_open() then
      app.connect({
        session = { action = "select" },
      })
    else
      app.open_chat({
        session = { action = "select" },
      })
    end
  end

  local function resize(cmd)
    app.resize(cmd.args)
  end

  local function review_changes(cmd)
    app.review_changes(cmd.args)
  end

  register("Omniac", toggle_chat, {})
  register("OmniacFocus", open_chat, {})
  register("OmniacConnect", connect, {})
  register("OmniacDisconnect", disconnect, {})
  register("OmniacExit", exit, {})
  register("OmniacSession", choose_session, {})
  register("OmniacModel", function(cmd)
    app.select_model(cmd.args)
  end, { nargs = "?" })
  register("OmniacMode", function(cmd)
    app.select_mode(cmd.args)
  end, { nargs = "?" })
  register("OmniacAsk", ask, { nargs = "?" })
  register("OmniacResize", resize, { nargs = 1 })
  register("OmniacDebug", debug, {})
  register("OmniacAskFiles", ask_files, { nargs = "?" })
  register("OmniacReference", reference, { range = true })
  register("OmniacReferenceBuffer", reference_buffer, {})
  register("OmniacTreeAdd", tree_add, {})
  register("OmniacChanges", review_changes, {
    nargs = "?",
    complete = function()
      return { "turn", "session" }
    end,
  })
  register("OmniacDiff", diff, { nargs = 1, complete = "file" })
  register("OmniacDiffAccept", function()
    require("omniac.changes.review").accept_current_review()
  end, {})
  register("OmniacDiffDeny", function()
    require("omniac.changes.review").deny_current_review()
  end, {})
end

return M
