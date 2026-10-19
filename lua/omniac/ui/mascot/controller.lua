local M = {}

local GAZE_DELAY_MS = 180
local BLINK_FRAME_MS = 100
local WORK_FRAME_MS = 650
local IDLE_DELAY_MS = 11000
local IDLE_GESTURE_MS = 350
local WALK_STEP_MS = 380
local PET_DURATION_MS = 320
local PET_WINDOW_MS = 2400

local function advance_gaze(state, opts)
  if state.mascot_gaze_pending or state.mascot_reacting then
    return
  end
  state.mascot_gaze_pending = true
  local generation = state.mascot_generation
  vim.defer_fn(function()
    if generation ~= state.mascot_generation then
      return
    end
    state.mascot_gaze_pending = false
    if state.mascot_reacting or not opts.visible() or state.mascot_gaze == state.mascot_target then
      return
    end

    local target = state.mascot_target
    if state.mascot_gaze ~= "center" and target ~= "center" then
      state.mascot_gaze = "center"
    else
      state.mascot_gaze = target
    end
    opts.render()
    if state.mascot_gaze ~= state.mascot_target then
      advance_gaze(state, opts)
    end
  end, GAZE_DELAY_MS)
end

local function finish_interaction(state, opts)
  state.mascot_interacting = false
  state.mascot_arm_frame = state.status == "working" and 1 or 0
  if opts.visible() then
    opts.render()
  end
end

local function react_to_card_pet(state, direction, opts)
  if ((state.config or {}).ui or {}).mascot_motion == false then
    return
  end
  local now = vim.uv.now()
  state.mascot_pet_count = now - state.mascot_last_pet_at <= PET_WINDOW_MS and state.mascot_pet_count + 1 or 1
  state.mascot_last_pet_at = now
  local flee = state.mascot_pet_count >= 3
  if flee then
    state.mascot_pet_count = 0
    local target = direction > 0 and 3 or -3
    state.mascot_x = state.mascot_x == target and -target or target
  end
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  local generation = state.mascot_interaction_generation
  state.mascot_interacting = true
  state.mascot_hop = 1
  state.mascot_walk_frame = 0
  state.mascot_arm_frame = direction > 0 and 1 or 2
  opts.render()
  vim.defer_fn(function()
    if generation ~= state.mascot_interaction_generation then
      return
    end
    state.mascot_hop = 0
    if not flee then
      state.mascot_x = 0
      finish_interaction(state, opts)
    else
      state.mascot_arm_frame = 0
      if opts.visible() then
        opts.render()
      end
    end
    if flee then
      vim.defer_fn(function()
        if generation ~= state.mascot_interaction_generation then
          return
        end
        state.mascot_x = 0
        finish_interaction(state, opts)
      end, 800)
    end
  end, PET_DURATION_MS)
end

local function react_to_card_vertical(state, direction, opts)
  if ((state.config or {}).ui or {}).mascot_motion == false then
    return
  end
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  local generation = state.mascot_interaction_generation
  state.mascot_interacting = true
  state.mascot_hop = 1
  state.mascot_arm_frame = direction > 0 and 2 or 1
  opts.render()
  vim.defer_fn(function()
    if generation ~= state.mascot_interaction_generation then
      return
    end
    state.mascot_hop = 0
    finish_interaction(state, opts)
  end, 180)
end

local function track_card_cursor(state, event, opts)
  if
    not state.card_pinned
    or not opts.valid_win(state.card_win)
    or vim.api.nvim_get_current_win() ~= state.card_win
  then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.card_win)[1]
  local column = vim.fn.virtcol(".")
  local previous = state.mascot_card_cursor
  state.mascot_card_cursor = { row = row, column = column }
  if event ~= "WinEnter" and previous then
    local width = vim.api.nvim_win_get_width(state.card_win)
    local sprite_left = math.floor((width - 2 - 10) / 2) + state.mascot_x + 2
    if
      row >= state.mascot_first_line
      and row <= state.mascot_last_line
      and column >= sprite_left - 1
      and column <= sprite_left + 10
    then
      if previous.row == row and previous.column ~= column then
        react_to_card_pet(state, column - previous.column, opts)
      elseif previous.row ~= row then
        react_to_card_vertical(state, row - previous.row, opts)
      end
    end
  end
  return row, column
