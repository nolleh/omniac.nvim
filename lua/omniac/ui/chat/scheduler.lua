local M = {}

function M.cancel(state)
  state.chat_render_generation = state.chat_render_generation + 1
  state.chat_render_pending = false
  state.chat_render_config = nil
  state.chat_render_opts = nil
end

function M.request(state, config, opts, render)
  opts = opts or {}
  config = config or state.config
  if opts.immediate and not state.session_loading then
    M.cancel(state)
    render(config, opts)
    return
  end

  state.chat_render_config = config
  local pending = state.chat_render_opts or {}
  pending.follow = pending.follow == true or opts.follow == true
  pending.skip_markdown = pending.skip_markdown ~= false and opts.skip_markdown == true
  state.chat_render_opts = pending
  if state.chat_render_pending then
    return
  end

  state.chat_render_pending = true
  state.chat_render_generation = state.chat_render_generation + 1
  local generation = state.chat_render_generation
  vim.defer_fn(function()
    if generation ~= state.chat_render_generation then
      return
    end
    local pending_config = state.chat_render_config or state.config
    local pending_opts = state.chat_render_opts or {}
    state.chat_render_pending = false
    state.chat_render_config = nil
    state.chat_render_opts = nil
    render(pending_config, pending_opts)
  end, state.session_loading and 48 or 24)
end

return M
