local layout = require("omniac.ui.layout")
local follow = require("omniac.ui.chat.follow")

local M = {}

local function schedule_relayout(state, relayout)
  if state.relayout_pending then
    return
  end
  state.relayout_pending = true
  vim.schedule(function()
    state.relayout_pending = false
    relayout()
  end)
end

local function schedule_close(state, close)
  if state.close_pending then
    return
  end
  state.close_pending = true
  vim.schedule(function()
    if not state.close_pending then
      return
    end
    state.close_pending = false
    close()
  end)
end

function M.clear(augroup)
  vim.api.nvim_clear_autocmds({
    group = augroup,
    event = {
      "VimResized",
      "WinResized",
      "WinClosed",
      "BufDelete",
      "BufWipeout",
      "WinScrolled",
      "CursorMoved",
      "OptionSet",
    },
  })
end

function M.setup(state, opts)
  vim.api.nvim_clear_autocmds({
    group = opts.augroup,
    event = {
      "VimResized",
      "WinResized",
      "WinClosed",
      "WinEnter",
      "FocusGained",
      "BufEnter",
      "BufWinEnter",
      "BufDelete",
      "BufWipeout",
      "WinScrolled",
      "CursorMoved",
      "OptionSet",
    },
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group = opts.augroup,
    pattern = "laststatus",
    callback = function()
      for _, name in ipairs({ "card_win", "chat_win", "activity_win", "input_win", "status_win", "command_win" }) do
        if opts.valid_win(state[name]) then
          layout.configure_statusline(state[name])
        end
      end
      schedule_relayout(state, opts.relayout)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    group = opts.augroup,
    callback = function()
      if opts.valid_win(state.chat_win) and opts.valid_buf(state.chat_buf) then
        follow.observe(state)
      end
    end,
  })

  for _, buf in ipairs({ state.card_buf, state.chat_buf, state.activity_buf, state.input_buf, state.status_buf }) do
    if opts.valid_buf(buf) then
      vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = opts.augroup,
        buffer = buf,
        callback = function()
          schedule_close(state, opts.close)
        end,
      })
    end
  end

  if state.card_pinned then
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
      group = opts.augroup,
      buffer = state.chat_buf,
      callback = function()
        vim.schedule(function()
          if state.card_pinned and opts.valid_win(state.chat_win) then
            vim.wo[state.chat_win].winbar = ""
          end
        end)
      end,
    })
  end

  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = opts.augroup,
    callback = function()
      schedule_relayout(state, opts.relayout)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = opts.augroup,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if closed_win and layout.is_ui_win(state, closed_win) then
        schedule_close(state, opts.close)
        return
      end
      if closed_win and layout.floating_win(closed_win, opts.valid_win) then
        return
      end
      schedule_relayout(state, opts.relayout)
    end,
  })
end

return M