end

local function react_to_focus(state, opts)
  if not opts.visible() then
    return
  end
  state.mascot_reaction_id = state.mascot_reaction_id + 1
  local reaction_id = state.mascot_reaction_id
  local generation = state.mascot_generation
  state.mascot_reacting = true
  state.mascot_eye_height = 1
  vim.schedule(function()
    if generation == state.mascot_generation and reaction_id == state.mascot_reaction_id and opts.visible() then
      opts.render()
    end
  end)
  for frame = 2, 4 do
    vim.defer_fn(function()
      if generation == state.mascot_generation and reaction_id == state.mascot_reaction_id then
        state.mascot_eye_height = frame == 2 and 0 or frame == 3 and 1 or 2
        if frame == 4 then
          state.mascot_reacting = false
        end
        if opts.visible() then
          opts.render()
        end
        if frame == 4 then
          M.schedule_gaze(state, { event = "CursorMoved" }, opts)
          if not state.mascot_in_omniac then
            advance_gaze(state, opts)
          end
        end
      end
    end, (frame - 1) * BLINK_FRAME_MS)
  end
end

function M.restart(state, opts)
  state.mascot_action_generation = state.mascot_action_generation + 1
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  state.mascot_interacting = false
  local generation = state.mascot_action_generation
  state.mascot_arm_frame = 0
  state.mascot_antenna_offset = 0
  state.mascot_x = 0
  state.mascot_hop = 0
  state.mascot_walk_frame = 0
  if opts.visible() then
    opts.render()
  end
  if ((state.config or {}).ui or {}).mascot_motion == false or not opts.valid_win(state.chat_win) then
    return
  end

  if state.status == "working" then
    local frames = { 1, 2, 1, 2, 0, 0 }
    local sway = { 0, 1, 0, -1, 0, 0 }
    local frame = 0
    local function tick()
      vim.defer_fn(function()
        if generation ~= state.mascot_action_generation then
          return
        end
        frame = frame % #frames + 1
        if not state.mascot_interacting then
          state.mascot_arm_frame = frames[frame]
          state.mascot_x = sway[frame]
          if opts.visible() then
            opts.render()
          end
        end
        tick()
      end, WORK_FRAME_MS)
    end
    tick()
  elseif state.status == "ready" then
    local function idle()
      vim.defer_fn(function()
        if generation ~= state.mascot_action_generation then
          return
        end
        state.mascot_antenna_offset = state.mascot_idle_direction
        state.mascot_idle_direction = -state.mascot_idle_direction
        if opts.visible() then
          opts.render()
        end
        vim.defer_fn(function()
          if generation ~= state.mascot_action_generation then
            return
          end
          state.mascot_antenna_offset = 0
          if opts.visible() then
            opts.render()
          end
          vim.defer_fn(function()
            if generation ~= state.mascot_action_generation then
              return
            end
            local direction = state.mascot_walk_direction
            state.mascot_walk_direction = -direction
            local steps = { 1, 2, 3, 2, 1, 0 }
            local function walk(index)
              if generation ~= state.mascot_action_generation then
                return
              end
              if state.mascot_interacting or vim.uv.now() - state.mascot_last_pet_at < PET_WINDOW_MS then
                state.mascot_walk_frame = 0
                idle()
                return
              end
              state.mascot_x = steps[index] * direction
              state.mascot_walk_frame = index == #steps and 0 or index % 2 + 1
              if opts.visible() then
                opts.render()
              end
              if index == #steps then
                idle()
              else
                vim.defer_fn(function()
                  walk(index + 1)
                end, WALK_STEP_MS)
              end
            end
            walk(1)
          end, 1800)
        end, IDLE_GESTURE_MS)
      end, IDLE_DELAY_MS)
    end
    idle()
  end
