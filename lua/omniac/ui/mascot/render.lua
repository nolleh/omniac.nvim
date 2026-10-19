local text = require("omniac.ui.text")

local M = {}

local function add_line(lines, marks, value, group)
  table.insert(lines, value)
  if group then
    table.insert(marks, { line = #lines, from = 0, to = -1, group = group })
  end
end

local function add_mark(marks, line, from, to, group)
  table.insert(marks, { line = line, from = from, to = to, group = group })
end

local function add_boxed_line(lines, marks, value, size, group)
  local line = text.boxed_text(value, size)
  table.insert(lines, line)
  local lnum = #lines
  local border_width = #"│"
  add_mark(marks, lnum, 0, border_width, "OmniacBorder")
  add_mark(marks, lnum, #line - border_width, -1, "OmniacBorder")
  if group then
    add_mark(marks, lnum, border_width, #line - border_width, group)
  end
end

function M.header(state, lines, marks, size, agent_name)
  local box_width = math.max(40, size)
  local user = vim.env.USER or "there"
  local title = "Omniac Code"
  local top = "╭─ "
    .. title
    .. " "
    .. string.rep("─", math.max(0, box_width - vim.fn.strdisplaywidth(title) - 5))
    .. "╮"
  local bottom = text.box_line("╰", "─", "╯", box_width)

  add_line(lines, marks, top, "OmniacBorder")
  add_boxed_line(lines, marks, "", box_width, nil)
  add_boxed_line(lines, marks, "Welcome back " .. user .. "!", box_width, "OmniacAccent")
  add_boxed_line(lines, marks, "", box_width, nil)

  local sprite_width = 10
  local sprite_height = 12
  local sprite = {}
  for row = 1, sprite_height do
    sprite[row] = {}
    for column = 1, sprite_width do
      sprite[row][column] = " "
    end
  end

  local function fill_rect(left, top_row, right, bottom_row, color)
    for row = top_row, bottom_row do
      for column = left, right do
        local shifted_row = row - state.mascot_hop
        if shifted_row >= 1 and shifted_row <= sprite_height then
          sprite[shifted_row][column] = color
        end
      end
    end
  end

  fill_rect(5 + state.mascot_antenna_offset, 1, 6 + state.mascot_antenna_offset, 1, "mint")
  fill_rect(5, 2, 6, 2, "coral")
  fill_rect(3, 3, 8, 3, "coral")
  fill_rect(2, 4, 9, 7, "coral")
  fill_rect(1, 5, 1, 6, "mint")
  fill_rect(10, 5, 10, 6, "mint")
  local eye_offset = state.mascot_gaze == "left" and -1 or state.mascot_gaze == "right" and 1 or 0
  if state.mascot_eye_height > 0 then
    local eye_top = 7 - state.mascot_eye_height + state.mascot_vertical_gaze
    local eye_bottom = 6 + state.mascot_vertical_gaze
    fill_rect(4 + eye_offset, eye_top, 4 + eye_offset, eye_bottom, " ")
    fill_rect(7 + eye_offset, eye_top, 7 + eye_offset, eye_bottom, " ")
  end
  fill_rect(3, 8, 8, 8, "coral")
  fill_rect(3, 10, 8, 11, "coral")
  fill_rect(2, state.mascot_arm_frame == 1 and 10 or 11, 2, state.mascot_arm_frame == 1 and 10 or 11, "coral")
  fill_rect(9, state.mascot_arm_frame == 2 and 10 or 11, 9, state.mascot_arm_frame == 2 and 10 or 11, "coral")
  fill_rect(5, 10, 6, 11, "mint")
  fill_rect(4, state.mascot_walk_frame == 1 and 11 or 12, 4, state.mascot_walk_frame == 1 and 11 or 12, "coral")
  fill_rect(7, state.mascot_walk_frame == 2 and 11 or 12, 7, state.mascot_walk_frame == 2 and 11 or 12, "coral")

  local function pixel_glyph(top_color, bottom_color)
    if top_color == " " and bottom_color == " " then
      return " ", nil
    end
    if top_color == bottom_color then
      return "█", top_color == "mint" and "OmniacGraphicShade" or nil
    end
    if top_color == " " then
      return "▄", bottom_color == "mint" and "OmniacGraphicShade" or nil
    end
    if bottom_color == " " then
      return "▀", top_color == "mint" and "OmniacGraphicShade" or nil
    end
    return "▀", top_color == "mint" and "OmniacGraphicMintOverCoral" or "OmniacGraphicCoralOverMint"
  end

  state.mascot_first_line = #lines + 1
  for row = 1, sprite_height, 2 do
    local glyphs = {}
    local groups = {}
    for column = 1, sprite_width do
      glyphs[column], groups[column] = pixel_glyph(sprite[row][column], sprite[row + 1][column])
    end

    local line = table.concat(glyphs)
    local inner_width = box_width - 2
    local left_padding = math.floor((inner_width - vim.fn.strdisplaywidth(line)) / 2) + state.mascot_x
    add_line(
      lines,
      marks,
      "│"
        .. string.rep(" ", left_padding)
        .. line
        .. string.rep(" ", inner_width - left_padding - sprite_width)
        .. "│",
      "OmniacGraphic"
    )
    local byte_offset = #"│" + left_padding
    local run_group
    local run_start
    for column = 1, sprite_width do
      local group = groups[column]
      if group ~= run_group then
        if run_group then
          add_mark(marks, #lines, run_start, byte_offset, run_group)
        end
        run_group = group
        run_start = group and byte_offset or nil
      end
      byte_offset = byte_offset + #glyphs[column]
    end
    if run_group then
      add_mark(marks, #lines, run_start, byte_offset, run_group)
    end
  end
  state.mascot_last_line = #lines

  add_boxed_line(lines, marks, "O M N I A C", box_width, "OmniacWordmark")
  add_boxed_line(lines, marks, "", box_width, nil)
  add_boxed_line(
    lines,
    marks,
    agent_name(state.config) .. " / " .. vim.fn.fnamemodify(vim.loop.cwd() or "", ":~"),
    box_width,
    "OmniacMuted"
  )
  add_line(lines, marks, bottom, "OmniacBorder")
end

function M.pin_view(state, valid_win)
  if valid_win(state.card_win) then
    pcall(vim.api.nvim_win_call, state.card_win, function()
      vim.fn.winrestview({ topline = 1, leftcol = 0 })
    end)
  end
end

function M.card(state, opts)
  if not state.card_pinned or not opts.valid_buf(state.card_buf) then
    return
  end
  local lines = {}
  local marks = {}
  local card_width = opts.valid_win(state.card_win) and vim.api.nvim_win_get_width(state.card_win) or opts.width()
  M.header(state, lines, marks, card_width, opts.agent_name)
  vim.bo[state.card_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.card_buf, opts.namespace, 0, -1)
  vim.api.nvim_buf_set_lines(state.card_buf, 0, -1, false, lines)
  vim.bo[state.card_buf].modifiable = false
  vim.bo[state.card_buf].modified = false
  for _, mark in ipairs(marks) do
    opts.add_hl(state.card_buf, mark.line, mark.from, mark.to, mark.group)
  end
  M.pin_view(state, opts.valid_win)
end

function M.refresh(state, render_card, render_chat)
  if state.card_pinned then
    render_card()
  else
    render_chat(state.config, { skip_markdown = true })
  end
end

function M.visible(state, valid_buf, valid_win)
  if state.card_pinned then
    if
      not valid_win(state.card_win)
      or not valid_buf(state.card_buf)
      or vim.api.nvim_win_get_buf(state.card_win) ~= state.card_buf
      or vim.api.nvim_win_get_tabpage(state.card_win) ~= vim.api.nvim_get_current_tabpage()
    then
      return false
    end
    local top = vim.fn.line("w0", state.card_win)
    return top <= state.mascot_last_line
      and top + vim.api.nvim_win_get_height(state.card_win) - 1 >= state.mascot_first_line
  end
  if
    not valid_win(state.chat_win)
    or not valid_buf(state.chat_buf)
    or vim.api.nvim_win_get_buf(state.chat_win) ~= state.chat_buf
    or not state.mascot_first_line
  then
    return false
  end
  local top = vim.fn.line("w0", state.chat_win)
  return top <= state.mascot_last_line
    and top + vim.api.nvim_win_get_height(state.chat_win) - 1 >= state.mascot_first_line
end

return M
