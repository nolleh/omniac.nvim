local layout = require("omniac.ui.layout")

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
    event = { "VimResized", "WinResized", "WinClosed", "BufDelete", "BufWipeout" },
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
    },
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
