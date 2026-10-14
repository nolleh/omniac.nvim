local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed

describe("omniac.nvim changes", function()
  after_each(helpers.cleanup_after_test)

  it("diff review accepts with :w", function()
    package.loaded["omniac.diff"] = nil
    local diff = require("omniac.diff")
    local result

    diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {}, function(accepted, lines)
      result = {
        accepted = accepted,
        lines = lines,
      }
    end)

    vim.cmd("w")

    assert_true(result ~= nil, "review callback should run")
    assert_equal(result.accepted, true, "review should be accepted")
    assert_equal(result.lines[1], "new", "accepted lines should come from proposed buffer")
  end)

  it("diff review denies with :q", function()
    package.loaded["omniac.diff"] = nil
    local diff = require("omniac.diff")
    local result

    diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {}, function(accepted, lines)
      result = {
        accepted = accepted,
        lines = lines,
      }
    end)

    vim.cmd("q")

    assert_true(result ~= nil, "review callback should run")
    assert_equal(result.accepted, false, "review should be denied")
    assert_equal(result.lines, nil, "denied review should not return accepted lines")
  end)

  it("diff review can deny edited proposed buffer with :q", function()
    package.loaded["omniac.diff"] = nil
    local diff = require("omniac.diff")
    local result

    diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {}, function(accepted, lines)
      result = {
        accepted = accepted,
        lines = lines,
      }
    end)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
    vim.cmd("doautocmd TextChanged")
    assert_equal(vim.bo.modified, false, "review buffer should stay quit-safe after edit")
    vim.cmd("q")

    assert_true(result ~= nil, "review callback should run")
    assert_equal(result.accepted, false, "edited review should still be denied by :q")
  end)

  it("diff review opens in normal mode", function()
    package.loaded["omniac.diff"] = nil
    local diff = require("omniac.diff")

    vim.cmd("startinsert")
    local edited
    diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {}, function(_, _, was_edited)
      edited = was_edited
    end)

    vim.wait(50, function()
      return not vim.fn.mode():match("^[iR]")
    end)
    assert_true(not vim.fn.mode():match("^i"), "diff review should leave insert mode when it opens")
    vim.cmd("w")
    assert_equal(edited, false, "opening the diff should not count as an edit")
  end)

  it("diff review jumps to the first changed line", function()
    package.loaded["omniac.diff"] = nil
    local diff = require("omniac.diff")

    diff.open_review("/tmp/omniac-test.txt", { "keep", "old", "tail" }, { "keep", "new", "tail" }, {})

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert_equal(cursor[1], 2, "diff review should place the cursor on the first changed line")
    assert_equal(cursor[2], 0, "diff review cursor should start at column 0")
  end)

  it("change preview is read-only and does not write the file", function()
    package.loaded["omniac.diff"] = nil
    local diff = require("omniac.diff")
    local path = "/private/tmp/omniac-change-preview-" .. tostring(vim.loop.hrtime()) .. ".txt"
    vim.fn.writefile({ "disk" }, path)

    local handles = diff.open_preview(path, { "before" }, { "after" }, {})

    assert_equal(vim.bo[handles.before_buf].modifiable, false, "preview before buffer should be immutable")
    assert_equal(vim.bo[handles.after_buf].modifiable, false, "preview after buffer should be immutable")
    assert_equal(vim.bo[handles.after_buf].readonly, true, "preview should be read-only")
    assert_equal(vim.bo[handles.after_buf].buftype, "nofile", "preview should not support writes")
    assert_equal(vim.fn.readfile(path)[1], "disk", "opening a preview should not touch the file")

    vim.cmd("q")
    pcall(vim.fn.delete, path)
  end)

  it("change tracker keeps latest turn and cumulative session changes", function()
    package.loaded["omniac.changes"] = nil
    local changes = require("omniac.changes")
    local path = "/tmp/omniac-change.lua"

    changes.reset("sess_1")
    changes.start_turn({ sessionId = "sess_1", turnId = 1 })
    changes.record({
      sessionId = "sess_1",
      turnId = 1,
      path = path,
      oldText = "before\n",
      newText = "middle\n",
    })
    changes.record({
      sessionId = "sess_1",
      turnId = 1,
      path = path,
      oldText = "middle\n",
      newText = "after\n",
    })

    assert_equal(changes.finish_turn({ sessionId = "sess_1", turnId = 1 }), 1, "turn should deduplicate files")
    assert_equal(changes.get("turn")[1].oldText, "before\n", "turn should keep the first file contents")
    assert_equal(changes.get("turn")[1].newText, "after\n", "turn should keep the latest file contents")

    changes.start_turn({ sessionId = "sess_1", turnId = 2 })
    changes.record({
      sessionId = "sess_1",
      turnId = 2,
      path = path,
      oldText = "after\n",
      newText = "final\n",
    })
    changes.finish_turn({ sessionId = "sess_1", turnId = 2 })

    assert_equal(changes.get("turn")[1].oldText, "after\n", "latest turn should have its own baseline")
    assert_equal(changes.get("session")[1].oldText, "before\n", "session should keep its initial baseline")
    assert_equal(changes.get("session")[1].newText, "final\n", "session should keep the latest contents")

    changes.start_turn({ sessionId = "sess_1", turnId = 3 })
    assert_equal(
      changes.finish_turn({ sessionId = "sess_1", turnId = 2 }),
      0,
      "late completion should not replace the active turn"
    )
    assert_equal(#changes.get("turn"), 0, "latest turn review should remain on the active turn")

    local change_dialog = require("omniac.change_dialog")
    local original_open = change_dialog.open
    local diff = require("omniac.diff")
    local original_preview = diff.open_preview
    local selected_scope
    local previewed
    local original_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vnew")
    local input_win = vim.api.nvim_get_current_win()
    local input_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(input_buf, "omniac://change-test-input")
    vim.bo[input_buf].buftype = "nofile"
    vim.bo[input_buf].filetype = "omniac-input"
    vim.w[input_win].omniac_ui = true
    change_dialog.open = function(entries, opts, callback)
      selected_scope = opts.scope
      callback(entries[1])
    end
    diff.open_preview = function(selected_path, before, after, opts)
      previewed = {
        path = selected_path,
        before = before,
        after = after,
        origin_win = opts.origin_win,
      }
    end

    local opened = changes.open("session", { ui = {} })
    change_dialog.open = original_open
    diff.open_preview = original_preview
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_close(input_win, true)
    end

    assert_equal(opened, true, "change browser should open when session changes exist")
    assert_equal(selected_scope, "session", "change browser should identify its scope")
    assert_equal(previewed.path, path, "selected change should open its file preview")
    assert_equal(previewed.before[1], "before", "preview should use the session baseline")
    assert_equal(previewed.after[1], "final", "preview should use the latest session contents")
    assert_equal(previewed.origin_win, original_win, "change preview should avoid the Omniac input window")
  end)

  it("change dialog matches the session picker layout and selects a file", function()
    package.loaded["omniac.change_dialog"] = nil
    local dialog = require("omniac.change_dialog")
    local result

    dialog.open({
      {
        path = "/tmp/project/README.md",
        operation = "modify",
        source = "acp",
        turnId = 7,
      },
      {
        path = "/tmp/project/lua/omniac/ui.lua",
        operation = "add",
        title = "Build status capsule",
        turnId = 7,
      },
    }, {
      scope = "session",
    }, function(selection)
      result = selection
    end)

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local rendered = table.concat(lines, "\n")
    assert_true(rendered:match("OMNIAC CHANGES") ~= nil, "change dialog should render a branded heading")
    assert_true(rendered:match("connection started") ~= nil, "change dialog should explain the session scope")
    assert_true(rendered:match("README%.md") ~= nil, "change dialog should list changed files")
    assert_true(rendered:match("ACP edit") ~= nil, "change dialog should render change metadata")
    local first_detail_line
    for index, line in ipairs(lines) do
      if line:find("ACP edit", 1, true) then
        first_detail_line = index
        break
      end
    end
    assert_true(first_detail_line ~= nil, "first change should show its details")
    assert_true(lines[first_detail_line + 1]:match("^%s+$") ~= nil, "change rows should keep a blank line")
    assert_true(lines[first_detail_line + 2]:match("ui%.lua") ~= nil, "next change should follow the blank line")

    local footer_rendered = ""
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "omniac-changes-footer" then
        footer_rendered = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        break
      end
    end
    assert_true(footer_rendered:match("%[Enter%] review") ~= nil, "change actions should render in the footer")

    feed("j")
    feed("<CR>")
    assert_equal(result.path, "/tmp/project/lua/omniac/ui.lua", "enter should select the highlighted change")
  end)

  it("change dialog stays in normal mode and cannot be edited", function()
    package.loaded["omniac.change_dialog"] = nil
    local dialog = require("omniac.change_dialog")
    vim.cmd("startinsert")
    dialog.open({ { path = "/tmp/project/README.md", operation = "modify" } }, { scope = "turn" }, function() end)

    assert_true(not vim.fn.mode():match("^[iR]"), "change dialog should open in normal mode")
    assert_equal(vim.bo.modifiable, false, "change dialog should be unmodifiable")
    local original = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    feed("i")
    assert_true(
      vim.wait(100, function()
        return not vim.fn.mode():match("^[iR]")
      end),
      "change dialog should leave insert mode"
    )
    vim.cmd("startinsert")
    assert_true(
      vim.wait(100, function()
        return not vim.fn.mode():match("^[iR]")
      end),
      "change dialog should reject external insert mode"
    )
    assert_equal(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
      original,
      "typing should not edit the dialog"
    )
    feed("q")
  end)

  it("reopens the selected session change after closing its preview", function()
    package.loaded["omniac.changes"] = nil
    local changes = require("omniac.changes")
    changes.reset("reopen_session")
    changes.start_turn({ sessionId = "reopen_session", turnId = 1 })
    for _, name in ipairs({ "first.txt", "second.txt" }) do
      changes.record({
        sessionId = "reopen_session",
        turnId = 1,
        path = "/tmp/project/" .. name,
        oldText = "before\n",
        newText = "after\n",
      })
    end
    changes.finish_turn({ sessionId = "reopen_session", turnId = 1 })

    assert_equal(changes.open("session", { ui = {} }), true, "session changes should open")
    feed("j")
    feed("<CR>")
    assert_true(vim.api.nvim_buf_get_name(0):match("Omniac changes:") ~= nil, "preview should open")
    vim.cmd("q")
    assert_true(
      vim.wait(200, function()
        return vim.api.nvim_buf_get_name(0) == "omniac://changes"
      end),
      "closing preview should reopen the change dialog"
    )

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert_true(table.concat(lines, "\n"):match("connection started") ~= nil, "session scope should be retained")
    assert_true(lines[vim.api.nvim_win_get_cursor(0)[1]]:match("second%.txt") ~= nil, "selection should be retained")
    feed("q")
  end)

  it("session dialog flattens multiline session titles", function()
    package.loaded["omniac.session_dialog"] = nil
    local dialog = require("omniac.session_dialog")
    local result

    dialog.open({
      {
        sessionId = "sess_1",
        title = "first line\n\nCurrent file: omniac://input",
        cwd = "/tmp/project",
        updatedAt = "2026-06-04T13:03:55.000Z",
      },
    }, {
      list_supported = true,
    }, function(selection)
      result = selection
    end)

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local rendered = table.concat(lines, "\n")
    assert_true(rendered:match("current file") ~= nil, "session title metadata should preserve regular letters")
    assert_true(rendered:match("%[LOAD%]") == nil, "session rows should not repeat the load action label")
    assert_true(rendered:match("sess_1") ~= nil, "session item should render after flattening multiline text")
    assert_true(rendered:match("전") ~= nil, "session metadata should include relative time")
    assert_true(lines[#lines]:match("^%s+$") ~= nil, "session rows should retain a blank line after their details")
    local footer_rendered = ""
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "omniac-session-footer" then
        footer_rendered = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        break
      end
    end
    assert_true(footer_rendered:match("%[n%] new") ~= nil, "new session action should render in the footer")

    feed("q")
    assert_equal(result, nil, "closing the dialog without selection should not choose a session")
  end)
end)
