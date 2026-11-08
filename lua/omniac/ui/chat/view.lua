local M = {}
local chat_render = require("omniac.ui.chat.render")
local markdown = require("omniac.ui.markdown")

local function capture_view(state, opts, valid_win)
  if not valid_win(state.chat_win) then
    return nil, false
  end

  local cursor = vim.api.nvim_win_get_cursor(state.chat_win)
  local is_active = vim.api.nvim_get_current_win() == state.chat_win
  local mode = is_active and vim.fn.mode(1) or ""
  local previous_view = vim.api.nvim_win_call(state.chat_win, vim.fn.winsaveview)
  local should_follow = opts.follow == true
    and (is_active or vim.api.nvim_get_current_win() == state.input_win)
    and mode:match("^[vV\22]") == nil
    and cursor[1] >= vim.api.nvim_buf_line_count(state.chat_buf)
  return previous_view, should_follow
end

local function restore_view(state, opts, line_count, previous_view, should_follow, valid_win)
  if opts.reset_view and valid_win(state.chat_win) then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { 1, 0 })
    pcall(vim.api.nvim_win_call, state.chat_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
  elseif should_follow and valid_win(state.chat_win) and line_count > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { line_count, 0 })
  elseif previous_view and valid_win(state.chat_win) then
    line_count = math.max(line_count, 1)
    previous_view.lnum = math.min(previous_view.lnum, line_count)
    previous_view.topline = math.min(previous_view.topline, line_count)
    pcall(vim.api.nvim_win_call, state.chat_win, function()
      vim.fn.winrestview(previous_view)
    end)
  end
end

-- Keep unchanged lines in the buffer, including the stable prefix of a streaming message.
local function replace_lines(buf, offset, lines)
  local previous = vim.api.nvim_buf_get_lines(buf, offset, -1, false)
  local first = 1
  while first <= #previous and first <= #lines and previous[first] == lines[first] do
    first = first + 1
  end
  local old_last, new_last = #previous, #lines
  while old_last >= first and new_last >= first and previous[old_last] == lines[new_last] do
    old_last = old_last - 1
    new_last = new_last - 1
  end
  if first <= old_last or first <= new_last then
    vim.api.nvim_buf_set_lines(
      buf,
      offset + first - 1,
      offset + old_last,
      false,
      vim.list_slice(lines, first, new_last)
    )
  end
end

function M.render(state, config, opts, handlers)
  opts = opts or {}
  state.config = config or state.config
  if not handlers.valid_buf(state.chat_buf) then
    return
  end

  local previous_view, should_follow = capture_view(state, opts, handlers.valid_win)
  local win_width = handlers.valid_win(state.chat_win) and vim.api.nvim_win_get_width(state.chat_win)
    or handlers.width()
  local cache = state.chat_render_cache
  local rebuild = not cache
    or cache.buf ~= state.chat_buf
    or cache.width ~= win_width
    or cache.messages ~= state.messages
    or cache.card_pinned ~= state.card_pinned
    or cache.tick ~= vim.api.nvim_buf_get_changedtick(state.chat_buf)
    or cache.count > #state.messages
    or cache.count == 0
  if rebuild then
    cache = { ranges = {}, excluded = {}, count = 0, line_count = 0 }
  end
  local start_index = rebuild and 1 or math.min(state.chat_dirty_from or (cache.count + 1), cache.count + 1)
  local offset = rebuild and 0 or (cache.ranges[start_index] or {}).from or cache.line_count
  local content_changed = start_index <= #state.messages or rebuild
  local index = state.streaming_message_index
  local streaming = index and state.messages[index] and state.messages[index].complete == false
  if content_changed or streaming or state.session_loading then
    markdown.suspend(state.chat_buf)
  end
  if content_changed then
    local content = chat_render.build({
      state = state,
      width = win_width,
      header = handlers.header,
      agent_name = handlers.agent_name,
      start_index = start_index,
    })
    local lines = content.lines

    vim.bo[state.chat_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(state.chat_buf, handlers.namespace, offset, -1)
    replace_lines(state.chat_buf, offset, lines)
    vim.bo[state.chat_buf].modifiable = false
    vim.bo[state.chat_buf].modified = false
    for index, range in pairs(content.message_ranges) do
      cache.ranges[index] = { from = offset + range.from, to = offset + range.to }
    end
    local excluded = {}
    for _, range in ipairs(cache.excluded) do
      if range.to <= offset then
        table.insert(excluded, range)
      end
    end
    for _, range in ipairs(content.markdown_excluded_ranges) do
      table.insert(excluded, { from = offset + range.from, to = offset + range.to })
    end
    cache.excluded = excluded
    cache.markdown_pending = true
    cache.markdown_from = math.min(cache.markdown_from or offset, offset)

    for _, mark in ipairs(content.marks) do
      handlers.add_hl(state.chat_buf, offset + mark.line, mark.from, mark.to, mark.group)
    end
    for _, mark in ipairs(content.permission_marks) do
      vim.api.nvim_buf_set_extmark(state.chat_buf, handlers.namespace, offset + mark.line - 1, 0, {
        virt_text = { { mark.label, mark.group }, { "  ", "Normal" } },
        virt_text_pos = "right_align",
      })
    end
  end

  -- Skipping our renderer alone does not stop redraw-triggered Treesitter parses.
  if not streaming and not state.session_loading and not opts.skip_markdown and cache.markdown_pending then
    markdown.clear(state.chat_buf, cache.markdown_from)
    markdown.start(state.chat_buf, cache.excluded)
    markdown.render(state.chat_buf, state.chat_win, "OmniacRender")
    cache.markdown_pending = false
    cache.markdown_from = nil
  end

  cache.buf = state.chat_buf
  cache.width = win_width
  cache.messages = state.messages
  cache.card_pinned = state.card_pinned
  cache.count = #state.messages
  cache.tick = vim.api.nvim_buf_get_changedtick(state.chat_buf)
  cache.line_count = vim.api.nvim_buf_line_count(state.chat_buf)
  state.chat_render_cache = cache
  state.chat_dirty_from = nil
  restore_view(state, opts, cache.line_count, previous_view, should_follow, handlers.valid_win)
end

return M