end

function M.schedule_gaze(state, args, opts)
  local win = vim.api.nvim_get_current_win()
  local card_row, card_column = track_card_cursor(state, args.event, opts)
  if win ~= state.card_win then
    state.mascot_card_cursor = nil
    if state.mascot_vertical_gaze ~= 0 then
      state.mascot_vertical_gaze = 0
      if opts.visible() then
        opts.render()
      end
    end
  end
  if ((state.config or {}).ui or {}).mascot_follow_cursor == false then
    return
  end
  local in_omniac = win == state.card_win
    or win == state.chat_win
    or win == state.input_win
    or win == state.activity_win
    or win == state.status_win
  if args.event == "WinEnter" then
    if in_omniac and not state.mascot_in_omniac then
      react_to_focus(state, opts)
    end
    state.mascot_in_omniac = in_omniac
  end
  if not in_omniac then
    if args.event == "WinEnter" and opts.visible() then
      state.mascot_target = "center"
      advance_gaze(state, opts)
    end
    return
  end
  if not opts.visible() then
    return
  end

  if win == state.card_win and card_row then
    local vertical = card_row < state.mascot_first_line + 2 and -1 or card_row > state.mascot_last_line - 2 and 1 or 0
    if vertical ~= state.mascot_vertical_gaze then
      state.mascot_vertical_gaze = vertical
      opts.render()
    end
    local center = math.floor(vim.api.nvim_win_get_width(state.card_win) / 2) + state.mascot_x
    state.mascot_target = card_column < center - 2 and "left" or card_column > center + 2 and "right" or "center"
    advance_gaze(state, opts)
    return
  end
  if win ~= state.chat_win and win ~= state.input_win then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local ok, position = pcall(vim.fn.screenpos, win, cursor[1], cursor[2] + 1)
  if not ok or not position or position.col == 0 then
    return
  end
  local window_left = vim.fn.win_screenpos(state.chat_win)[2]
  local fraction = (position.col - window_left) / math.max(1, vim.api.nvim_win_get_width(state.chat_win) - 1)
  local target = fraction < 1 / 3 and "left" or fraction > 2 / 3 and "right" or "center"
  if target == state.mascot_gaze and not state.mascot_gaze_pending then
    return
  end
  state.mascot_target = target
  advance_gaze(state, opts)
end

function M.start(state, opts)
  M.restart(state, opts)
  state.mascot_in_omniac = true
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter" }, {
    group = opts.augroup,
    callback = function(args)
      M.schedule_gaze(state, args, opts)
    end,
  })
  vim.on_key(function()
    if vim.api.nvim_get_current_win() == state.card_win then
      vim.schedule(function()
        if opts.valid_win(state.card_win) and vim.api.nvim_get_current_win() == state.card_win then
          M.schedule_gaze(state, { event = "CursorMoved" }, opts)
        end
      end)
    end
  end, opts.key_namespace)
end

function M.stop(state, opts)
  state.mascot_action_generation = state.mascot_action_generation + 1
  state.mascot_interaction_generation = state.mascot_interaction_generation + 1
  state.mascot_interacting = false
  state.mascot_arm_frame = 0
  state.mascot_antenna_offset = 0
  state.mascot_x = 0
  state.mascot_hop = 0
  state.mascot_walk_frame = 0
  state.mascot_vertical_gaze = 0
  state.mascot_card_cursor = nil
  state.mascot_pet_count = 0
  state.mascot_generation = state.mascot_generation + 1
  state.mascot_gaze_pending = false
  state.mascot_gaze = "center"
  state.mascot_target = "center"
  state.mascot_in_omniac = false
  state.mascot_reacting = false
  state.mascot_eye_height = 2
  state.mascot_reaction_id = state.mascot_reaction_id + 1
  vim.api.nvim_clear_autocmds({ group = opts.augroup })
  vim.on_key(nil, opts.key_namespace)
end

return M
