local attachments = require("omniac.ui.input.attachments")
local ambient = require("omniac.ui.input.ambient")
local completion = require("omniac.ui.input.completion")
local editing = require("omniac.ui.input.editing")

local M = {}

local function complete_current(state, opts, scheduled)
  local value = opts.input_text()
  local completed = completion.complete(state.available_commands, value)
  if completed == value then
    return false
  end

  local apply = function()
    if not opts.valid_buf(state.input_buf) or not opts.valid_win(state.input_win) then
      return
    end
    opts.editing.render(completed, { line = 1, col = #completed })
    vim.cmd("startinsert!")
  end
  if scheduled then
    vim.schedule(apply)
  else
    apply()
  end
  return true
end

local function add_clipboard_image(state, opts, image)
  if not opts.valid_buf(state.input_buf) or not opts.valid_win(state.input_win) then
    return false
  end

  local lines = opts.editing.read()
  local cursor = vim.api.nvim_win_get_cursor(state.input_win)
  lines, cursor = attachments.insert(state, image, lines, opts.editing.logical_cursor(cursor))
  opts.editing.render(lines, cursor)
  vim.schedule(opts.focus)
  return true
end

local function cancel_active_turn(state, opts)
  if state.status ~= "working" or state.cancel_requested then
    return false
  end

  state.cancel_requested = true
  state.suppress_current_turn = true
  vim.schedule(function()
    opts.set_activity("Cancelling current turn.", state.config)
    if state.cancel_handler then
      state.cancel_handler()
    end
    opts.focus()
  end)
  return true
end

function M.setup(state, opts)
  local buf = state.input_buf
  ambient.suppress_completion(buf)
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    local value, prepared_attachments = opts.prepared_input()
    if value == "" and #prepared_attachments == 0 then
      opts.reset()
      opts.close_suggestions()
      opts.focus()
      return
    end
    if completion.mention_prefix(opts.raw_text()) ~= nil and #prepared_attachments == 0 then
      complete_current(state, opts, false)
      opts.focus()
      return
    end
    value = completion.complete(state.available_commands, value)
    if state.submit and state.submit(value, prepared_attachments) == false then
      return
    end
    opts.remember_history(value)
    opts.reset()
    opts.close_suggestions()
    opts.clear_attachments()
  end, { buffer = buf, nowait = true, desc = "Send Omniac prompt" })

  if state.queue_submit then
    vim.keymap.set("i", "<Tab>", function()
      if complete_current(state, opts, true) then
        return "<Ignore>"
      end
      if completion.command_prefix(opts.raw_text()) ~= nil then
        return "<Tab>"
      end

      local value, prepared_attachments = opts.prepared_input()
      if (value == "" and #prepared_attachments == 0) or not state.queue_submit then
        return "<Tab>"
      end
      value = completion.complete(state.available_commands, value)
      if state.queue_submit(value, prepared_attachments) == false then
        return "<Tab>"
      end
      vim.schedule(function()
        opts.remember_history(value)
        opts.reset()
        opts.clear_attachments()
        opts.close_suggestions()
      end)
      return "<Ignore>"
    end, { buffer = buf, expr = true, nowait = true, desc = "Queue Omniac prompt during a turn" })
  end

  vim.keymap.set("i", "<C-v>", function()
    local image = require("omniac.editor.clipboard").read_image()
    if not image then
      return "<C-r>+"
    end
    vim.schedule(function()
      add_clipboard_image(state, opts, image)
    end)
    return ""
  end, { buffer = buf, expr = true, nowait = true, desc = "Paste Omniac clipboard image or text" })
  vim.keymap.set("n", "<C-v>", function()
    local image = require("omniac.editor.clipboard").read_image()
    if not image or not add_clipboard_image(state, opts, image) then
      vim.cmd('normal! "+p')
    end
  end, { buffer = buf, nowait = true, desc = "Paste Omniac clipboard image or text" })

  for _, key in ipairs({ "<S-CR>", "<S-Enter>" }) do
    vim.keymap.set({ "n", "i" }, key, function()
      editing.insert_newline(state, opts.editing)
    end, { buffer = buf, nowait = true, desc = "Insert newline in Omniac prompt" })
  end
  vim.keymap.set("i", "<BS>", function()
    return editing.delete_backwards(state, opts.editing)
  end, { buffer = buf, nowait = true, desc = "Delete Omniac input character" })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    opts.reset()
    opts.clear_attachments()
    opts.close_suggestions()
    opts.focus()
  end, { buffer = buf, nowait = true, desc = "Clear Omniac input" })

  local function bind_history(key, direction)
    local description = "Recall " .. (direction == -1 and "previous" or "next") .. " Omniac prompt"
    vim.keymap.set("i", key, function()
      return opts.navigate_history(direction) and "<Ignore>" or key
    end, { buffer = buf, expr = true, nowait = true, desc = description })
    vim.keymap.set("n", key, function()
      if not opts.navigate_history(direction) then
        vim.cmd("normal! " .. (direction == -1 and "k" or "j"))
      end
    end, { buffer = buf, nowait = true, desc = description })
  end
  bind_history("<Up>", -1)
  bind_history("<Down>", 1)

  vim.keymap.set("n", "<Esc>", function()
    cancel_active_turn(state, opts)
  end, { buffer = buf, nowait = true, desc = "Cancel active Omniac turn" })
  vim.keymap.set("n", "q", opts.close_ui, { buffer = buf, nowait = true, desc = "Close Omniac chat" })

  vim.api.nvim_clear_autocmds({ group = opts.augroup, buffer = buf })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = opts.augroup,
    buffer = buf,
    callback = function(args)
      editing.enforce(state, args, opts.editing)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "InsertCharPre" }, {
    group = opts.augroup,
    buffer = buf,
    callback = function()
      editing.clamp_cursor(state, opts.editing)
    end,
  })
end

return M
