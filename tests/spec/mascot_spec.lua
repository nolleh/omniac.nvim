local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim mascot", function()
  after_each(helpers.cleanup_after_test)

  it("welcome header renders a compact pixel robot and readable wordmark", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil

    local ui = require("omniac.ui")
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    local chat = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("omniac"), 0, -1, false), "\n")
    assert_true(chat:find("████", 1, true) ~= nil, "welcome header should show the block-pixel robot")
    assert_true(chat:find("O M N I A C", 1, true) ~= nil, "welcome header should show the wordmark")
    local sprite_rows = 0
    local widest_row = 0
    for line in chat:gmatch("[^\n]+") do
      local pixels = line:gsub("█", "X"):gsub("▀", "X"):gsub("▄", "X")
      local first = pixels:find("X", 1, true)
      if first then
        local last = #pixels - pixels:reverse():find("X", 1, true) + 1
        sprite_rows = sprite_rows + 1
        widest_row = math.max(widest_row, last - first + 1)
      end
    end
    assert_equal(sprite_rows, 6, "two vertical pixels should fit in each terminal row")
    assert_equal(widest_row, 10, "the full robot should stay compact")
    assert_true(
      chat:find("▄▄▄▄▄▄▄", 1, true) == nil,
      "welcome header should remove the previous large graphic"
    )
  end)

  it("pins the welcome card while chat messages scroll", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local previous_lines = vim.o.lines
    local previous_laststatus = vim.o.laststatus
    vim.o.lines = 50
    vim.o.laststatus = 3
    local ui = require("omniac.ui")
    local ok, err = xpcall(function()
      local ui_state = ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 48 } }, function(_) end)
      assert_true(ui_state.card_pinned and vim.api.nvim_win_is_valid(ui_state.card_win))
      assert_true(vim.api.nvim_buf_get_name(ui_state.card_buf):find("omniac://card", 1, true) ~= nil)
      assert_equal(vim.wo[ui_state.card_win].winbar, " omniac")
      assert_equal(vim.wo[ui_state.chat_win].winbar, "")
      local card = table.concat(vim.api.nvim_buf_get_lines(ui_state.card_buf, 0, -1, false), "\n")
      local chat_buf = ui_state.chat_buf
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      assert_true(card:find("O M N I A C", 1, true) ~= nil)
      assert_true(chat:find("O M N I A C", 1, true) == nil)
      assert_equal(vim.api.nvim_buf_line_count(ui_state.card_buf), 14)
      assert_true(vim.api.nvim_win_get_height(ui_state.card_win) >= 15, "pinned card must include the winbar")
      assert_true(vim.api.nvim_buf_get_lines(ui_state.card_buf, 13, 14, false)[1]:find("╰", 1, true) ~= nil)
      assert_equal(vim.fn.line("w0", ui_state.card_win), 1, "pinned card must start at the top")
      assert_equal(vim.fn.line("w$", ui_state.card_win), 14, "pinned card must show its bottom border")

      local initial_chat_height = vim.api.nvim_win_get_height(ui_state.chat_win)
      vim.cmd("botright 6split")
      local external_win = vim.api.nvim_get_current_win()
      vim.cmd("doautocmd WinResized")
      assert_true(
        vim.wait(250, function()
          return vim.api.nvim_win_get_height(ui_state.chat_win) < initial_chat_height
        end),
        "pinned chat should yield space to a bottom split"
      )
      assert_true(vim.api.nvim_win_get_height(external_win) >= 5)
      assert_equal(vim.fn.line("w$", ui_state.card_win), 14, "bottom split must not clip the card")
      vim.api.nvim_win_close(external_win, true)
      vim.cmd("doautocmd WinResized")

      ui.add_message("You", "A message after opening the card", ui_state.config)
      assert_equal(table.concat(vim.api.nvim_buf_get_lines(ui_state.card_buf, 0, -1, false), "\n"), card)
      assert_true(
        table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("A message", 1, true) ~= nil
      )

      local old_card_win = ui_state.card_win
      ui.close()
      cleanup_omniac_buffers()
      package.loaded["omniac.ui"] = nil
      ui = require("omniac.ui")
      local welcome_only = ui.open({
        agent = { cmd = { "codex-acp" } },
        ui = { chat_width = 48, welcome_card = "welcome_only" },
      }, function(_) end)
      assert_true(not welcome_only.card_pinned and not vim.api.nvim_win_is_valid(old_card_win))
      assert_true(
        table.concat(vim.api.nvim_buf_get_lines(welcome_only.chat_buf, 0, -1, false), "\n"):find("O M N I A C", 1, true)
          ~= nil
      )
      ui.add_message("You", "The conversation has started", welcome_only.config)
      assert_true(
        table.concat(vim.api.nvim_buf_get_lines(welcome_only.chat_buf, 0, -1, false), "\n"):find("O M N I A C", 1, true)
          == nil
      )
    end, debug.traceback)
    ui.close()
    vim.o.lines = previous_lines
    vim.o.laststatus = previous_laststatus
    if not ok then
      error(err)
    end
  end)

  it("returns the chat view to the top after clearing a session", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local ui_state = ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 48 } }, function(_) end)

    for index = 1, 30 do
      ui.add_message("You", "Message " .. index, ui_state.config)
    end
    vim.api.nvim_win_set_cursor(ui_state.chat_win, { vim.api.nvim_buf_line_count(ui_state.chat_buf), 0 })
    assert_true(vim.fn.line("w0", ui_state.chat_win) > 1, "chat should be scrolled before clearing")

    ui.clear_conversation(ui_state.config)

    assert_equal(vim.api.nvim_win_get_cursor(ui_state.chat_win)[1], 1, "chat cursor should return to the first line")
    assert_equal(vim.fn.line("w0", ui_state.chat_win), 1, "session card should start at the top")
  end)

  it("alternates mascot arms while working and stops when ready", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local previous_lines = vim.o.lines
    vim.o.lines = 50
    local ui = require("omniac.ui")
    local ok, err = xpcall(function()
      local ui_state = ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 48 } }, function(_) end)
      ui.set_status("working", ui_state.config)
      local chat = table.concat(vim.api.nvim_buf_get_lines(ui_state.chat_buf, 0, -1, false), "\n")
      assert_true(
        vim.wait(800, function()
          return ui_state.mascot_arm_frame == 1
        end),
        "working should raise one arm"
      )
      assert_true(
        vim.wait(800, function()
          return ui_state.mascot_arm_frame == 2
        end),
        "working should switch arms"
      )
      assert_equal(table.concat(vim.api.nvim_buf_get_lines(ui_state.chat_buf, 0, -1, false), "\n"), chat)
      ui.set_status("ready", ui_state.config)
      assert_equal(ui_state.mascot_arm_frame, 0, "ready should lower both arms")
      vim.wait(700)
      assert_equal(ui_state.mascot_arm_frame, 0, "old working animation should stop")

      ui.close()
      local still = ui.open({
        agent = { cmd = { "codex-acp" } },
        ui = { chat_width = 48, mascot_motion = false },
      }, function(_) end)
      ui.set_status("working", still.config)
      vim.wait(700)
      assert_equal(still.mascot_arm_frame, 0, "disabled motion should keep both arms still")
    end, debug.traceback)
    ui.close()
    vim.o.lines = previous_lines
    if not ok then
      error(err)
    end
  end)

  it("lets the card mascot follow and react to cursor movement", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local previous_lines = vim.o.lines
    vim.o.lines = 50
    local ui = require("omniac.ui")
    local ok, err = xpcall(function()
      local ui_state = ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 48 } }, function(_) end)
      ui.set_status("ready", ui_state.config)
      vim.api.nvim_set_current_win(ui_state.card_win)
      vim.wait(350)

      local row = ui_state.mascot_first_line + 2
      local line = vim.api.nvim_buf_get_lines(ui_state.card_buf, row - 1, row, false)[1]
      local block = line:find("█", 1, true)
      assert_true(block ~= nil, "mascot body should be visible on the card")
      vim.api.nvim_win_set_cursor(ui_state.card_win, { row, block - 1 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.card_buf })
      vim.api.nvim_win_set_cursor(ui_state.card_win, { row, block - 1 + #"█" })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.card_buf })
      assert_equal(ui_state.mascot_pet_count, 1, "horizontal movement on the mascot should pet it")
      assert_equal(ui_state.mascot_hop, 1, "the first pet should make the mascot hop")
      assert_equal(vim.api.nvim_win_get_cursor(ui_state.card_win)[1], row, "animation should preserve the card cursor")

      vim.api.nvim_win_set_cursor(ui_state.card_win, { row, block - 1 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.card_buf })
      vim.api.nvim_win_set_cursor(ui_state.card_win, { row, block - 1 + #"█" })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.card_buf })
      assert_equal(ui_state.mascot_pet_count, 0, "repeated pets should trigger a flee")
      assert_true(ui_state.mascot_x ~= 0, "fleeing should move the mascot sideways")
      assert_true(
        vim.wait(1500, function()
          return ui_state.mascot_x == 0 and ui_state.mascot_hop == 0
        end),
        "the mascot should return to its resting place"
      )

      vim.api.nvim_win_set_cursor(ui_state.card_win, { row + 1, block - 1 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.card_buf })
      assert_equal(ui_state.mascot_hop, 1, "vertical movement near the mascot should invite a hop")
      assert_equal(vim.api.nvim_win_get_cursor(ui_state.card_win)[1], row + 1)
      vim.wait(250)

      vim.api.nvim_win_set_cursor(ui_state.card_win, { ui_state.mascot_first_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.card_buf })
      assert_equal(ui_state.mascot_vertical_gaze, -1, "the mascot should look up as the cursor rises")
      vim.api.nvim_win_set_cursor(ui_state.card_win, { ui_state.mascot_last_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.card_buf })
      assert_equal(ui_state.mascot_vertical_gaze, 1, "the mascot should look down as the cursor falls")
      assert_equal(vim.api.nvim_win_get_cursor(ui_state.card_win)[1], ui_state.mascot_last_line)
    end, debug.traceback)
    ui.close()
    vim.o.lines = previous_lines
    if not ok then
      error(err)
    end
  end)

  it("takes occasional idle walks and returns to the center", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local previous_lines = vim.o.lines
    local original_defer = vim.defer_fn
    vim.o.lines = 50
    vim.defer_fn = function(callback, delay)
      local quick = ({ [11000] = 30, [350] = 20, [1800] = 20, [380] = 50 })[delay]
      return original_defer(callback, quick or delay)
    end
    local ui = require("omniac.ui")
    local ok, err = xpcall(function()
      local ui_state = ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 48 } }, function(_) end)
      ui.set_status("ready", ui_state.config)
      assert_true(
        vim.wait(500, function()
          return ui_state.mascot_x ~= 0 and ui_state.mascot_walk_frame ~= 0
        end),
        "idle mascot should take a step"
      )
      assert_true(
        vim.wait(500, function()
          return ui_state.mascot_x == 0 and ui_state.mascot_walk_frame == 0
        end),
        "idle mascot should come home after walking"
      )
    end, debug.traceback)
    ui.close()
    vim.defer_fn = original_defer
    vim.o.lines = previous_lines
    if not ok then
      error(err)
    end
  end)

  it("mascot reacts to Omniac focus and follows its cursor without moving the card", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    vim.cmd("tabnew")

    local editor_win = vim.api.nvim_get_current_win()
    local editor_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { string.rep("x", 120) })
    vim.wo[editor_win].wrap = false

    local ui = require("omniac.ui")
    local ui_state = ui.open({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 48 } }, function(_) end)
    vim.api.nvim_win_set_height(ui_state.chat_win, 12)
    local chat_buf = vim.fn.bufnr("omniac")
    local line_count = vim.api.nvim_buf_line_count(chat_buf)
    local center_eye_line = vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1]

    vim.api.nvim_set_current_win(editor_win)
    vim.api.nvim_win_set_cursor(editor_win, { 1, 26 })
    vim.cmd("redraw")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = editor_buf })
    vim.wait(250)
    assert_equal(ui_state.mascot_gaze, "center", "external cursor movement should not steer the mascot")
    assert_equal(vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1], center_eye_line)

    vim.api.nvim_set_current_win(ui_state.input_win)
    assert_true(
      vim.wait(100, function()
        return ui_state.mascot_reacting
      end),
      "entering Omniac should trigger a brief blink"
    )
    assert_true(
      vim.wait(100, function()
        return vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1] ~= center_eye_line
      end),
      "the eyes should visibly shrink during the blink"
    )
    assert_true(
      vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1]:find("▀", 1, true) ~= nil,
      "half-height black eyes should remain visible"
    )
    vim.cmd("redraw")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.input_buf })
    assert_equal(ui_state.mascot_target, "left", "the input cursor should set the post-blink gaze")
    assert_true(
      vim.wait(180, function()
        return ui_state.mascot_eye_height == 0
      end),
      "the blink should include a fully closed frame"
    )
    local closed_eye_line = vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1]
    assert_true(closed_eye_line ~= center_eye_line and closed_eye_line:find("▀", 1, true) == nil)
    assert_true(
      vim.wait(180, function()
        return ui_state.mascot_eye_height == 1
      end),
      "the eyes should reopen through the half-height frame"
    )
    assert_equal(ui_state.mascot_gaze, "center", "the eyes should not move during the blink")
    assert_true(
      vim.wait(350, function()
        return not ui_state.mascot_reacting
      end),
      "the blink should end without moving the card"
    )
    assert_equal(vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1], center_eye_line)
    assert_true(
      vim.wait(400, function()
        return ui_state.mascot_gaze == "left"
      end),
      "the eyes should move toward the cursor after the blink"
    )

    vim.api.nvim_set_current_win(ui_state.chat_win)
    vim.api.nvim_win_set_cursor(ui_state.chat_win, { 2, 4 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = chat_buf })
    assert_true(
      vim.wait(400, function()
        return ui_state.mascot_gaze == "left"
      end),
      "the eyes should look left inside the chat"
    )
    local left_eye_line = vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1]

    vim.api.nvim_win_set_cursor(ui_state.chat_win, { 2, 43 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = chat_buf })
    assert_true(
      vim.wait(600, function()
        return ui_state.mascot_gaze == "right"
      end),
      "the eyes should slowly cross through center"
    )
    assert_true(vim.api.nvim_buf_get_lines(chat_buf, 6, 7, false)[1] ~= left_eye_line)
    assert_equal(vim.api.nvim_buf_line_count(chat_buf), line_count, "gaze should not resize the card")

    vim.api.nvim_set_current_win(ui_state.input_win)
    vim.bo[ui_state.input_buf].modifiable = true
    vim.api.nvim_buf_set_lines(ui_state.input_buf, 0, 1, false, { "│ > " .. string.rep("x", 38) .. " │" })
    vim.api.nvim_win_set_cursor(ui_state.input_win, { 1, 4 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.input_buf })
    assert_true(
      vim.wait(400, function()
        return ui_state.mascot_gaze == "left"
      end),
      "the eyes should also follow the input cursor"
    )

    ui_state.config.ui.mascot_follow_cursor = false
    vim.api.nvim_win_set_cursor(ui_state.input_win, { 1, 40 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.input_buf })
    vim.wait(250)
    assert_equal(ui_state.mascot_gaze, "left", "mascot gaze should honor the opt-out")

    ui.close()
    vim.cmd("tabclose!")
  end)
end)
