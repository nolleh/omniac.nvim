local M = {}

local function create(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

function M.ensure(state, valid_buf)
  if not valid_buf(state.chat_buf) then
    state.chat_buf = create("omniac", "markdown")
  end
  if state.card_pinned and not valid_buf(state.card_buf) then
    state.card_buf = create("omniac://card", "omniac-card")
  end
  if not valid_buf(state.input_buf) then
    state.input_buf = create("omniac://input", "omniac-input")
  end
  if not valid_buf(state.activity_buf) then
    state.activity_buf = create("omniac://activity", "omniac-activity")
  end
  if not valid_buf(state.status_buf) then
    state.status_buf = create("omniac://status", "omniac-status")
  end
end

return M
