local function assert_equal(actual, expected, message)
  assert.are.equal(expected, actual, message)
end

local function assert_true(value, message)
  assert.is_true(not not value, message)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(tostring(keys or ""), true, false, true), "xt", false)
  vim.wait(20, function()
    return true
  end)
  vim.cmd("redraw")
end

local function cleanup_omniac_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local basename = vim.fn.fnamemodify(name, ":t")
    if basename == "omniac" or name:match("omniac://") then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function has_window_for_buffer_name(name)
  local target = vim.fn.bufnr(name)
  if target == -1 then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == target then
      return true
    end
  end
  return false
end

describe("omniac.nvim", function()
  after_each(function()
    cleanup_omniac_buffers()
    pcall(vim.api.nvim_del_user_command, "OmniacReferenceBuffer")
    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
    package.loaded["omniac.clipboard"] = nil
  end)

  it("defaults use an ACP agent without backend selection", function()
    package.loaded["omniac.config"] = nil
    local defaults = require("omniac.config").defaults

    assert_equal(defaults.agent.cmd[1], "codex-acp", "default command should speak ACP")
    assert_equal(defaults.backend, nil, "backend selection should not be configurable")
    assert_equal(defaults.agent.auto_initialize, nil, "legacy transport initialization should be removed")
    assert_equal(defaults.ui.change_review, "summary", "change review should default to a non-blocking summary")
    assert_equal(defaults.ui.welcome_card, "pinned", "welcome card should default to pinned")
    assert_equal(defaults.ui.mascot_follow_cursor, true, "mascot gaze should default to enabled")
    assert_equal(defaults.ui.mascot_motion, true, "mascot idle and work motion should default to enabled")
    assert_equal(defaults.references.include_modified_buffer, false, "full modified-buffer references should be opt-in")
  end)

  it("stdio transport exposes protocol primitives only", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({})

    assert_true(type(client.request) == "function", "transport should expose JSON-RPC requests")
    assert_true(type(client.notify) == "function", "transport should expose JSON-RPC notifications")
    assert_true(type(client.respond) == "function", "transport should expose JSON-RPC responses")
    assert_equal(client.thread_start, nil, "transport should not expose Codex thread startup")
    assert_equal(client.turn_start, nil, "transport should not expose Codex turn startup")
    assert_equal(client.prompt, nil, "transport should not expose Codex prompt handling")
  end)

  it("stdio transport sends JSON-RPC 2.0 request and response envelopes", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({})
    local sent = {}

    client.running = true
    client.jobid = 1
    client._send_raw = function(_, payload)
      table.insert(sent, payload)
    end

    client:request("initialize", {})
    client:notify("session/cancel", { sessionId = "sess_1" })
    client:respond("server-request", {})
    client:_dispatch_message({
      jsonrpc = "2.0",
      id = "agent-request",
      method = "client/unknown",
      params = {},
    })

    assert_equal(sent[1].jsonrpc, "2.0", "requests should declare JSON-RPC 2.0")
    assert_equal(sent[1].method, "initialize", "request method should be preserved")
    assert_equal(sent[2].method, "session/cancel", "notification method should be preserved")
    assert_equal(sent[2].id, nil, "notifications must not have an id")
    assert_equal(sent[2].params.sessionId, "sess_1", "notification params should be preserved")
    assert_equal(sent[3].jsonrpc, "2.0", "responses should declare JSON-RPC 2.0")
    assert_equal(sent[3].id, "server-request", "response id should be preserved")
    assert_equal(sent[4].jsonrpc, "2.0", "automatic responses should declare JSON-RPC 2.0")
    assert_equal(sent[4].id, "agent-request", "automatic response id should be preserved")
  end)

  it("stdio transport keeps large debug chunks as summaries", function()
    package.loaded["omniac.transport.stdio"] = nil
    local client = require("omniac.transport.stdio").new({ debug = true })
    local notifications = {}
    client:on_notification(function(message)
      table.insert(notifications, message)
    end)

    client:_debug("stdout_chunk", { lines = { string.rep("x", 10000), "tail" } })

    local entry = client:get_debug_log()[1]
    assert_equal(entry.payload.line_count, 2, "debug summary should retain the line count")
    assert_equal(entry.payload.bytes, 10004, "debug summary should retain the byte count")
    assert_equal(#notifications, 0, "debug bookkeeping should not emit protocol notifications")
  end)

  it("selection references preserve source range and unsaved text", function()
    package.loaded["omniac.selection"] = nil
    local selection = require("omniac.selection")
    local buf = vim.api.nvim_create_buf(false, false)
    local path = "/private/tmp/omniac-reference-" .. tostring(vim.loop.hrtime()) .. ".lua"

    vim.api.nvim_buf_set_name(buf, path)
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local first = true",
      "local second = true",
      "return second",
    })
    vim.bo[buf].modified = true

    local reference = selection.reference_from_range(buf, 2, 3)

    assert_equal(reference.type, "reference", "selection should become a reference attachment")
    assert_equal(reference.path, path, "reference should preserve the source path")
    assert_equal(reference.filetype, "lua", "reference should preserve the source filetype")
    assert_equal(reference.startLine, 2, "reference should preserve the first selected line")
    assert_equal(reference.endLine, 3, "reference should preserve the last selected line")
    assert_equal(reference.text, "local second = true\nreturn second", "reference should capture buffer text")
    assert_equal(reference.modified, true, "reference should record unsaved buffer state")
    assert_true(reference.uri:match("#L2%-L3$") ~= nil, "reference URI should identify its line range")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("current-buffer references omit unsaved contents unless explicitly enabled", function()
    cleanup_omniac_buffers()
    pcall(vim.api.nvim_del_user_command, "OmniacReferenceBuffer")
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil

    local omniac = require("omniac")
    omniac.setup({ agent = { cmd = { "custom-acp" } }, keymaps = false })
    omniac.open_chat = function() end

    local ui = require("omniac.ui")
    local original_attach = ui.attach_reference
    local attached = {}
    ui.attach_reference = function(reference)
      table.insert(attached, reference)
    end

    local path = "/private/tmp/omniac-buffer-reference-" .. tostring(vim.loop.hrtime()) .. ".lua"
    assert_equal(vim.fn.writefile({ "on disk" }, path), 0, "test fixture should be written")
    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved", "buffer content" })
    vim.bo[bufnr].modified = true
    vim.api.nvim_set_current_buf(bufnr)

    local ok, err = pcall(vim.cmd, "OmniacReferenceBuffer")
    if ok then
      omniac.config.references.include_modified_buffer = true
      ok, err = pcall(vim.cmd, "OmniacReferenceBuffer")
    end
    ui.attach_reference = original_attach
    vim.fn.delete(path)

    assert_true(ok, tostring(err))
    assert_equal(#attached, 2, "both reference policies should attach the current file")
    assert_equal(attached[1].pathOnly, true, "default policy should link the on-disk file")
    assert_equal(attached[1].text, "unsaved\nbuffer content", "the captured buffer remains available locally")
    assert_equal(attached[2].pathOnly, false, "opt-in policy should embed the modified buffer")
    assert_equal(attached[2].text, "unsaved\nbuffer content", "opt-in should include the full buffer contents")

    omniac.config.references.include_modified_buffer = false
    local unnamed_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(unnamed_buf, 0, -1, false, { "unpersisted content" })
    vim.bo[unnamed_buf].modified = true
    vim.api.nvim_set_current_buf(unnamed_buf)
    assert_true(pcall(vim.cmd, "OmniacReferenceBuffer"), "referencing an unnamed buffer should be safe")
    assert_equal(#attached, 2, "unpersisted buffer contents should not be attached by default")

    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.api.nvim_buf_delete(unnamed_buf, { force = true })
  end)

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
    diff.open_review("/tmp/omniac-test.txt", { "old" }, { "new" }, {})

    assert_true(not vim.fn.mode():match("^i"), "diff review should leave insert mode when it opens")
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

  it("input focus returns to end of wrapped message", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    feed(string.rep("a", 80))
    vim.cmd("stopinsert")
    vim.cmd("wincmd p")
    feed("i")
    vim.cmd("redraw")

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local view = vim.fn.winsaveview()

    assert_equal(vim.wo.wrap, true, "input window should wrap instead of horizontal scrolling")
    assert_equal(view.leftcol, 0, "input window should not be horizontally scrolled")
    assert_equal(cursor[1], #lines - 1, "cursor should return to final input display line")
    assert_true(cursor[2] > 0, "cursor should be past the input prefix")
    vim.cmd("stopinsert")
  end)

  it("input cursor is clamped away from prompt marker", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("startinsert")
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    vim.cmd("doautocmd CursorMovedI")
    vim.cmd("redraw")

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert_true(cursor[2] >= #"│ > ", "cursor should be moved to the content column")
    vim.cmd("stopinsert")
  end)

  it("input padding cursor is remapped safely", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(0, { 3, #"│ " })
    vim.cmd("doautocmd TextChangedI")
    vim.cmd("redraw")

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert_equal(cursor[1], 2, "padding cursor should map back to the editable input line")
  end)

  it("input history recalls previous prompts with up and down", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted = {}
    local input_buf

    local function wait_for(predicate, message)
      local ok = vim.wait(500, function()
        if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
          return false
        end
        return predicate(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
      end)
      assert_true(ok, message or "timed out waiting for input state")
    end

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(text)
      table.insert(submitted, text)
    end)

    feed("ifirst prompt<CR>")
    feed("isecond prompt<CR>")

    feed("<Up>")
    vim.cmd("redraw")
    input_buf = vim.fn.bufnr("omniac://input")
    wait_for(function(lines)
      return table.concat(lines, "\n"):match("second prompt") ~= nil
    end, "timed out waiting for input to show second prompt")

    feed("<Up>")
    vim.cmd("redraw")
    wait_for(function(lines)
      return table.concat(lines, "\n"):match("first prompt") ~= nil
    end, "timed out waiting for input to show first prompt")

    feed("<Down>")
    vim.cmd("redraw")
    wait_for(function(lines)
      return table.concat(lines, "\n"):match("second prompt") ~= nil
    end, "timed out waiting for input to show second prompt")

    feed("<Down>")
    vim.cmd("redraw")
    wait_for(function(lines)
      return (lines[2] or "") == "│ > "
    end, "timed out waiting for empty prompt")

    assert_equal(submitted[1], "first prompt", "first prompt should be submitted")
    assert_equal(submitted[2], "second prompt", "second prompt should be submitted")
  end)

  it("input up and down keep normal cursor motion when text is present", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    feed("ihello")
    local before = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("omniac://input"), 0, -1, false), "\n")
    feed("<Up>")
    vim.cmd("redraw")
    local after = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("omniac://input"), 0, -1, false), "\n")
    assert_equal(after, before, "up should not replace non-empty input with history")
  end)

  it("tab switches between Omniac input and chat windows", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "Omniac should open focused on input")

    feed("<Tab>")
    vim.cmd("redraw")
    assert_equal(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "omniac", "Tab should focus chat")

    feed("<S-Tab>")
    vim.cmd("redraw")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "Shift-Tab should focus input")
  end)

  it("tab navigation works from explicitly focused activity window", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local activity_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == "omniac://activity" then
        activity_win = win
        break
      end
    end
    assert_true(activity_win ~= nil, "activity window should exist")

    vim.api.nvim_set_current_win(activity_win)
    feed("<Tab>")
    vim.cmd("redraw")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "Tab from activity should focus input")

    vim.api.nvim_set_current_win(activity_win)
    feed("<S-Tab>")
    vim.cmd("redraw")
    assert_equal(
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
      "omniac",
      "Shift-Tab from activity should focus chat"
    )
  end)

  it("closes every Omniac split when one of them is quit", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local original_win = vim.api.nvim_get_current_win()
    local ui_state = ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)
    local omniac_wins = {
      ui_state.card_win,
      ui_state.chat_win,
      ui_state.activity_win,
      ui_state.input_win,
      ui_state.status_win,
    }

    vim.api.nvim_win_call(ui_state.activity_win, function()
      vim.cmd("quit")
    end)

    assert_true(
      vim.wait(250, function()
        for _, win in ipairs(omniac_wins) do
          if win and vim.api.nvim_win_is_valid(win) then
            return false
          end
        end
        return true
      end),
      "quitting one Omniac split should close the whole UI"
    )
    assert_true(vim.api.nvim_win_is_valid(original_win), "quitting Omniac should preserve the original editor window")
  end)

  it("input ctrl-v attaches clipboard image and submits it", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.clipboard"] = {
      read_image = function()
        return {
          type = "image",
          mimeType = "image/png",
          data = "aW1n",
          byteSize = 3,
        }
      end,
    }
    local ui = require("omniac.ui")
    local submitted_text
    local submitted_attachments

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(text, attachments)
      submitted_text = text
      submitted_attachments = attachments
    end)

    vim.cmd("startinsert")
    feed("<C-v>")
    vim.wait(20)
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 1, 2, false, { "│ > describe image" })
    feed("<CR>")
    vim.cmd("redraw")

    assert_equal(submitted_text, "describe image", "submit should keep typed prompt text")
    assert_equal(#submitted_attachments, 1, "submit should include the pasted image")
    assert_equal(submitted_attachments[1].mimeType, "image/png", "image mime type should be preserved")

    package.loaded["omniac.clipboard"] = nil
  end)

  it("input allows greater-than as user text", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(0, { 2, #"│ > " })
    feed("i><Esc>")
    vim.cmd("redraw")

    local line = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 1, 2, false)[1]
    assert_equal(line, "│ > >", "greater-than should be kept as input text")
  end)

  it("normal i inside input prompt starts at content column", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    feed("ix<Esc>")
    vim.cmd("redraw")

    local line = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 1, 2, false)[1]
    assert_equal(line, "│ > x", "typed text should be inserted after the input prompt")
  end)

  it("input height shrinks back to three display lines", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    assert_equal(vim.api.nvim_win_get_height(0), 5, "input window should start with three display lines")
    assert_equal(vim.api.nvim_buf_line_count(0), 5, "input box should start with three display lines")

    local text = table.concat({ "a", "b", "c", "d", "e" }, "<S-CR>")
    feed("i" .. text .. "<Esc>")
    vim.cmd("redraw")

    assert_equal(vim.api.nvim_win_get_height(0), 7, "input window should grow with input lines")

    feed("i<BS><BS><BS><BS><Esc>")
    vim.cmd("redraw")

    assert_equal(vim.api.nvim_win_get_height(0), 5, "input window should shrink back to the minimum display height")
    assert_equal(vim.api.nvim_buf_line_count(0), 5, "input box should fill the minimum input window height")
    assert_equal(vim.fn.winsaveview().topline, 1, "input top border should stay visible")
  end)

  it("input line background does not override border foreground", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local input_hl = vim.api.nvim_get_hl(0, { name = "OmniacInput" })
    local input_text_hl = vim.api.nvim_get_hl(0, { name = "OmniacInputText" })

    assert_equal(input_hl.fg, nil, "input line highlight should only provide the input background")
    assert_equal(input_hl.bg, tonumber("313244", 16), "input line highlight should keep the input background")
    assert_equal(input_text_hl.fg, tonumber("cdd6f4", 16), "input text should keep the normal input foreground")
    assert_equal(input_text_hl.bg, tonumber("313244", 16), "input text should keep the input background")
  end)

  it("activity text keeps horizontal padding when truncated", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 42 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "completed",
        title = string.rep("very-long-command ", 10),
        exitCode = 0,
      },
    }, { ui = { chat_width = 42 } })

    local activity_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):match("omniac://activity") then
        activity_buf = buf
        break
      end
    end

    assert_true(activity_buf ~= nil, "activity buffer should exist")
    local line = vim.api.nvim_buf_get_lines(activity_buf, 0, 1, false)[1]
    assert_true(line:match("^  "), "activity line should keep left padding")
    assert_true(line:match("  $"), "activity line should keep right padding")
  end)

  it("multiline activity grows to three lines and shrinks again", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity_win = vim.fn.win_findbuf(activity_buf)[1]
    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win = vim.fn.win_findbuf(chat_buf)[1]
    local initial_chat_height = vim.api.nvim_win_get_height(chat_win)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 42 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "in_progress",
        title = table.concat({ "first command", "second command", "third command", "fourth command" }, "\n"),
      },
    }, { ui = { chat_width = 42 } })

    local expanded = vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false)
    assert_equal(#expanded, 3, "activity should show at most three lines")
    assert_equal(vim.api.nvim_win_get_height(activity_win), 3, "activity window should grow with multiline text")
    assert_true(expanded[1]:match("first command") ~= nil, "activity should keep the first command line")
    assert_true(expanded[2]:match("second command") ~= nil, "activity should keep the second command line")
    assert_true(expanded[3]:match("third command…") ~= nil, "activity should ellipsize hidden lines")
    assert_equal(
      vim.api.nvim_win_get_height(chat_win),
      initial_chat_height - 2,
      "chat should yield space to multiline activity"
    )

    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "in_progress",
        title = "short command",
      },
    }, { ui = { chat_width = 42 } })

    assert_equal(vim.api.nvim_buf_line_count(activity_buf), 1, "single-line activity should use one buffer line")
    assert_equal(vim.api.nvim_win_get_height(activity_win), 1, "activity window should shrink to one line")
    assert_equal(
      vim.api.nvim_win_get_height(chat_win),
      initial_chat_height,
      "chat should reclaim space after activity shrinks"
    )
  end)

  it("tool result output is collapsed and toggled", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 60, tool_results = "all" },
    }, function(_) end)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "printf lines",
        output = table.concat({ "one", "two", "three", "four", "five", "six" }, "\n") .. "\n",
        exitCode = 0,
      },
    }, { ui = { chat_width = 60, tool_results = "all" } })

    local chat_buf = vim.fn.bufnr("omniac")
    local collapsed = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(collapsed:match("Ran printf lines") ~= nil, "tool result should show command")
    assert_true(collapsed:match("one") ~= nil, "collapsed output should show first line")
    assert_true(collapsed:match("two") ~= nil, "collapsed output should show second line")
    assert_true(collapsed:match("five") ~= nil, "collapsed output should show penultimate line")
    assert_true(collapsed:match("six") ~= nil, "collapsed output should show last line")
    assert_true(collapsed:match("three") == nil, "collapsed output should hide middle lines")
    assert_true(collapsed:match("%+2 lines") ~= nil, "collapsed output should show hidden line count")

    feed("<C-t>")
    vim.wait(20)
    local expanded = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(expanded:match("three") ~= nil, "expanded output should show hidden line")
    assert_true(expanded:match("%-2 lines") ~= nil, "expanded output should show collapse hint")
  end)

  it("completed tool results return activity to working", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "completed",
        title = "run tests",
        exitCode = 0,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        title = "run tests",
        output = "ok\n",
        exitCode = 0,
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Completed execute: run tests") ~= nil, "completed tool activity should show briefly")

    vim.wait(700, function()
      activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
      return activity:match("Working") ~= nil
    end)

    assert_true(activity:match("Working") ~= nil, "completed tool result should return to working activity")
    assert_true(activity:match("Completed execute: run tests") == nil, "completed tool activity should not linger")
  end)

  it("failed tool results return activity to working", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "failed",
        title = "run tests",
        exitCode = 1,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "failed",
        title = "run tests",
        output = "nope\n",
        exitCode = 1,
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Failed execute: run tests") ~= nil, "failed tool activity should show briefly")

    vim.wait(700, function()
      activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
      return activity:match("Working") ~= nil
    end)

    assert_true(activity:match("Working") ~= nil, "failed tool result should return to working activity")
    assert_true(activity:match("Failed execute: run tests") == nil, "failed tool activity should not linger")
  end)

  it("assistant chunks clear completed tool activity", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "completed",
        title = "run tests",
        exitCode = 0,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "follow-up answer",
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "assistant chunk should restore working activity")
    assert_true(
      activity:match("Completed execute: run tests") == nil,
      "completed tool activity should clear on assistant chunk"
    )
  end)

  it("assistant chunks clear failed tool activity", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/tool_activity",
      params = {
        kind = "execute",
        status = "failed",
        title = "run tests",
        exitCode = 1,
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "follow-up answer",
      },
    }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "assistant chunk should restore working activity")
    assert_true(
      activity:match("Failed execute: run tests") == nil,
      "failed tool activity should clear on assistant chunk"
    )
  end)

  it("compact tool results hide noisy completed output", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = {
      agent = { cmd = { "codex-acp" } },
      ui = {
        chat_width = 60,
        tool_results = "compact",
        tool_result_max_lines = 4,
      },
    }

    ui.open(config, function(_) end)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        title = "call_hidden",
        output = "internal output\n",
        exitCode = 0,
      },
    }, config)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "printf lines",
        output = table.concat({ "one", "two", "three", "four", "five" }, "\n") .. "\n",
        exitCode = 0,
      },
    }, config)

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "printf ok",
        output = "ok\n",
        exitCode = 0,
      },
    }, config)

    local chat_buf = vim.fn.bufnr("omniac")
    local collapsed = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(collapsed:match("Ran call_hidden") == nil, "compact mode should hide opaque completed calls")
    assert_true(collapsed:match("Ran printf lines") == nil, "compact mode should hide long completed output")
    assert_true(collapsed:match("Ran printf ok") ~= nil, "compact mode should keep short named output")
  end)

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

  it("chat buffer uses markdown renderer when available", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    local render_calls = {}
    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function(ctx)
          table.insert(render_calls, ctx)
        end,
      }
    end

    local ui = require("omniac.ui")
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "```markdown\n| A | B |\n| - | - |\n| 1 | 2 |\n```\n\n```lua\nprint('x')\n```",
      },
    }, { ui = { chat_width = 48 } })
    ui.handle_notification({ method = "omniac/response_completed", params = {} }, { ui = { chat_width = 48 } })

    local chat_buf = vim.fn.bufnr("omniac")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_buf ~= -1, "chat buffer should exist")
    assert_true(chat_win ~= nil, "chat window should exist")
    assert_equal(vim.wo[chat_win].signcolumn, "no", "chat window should not use signcolumn for padding")
    assert_equal(vim.bo[chat_buf].filetype, "markdown", "chat buffer should use markdown filetype")
    assert_true(chat:match("```markdown") == nil, "markdown fences should be unwrapped before display")
    assert_true(chat:match("| A | B |") ~= nil, "markdown fence contents should remain visible")
    assert_true(chat:match("```lua") ~= nil, "non-markdown code fences should remain intact")
    assert_true(
      chat:match("^| A | B |\n") ~= nil or chat:match("\n| A | B |\n") ~= nil,
      "markdown table rows should be inserted without padding"
    )
    assert_true(chat:match("\n  | A | B |") == nil, "markdown table rows should not receive leading UI padding")
    assert_true(chat:match("| A | B |  \n") == nil, "markdown table rows should not receive trailing UI padding")
    assert_true(#render_calls > 0, "render-markdown should be called for chat rendering")
    assert_equal(render_calls[#render_calls].buf, chat_buf, "render-markdown should receive the chat buffer")
    assert_equal(render_calls[#render_calls].event, "OmniacRender", "render-markdown should receive an Omniac event")
    assert_equal(
      render_calls[#render_calls].config.pipe_table.style,
      "normal",
      "chat tables should use compact markdown rendering"
    )
    assert_equal(
      render_calls[#render_calls].config.pipe_table.border_virtual,
      true,
      "chat table borders should avoid consuming empty buffer lines"
    )

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("streaming response defers markdown rendering until complete", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    local render_calls = {}
    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function(ctx)
          table.insert(render_calls, ctx)
        end,
      }
    end

    local ui = require("omniac.ui")
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    local initial_calls = #render_calls

    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "| A | B |\n| - | - |\n| 1 | 2 |\n",
      },
    }, { ui = { chat_width = 48 } })
    assert_equal(#render_calls, initial_calls, "streaming chunks should not invoke markdown rendering")

    ui.handle_notification({ method = "omniac/response_completed", params = {} }, { ui = { chat_width = 48 } })
    assert_true(#render_calls > initial_calls, "completed responses should invoke markdown rendering")

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("streaming coalesces queued chunks into one chat render", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 48 } }

    ui.open(config, function(_) end)
    local chat_buf = vim.fn.bufnr("omniac")
    local render_count = 0
    vim.api.nvim_buf_attach(chat_buf, false, {
      on_lines = function()
        render_count = render_count + 1
      end,
    })

    ui.append_response_chunk("one ", config)
    ui.append_response_chunk("two ", config)
    ui.append_response_chunk("three", config)

    vim.wait(100, function()
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      return chat:match("one two three") ~= nil
    end)
    assert_equal(render_count, 1, "queued chunks should update the chat buffer once")
  end)

  it("streaming preserves chat view while another window is active", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 48 } }

    ui.open(config, function(_) end)
    ui.add_message(
      "Omniac",
      table.concat(
        vim.tbl_map(function(index)
          return "history line " .. index
        end, vim.fn.range(1, 40)),
        "\n"
      ),
      config
    )

    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_win ~= nil, "chat window should exist")

    vim.api.nvim_win_set_cursor(chat_win, { 5, 0 })
    vim.api.nvim_win_call(chat_win, function()
      vim.cmd("normal! zt")
    end)
    local before_view = vim.api.nvim_win_call(chat_win, vim.fn.winsaveview)
    assert_true(vim.api.nvim_get_current_win() ~= chat_win, "another Omniac window should remain active")

    ui.append_response_chunk("new streamed response", config)
    vim.wait(100, function()
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      return chat:match("new streamed response") ~= nil
    end)

    local after_cursor = vim.api.nvim_win_get_cursor(chat_win)
    local after_view = vim.api.nvim_win_call(chat_win, vim.fn.winsaveview)
    assert_equal(after_cursor[1], 5, "streaming should preserve an inactive chat cursor")
    assert_equal(after_view.topline, before_view.topline, "streaming should preserve an inactive chat view")
  end)

  it("streaming follows an active chat cursor on the last line", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 48 } }

    ui.open(config, function(_) end)
    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_win ~= nil, "chat window should exist")

    vim.api.nvim_set_current_win(chat_win)
    vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(chat_buf), 0 })
    ui.append_response_chunk(string.rep("streamed text ", 20), config)
    vim.wait(100, function()
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      return chat:match("streamed text") ~= nil
    end)

    assert_equal(
      vim.api.nvim_win_get_cursor(chat_win)[1],
      vim.api.nvim_buf_line_count(chat_buf),
      "active chat should follow new content from its previous last line"
    )
  end)

  it("streaming preserves an active visual selection away from the last line", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = { ui = { chat_width = 48 } }

    ui.open(config, function(_) end)
    ui.add_message(
      "Omniac",
      table.concat(
        vim.tbl_map(function(index)
          return "history line " .. index
        end, vim.fn.range(1, 40)),
        "\n"
      ),
      config
    )

    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_win ~= nil, "chat window should exist")

    vim.api.nvim_set_current_win(chat_win)
    vim.api.nvim_win_set_cursor(chat_win, { 5, 0 })
    vim.cmd("normal! v")
    assert_equal(vim.fn.mode(1), "v", "chat should be in visual mode")

    ui.append_response_chunk("new streamed response", config)
    vim.wait(100, function()
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      return chat:match("new streamed response") ~= nil
    end)

    assert_equal(vim.api.nvim_win_get_cursor(chat_win)[1], 5, "streaming should preserve the visual cursor")
    vim.cmd("normal! v")
  end)

  it("focus changes and notification floats do not relayout chat", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    local render_calls = 0
    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function()
          render_calls = render_calls + 1
        end,
      }
    end

    local ui = require("omniac.ui")
    ui.open({ ui = { chat_width = 48 } }, function(_) end)
    local before = render_calls

    vim.cmd("doautocmd FocusGained")
    vim.wait(20, function()
      return false
    end)
    assert_equal(render_calls, before, "FocusGained should not relayout chat")

    local float_buf = vim.api.nvim_create_buf(false, true)
    local float_win = vim.api.nvim_open_win(float_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 1,
      style = "minimal",
    })
    vim.api.nvim_win_close(float_win, true)
    vim.wait(20, function()
      return false
    end)
    assert_equal(render_calls, before, "closing a floating notification window should not relayout chat")

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("response stop reasons render only actionable UI", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    ui.handle_notification(
      { method = "omniac/response_chunk", params = { text = "short answer" } },
      { ui = { chat_width = 48 } }
    )
    ui.handle_notification(
      { method = "omniac/response_completed", params = { stopReason = "max_tokens" } },
      { ui = { chat_width = 48 } }
    )

    local chat_buf = vim.fn.bufnr("omniac")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(chat:match("short answer") ~= nil, "response text should render")
    assert_true(chat:match("Stopped: token limit") ~= nil, "token limit stop reason should render as footer")

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/response_completed", params = { stopReason = "cancelled" } },
      { ui = { chat_width = 48 } }
    )

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Turn cancelled%.") ~= nil, "cancelled stop reason should render as activity")

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/response_chunk", params = { text = "done" } },
      { ui = { chat_width = 48 } }
    )
    ui.handle_notification(
      { method = "omniac/response_completed", params = { stopReason = "end_turn" } },
      { ui = { chat_width = 48 } }
    )

    chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(chat:match("Stopped: end_turn") == nil, "normal end_turn should not render as chat noise")
  end)

  it("assistant prose keeps chat padding", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "plain assistant line",
      },
    }, { ui = { chat_width = 48 } })

    local chat_buf = vim.fn.bufnr("omniac")
    vim.wait(100, function()
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      return chat:match("plain assistant line") ~= nil
    end)
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(
      chat:match("^  plain assistant line%s+\n") ~= nil or chat:match("\n  plain assistant line%s+\n") ~= nil,
      "assistant prose should keep horizontal padding"
    )
  end)

  it("assistant prose wraps instead of ellipsizing", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "this assistant response is intentionally long enough to wrap across more than one visible chat line",
      },
    }, { ui = { chat_width = 48 } })

    local chat_buf = vim.fn.bufnr("omniac")
    vim.wait(100, function()
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      return chat:match("intentionally long enough") ~= nil
    end)
    local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    local prose_lines = 0
    local prose_text = {}
    for _, line in ipairs(lines) do
      if line:match("^  %S") and not line:match("^  [─]+%s*$") then
        prose_lines = prose_lines + 1
        table.insert(prose_text, line)
      end
    end

    assert_true(table.concat(prose_text, "\n"):match("…") == nil, "assistant prose should not be ellipsized")
    assert_true(prose_lines >= 2, "assistant prose should wrap across multiple padded lines")
  end)

  it("chat and input redraw after explicit omniac resize", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    local render_calls = {}
    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function(ctx)
          table.insert(render_calls, ctx)
        end,
      }
    end

    local ui = require("omniac.ui")
    vim.api.nvim_set_option_value("columns", 180, {})
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }, function(_) end)

    local chat_buf = vim.fn.bufnr("omniac")
    local input_buf = vim.fn.bufnr("omniac://input")
    local status_buf = vim.fn.bufnr("omniac://status")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_win ~= nil, "chat window should exist")

    ui.resize(100)
    vim.wait(50, function()
      local chat_line = vim.api.nvim_buf_get_lines(chat_buf, 0, 1, false)[1] or ""
      local input_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
      return vim.fn.strdisplaywidth(chat_line) == 100
        and vim.fn.strdisplaywidth(input_line) == 100
        and #render_calls >= 2
    end)

    local chat_line = vim.api.nvim_buf_get_lines(chat_buf, 0, 1, false)[1] or ""
    local input_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
    local status_line = vim.api.nvim_buf_get_lines(status_buf, 0, 1, false)[1] or ""
    assert_equal(vim.api.nvim_win_get_width(chat_win), 100, "user resize should keep the chat window width")
    assert_equal(vim.wo[chat_win].signcolumn, "no", "chat should not use signcolumn for padding")
    assert_equal(vim.fn.strdisplaywidth(chat_line), 100, "chat should redraw to the resized width")
    assert_equal(vim.fn.strdisplaywidth(input_line), 100, "input should redraw to the resized width")
    assert_equal(vim.fn.strdisplaywidth(status_line), 100, "status should redraw to the resized width")

    vim.cmd("vsplit")
    vim.cmd("enew")
    vim.cmd("close")
    vim.cmd("doautocmd WinResized")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }, function(_) end)
    assert_equal(vim.api.nvim_win_get_width(chat_win), 100, "reopening chat should preserve user resize width")

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("chat keeps its initial open width across external split churn", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    local ui = require("omniac.ui")
    vim.api.nvim_set_option_value("columns", 180, {})
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }, function(_) end)

    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_win ~= nil, "chat window should exist")

    local initial_width = vim.api.nvim_win_get_width(chat_win)
    vim.cmd("vsplit")
    vim.cmd("enew")
    vim.cmd("close")

    vim.wait(250, function()
      return vim.api.nvim_win_is_valid(chat_win) and vim.api.nvim_win_get_width(chat_win) == initial_width
    end)

    assert_equal(
      vim.api.nvim_win_get_width(chat_win),
      initial_width,
      "closing an external split should keep the initial chat window width"
    )

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("chat relayouts while error state is active", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    local ui = require("omniac.ui")
    vim.api.nvim_set_option_value("columns", 180, {})
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }, function(_) end)

    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_win ~= nil, "chat window should exist")

    local initial_height = vim.api.nvim_win_get_height(chat_win)
    ui.set_status("error", {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    })
    vim.cmd("split")
    vim.cmd("enew")
    vim.cmd("close")

    vim.wait(250, function()
      return vim.api.nvim_win_is_valid(chat_win) and vim.api.nvim_win_get_height(chat_win) == initial_height
    end)

    assert_equal(
      vim.api.nvim_win_get_height(chat_win),
      initial_height,
      "error-state relayout should restore the chat window height"
    )

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("chat yields vertical space to an external bottom split", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    local ui = require("omniac.ui")
    vim.api.nvim_set_option_value("columns", 180, {})
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }, function(_) end)

    local chat_buf = vim.fn.bufnr("omniac")
    local chat_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat_buf then
        chat_win = win
        break
      end
    end
    assert_true(chat_win ~= nil, "chat window should exist")

    local initial_height = vim.api.nvim_win_get_height(chat_win)
    vim.cmd("botright 6split")
    vim.cmd("enew")
    vim.cmd("wincmd J")
    local external_win = vim.api.nvim_get_current_win()
    vim.cmd("doautocmd WinResized")

    vim.wait(250, function()
      return vim.api.nvim_win_is_valid(chat_win) and vim.api.nvim_win_get_height(chat_win) < initial_height
    end)
    assert_true(
      vim.api.nvim_win_get_height(chat_win) < initial_height,
      "chat should yield height to an external bottom split"
    )
    assert_true(vim.api.nvim_win_get_height(external_win) >= 5, "external split should retain its requested height")

    vim.api.nvim_win_close(external_win, true)
    vim.wait(250, function()
      return vim.api.nvim_win_is_valid(chat_win) and vim.api.nvim_win_get_height(chat_win) == initial_height
    end)
    assert_equal(
      vim.api.nvim_win_get_height(chat_win),
      initial_height,
      "chat should reclaim height after the external split closes"
    )

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("completed assistant messages keep turn separators after reopen", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    local config = {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }

    ui.open(config, function(_) end)
    ui.add_message("Omniac", "first answer", config)
    ui.add_message("Omniac", "second answer", config)
    ui.open(config, function(_) end)

    local chat_buf = vim.fn.bufnr("omniac")
    local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    local separators = 0
    for _, line in ipairs(lines) do
      if line:match("^  [─]+%s*$") then
        separators = separators + 1
      end
    end

    assert_true(separators >= 2, "completed assistant messages should keep visible turn separators")
  end)

  it("user messages keep turn separators after reopen", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    local config = {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }

    ui.open(config, function(_) end)
    ui.add_message("You", "first prompt", config)
    ui.add_message("You", "second prompt", config)
    ui.open(config, function(_) end)

    local chat_buf = vim.fn.bufnr("omniac")
    local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    local separators = 0
    for _, line in ipairs(lines) do
      if line:match("^  [─]+%s*$") then
        separators = separators + 1
      end
    end

    assert_true(separators >= 2, "user messages should keep visible turn separators")
  end)

  it("omniac resize command resizes the side ui as one body", function()
    cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    package.loaded["render-markdown"] = nil

    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function(_) end,
      }
    end

    local omniac = require("omniac")
    vim.api.nvim_set_option_value("columns", 180, {})
    omniac.setup({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    })
    omniac.open_chat()

    vim.cmd("OmniacResize 100")

    local widths = {}
    for _, name in ipairs({ "omniac", "omniac://activity", "omniac://input", "omniac://status" }) do
      local buf = vim.fn.bufnr(name)
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          table.insert(widths, vim.api.nvim_win_get_width(win))
          break
        end
      end
    end

    assert_equal(#widths, 4, "all omniac side windows should be open")
    for _, actual in ipairs(widths) do
      assert_equal(actual, 100, "omniac side windows should share the requested width")
    end

    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("transport reconnect messages render as activity", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 62 },
    }, function(_) end)

    ui.handle_notification({
      method = "omniac/response_chunk",
      params = { text = "Reconnecting... 4/5\n" },
    }, { ui = { chat_width = 62 } })
    ui.handle_notification({
      method = "omniac/response_chunk",
      params = {
        text = "Warning: Falling back from WebSockets to HTTPS transport. stream disconnected before completion: Connection refused (os error 61)\n",
      },
    }, { ui = { chat_width = 62 } })

    local chat_buf = vim.fn.bufnr("omniac")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")

    assert_true(chat:match("Reconnecting") == nil, "reconnect messages should not be added to chat")
    assert_true(chat:match("Falling back from WebSockets") == nil, "transport warnings should not be added to chat")
    assert_true(activity:match("Falling back from WebSockets") ~= nil, "transport warning should render as activity")
  end)

  it("permission request shows JSON-RPC details in chat and selector", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.approval"] = nil
    package.loaded["omniac.permission_dialog"] = nil
    local ui = require("omniac.ui")
    local approval = require("omniac.approval")
    local dialog_text

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/response_chunk", params = { text = "before " } },
      { ui = { chat_width = 48 } }
    )

    local replied
    approval.review_acp_permission({
      sessionId = "019ebc08-548b-7033-bb21-96097389145c",
      toolCall = {
        kind = "execute",
        status = "pending",
        toolCallId = "call_NoA8PXYCbZ2V0zw4BmoF62T3",
        rawInput = {
          command = "stylua lua/omniac/clipboard.lua lua/omniac/backend/acp.lua lua/omniac/init.lua lua/omniac/ui.lua tests/headless.lua",
          cwd = "/Users/nolleh/Documents/workspace_github/omniac.nvim",
        },
        content = {
          {
            type = "content",
            content = {
              type = "text",
              text = "커밋 전에 변경된 Lua 파일 포맷을 확인/적용하도록 허용할까요?",
            },
          },
        },
      },
      options = {
        { optionId = "allow_once", name = "Allow Once" },
        { optionId = "allow_always", name = "Allow for Session" },
        { optionId = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, { ui = { chat_width = 48 } })

    vim.wait(50, function()
      return vim.fn.bufnr("omniac://permission") ~= -1
    end)
    local dialog_buf = vim.fn.bufnr("omniac://permission")
    local body_lines = vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false)
    dialog_text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    assert_equal(body_lines[#body_lines], "", "permission body should leave a blank line below cwd")
    feed("1")
    vim.wait(50, function()
      return replied ~= nil
    end)

    ui.handle_notification(
      { method = "omniac/response_chunk", params = { text = "after" } },
      { ui = { chat_width = 48 } }
    )
    ui.handle_notification({ method = "omniac/response_completed", params = {} }, { ui = { chat_width = 48 } })

    local chat_buf = vim.fn.bufnr("omniac")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local before_index = chat:find("before", 1, true)
    local permission_index = chat:find("Permission requested", 1, true)
    local after_index = chat:find("after", 1, true)
    assert_true(before_index ~= nil, "chat should include response before permission request")
    assert_true(permission_index ~= nil, "permission request should be inserted into chat")
    assert_true(after_index ~= nil, "chat should include response after permission request")
    assert_true(before_index < permission_index, "permission request should follow prior response text")
    assert_true(permission_index < after_index, "later response text should follow permission request")
    assert_true(chat:match("Permission requested") ~= nil, "permission request should be inserted into chat")
    assert_true(chat:match("```sh") ~= nil, "permission command should be rendered as shell code")
    assert_true(chat:match("stylua lua/omniac/clipboard.lua") ~= nil, "permission chat should show the command")
    assert_true(chat:match("커밋 전에 변경된 Lua 파일") ~= nil, "permission chat should show content text")
    assert_true(chat:match("Decision: Allow Once") ~= nil, "permission chat should show selected decision")
    assert_true(chat:match("cwd:") ~= nil, "permission chat should show cwd")
    assert_true(chat:match("Options:") == nil, "permission chat should leave options to the selector")
    assert_true(chat:match("Details:") == nil, "permission chat should not expose protocol-ish detail labels")
    assert_true(dialog_text:match("Permission requested: execute") ~= nil, "selector prompt should still be shown")
    assert_true(
      dialog_text:match("stylua lua/omniac/clipboard.lua") ~= nil,
      "selector should show the command to approve"
    )
    assert_true(
      dialog_text:match("커밋 전에 변경된 Lua 파일 포맷을 확인/적용하도록 허용할까요%?") ~= nil,
      "selector should show the request text"
    )
    assert_true(dialog_text:match("cwd:") ~= nil, "selector should show the working directory")
    assert_equal(replied.outcome.optionId, "allow_once", "permission reply should select the chosen option")

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Permission requested") == nil, "permission activity should clear after decision")
  end)

  it("permission selector leaves insert mode and stays read-only", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.permission_dialog"] = nil
    local dialog = require("omniac.permission_dialog")

    vim.cmd("startinsert")
    vim.wait(50, function()
      return vim.fn.mode():match("^i") ~= nil
    end)

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, { prompt = "Permission requested: execute" }, function(_) end)

    vim.wait(50, function()
      return not vim.fn.mode():match("^i")
    end)

    local dialog_buf = vim.fn.bufnr("omniac://permission")
    assert_true(dialog_buf ~= -1, "permission selector should open")
    assert_equal(vim.bo[dialog_buf].modifiable, false, "permission selector should not be modifiable")
    assert_equal(vim.bo[dialog_buf].readonly, true, "permission selector should be read-only")
    assert_true(not vim.fn.mode():match("^i"), "permission selector should not stay in insert mode")

    dialog.dismiss()
  end)

  it("permission selector has a bordered action area below the request", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.permission_dialog"] = nil
    local dialog = require("omniac.permission_dialog")

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, { prompt = "Permission requested: execute" }, function(_) end)

    local body_buf = vim.fn.bufnr("omniac://permission")
    local selector_buf = vim.fn.bufnr("omniac://permission-selector")
    local body_win = vim.fn.win_findbuf(body_buf)[1]
    local selector_win = vim.fn.win_findbuf(selector_buf)[1]
    local body_config = vim.api.nvim_win_get_config(body_win)
    local selector_config = vim.api.nvim_win_get_config(selector_win)
    local selector_lines = vim.api.nvim_buf_get_lines(selector_buf, 0, -1, false)
    local selected_hl = vim.api.nvim_get_hl(0, { name = "OmniacPermissionSelected" })

    assert_true(body_config.border ~= nil, "permission body should keep its outline")
    assert_equal(body_config.title_pos, "left", "permission title should use native left alignment")
    assert_true(
      selector_config.border ~= nil and selector_config.border ~= "none",
      "permission actions should have an outline"
    )
    assert_equal(selector_config.col, body_config.col, "permission actions should align with the card")
    assert_equal(
      selector_config.row,
      body_config.row + body_config.height + 3,
      "permission actions should sit below the request card"
    )
    assert_true(selector_lines[1]:match("^› 1  Allow Once") ~= nil, "selected permission action should use a cursor")
    assert_equal(selected_hl.fg, tonumber("11111b", 16), "selected permission action should use the session foreground")
    assert_equal(selected_hl.bg, tonumber("94e2d5", 16), "selected permission action should use the session background")
    assert_equal(selected_hl.bold, true, "selected permission action should match the bold session selection")

    dialog.dismiss()
  end)

  it("permission body wraps long commands and preserves source newlines", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.permission_dialog"] = nil
    local dialog = require("omniac.permission_dialog")
    local command = "python3 -c '" .. string.rep("print(1234567890);", 30) .. "'"

    dialog.open({ { optionId = "allow_once", name = "Allow Once" } }, {
      prompt = "Permission requested: execute",
      body = "Command:\n```sh\n" .. command .. "\nsecond line\n```",
    }, function(_) end)

    local body_buf = vim.fn.bufnr("omniac://permission")
    local body_win = vim.fn.win_findbuf(body_buf)[1]
    local lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
    assert_equal(lines[5], command, "the full command should remain in the buffer")
    assert_equal(lines[6], "second line", "source newlines should stay separate")
    assert_equal(vim.wo[body_win].wrap, true, "long command lines should wrap visually")
    assert_true(vim.api.nvim_win_get_width(body_win) >= 50, "request card should leave space for command text")
    feed("<C-d>")
    assert_equal(vim.fn.bufnr("omniac://permission"), body_buf, "scrolling details should keep the dialog open")

    dialog.dismiss()
  end)

  it("permission dialog uses markdown rendering for the body", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.permission_dialog"] = nil
    package.loaded["render-markdown"] = nil

    local render_calls = {}
    package.preload["render-markdown"] = function()
      return {
        initialized = true,
        render = function(ctx)
          table.insert(render_calls, ctx)
        end,
      }
    end

    local dialog = require("omniac.permission_dialog")

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, {
      prompt = "Permission requested: execute",
      body = table.concat({
        "Title: Markdown body",
        "",
        "```sh",
        "printf ok",
        "```",
        "",
        "| A | B |",
        "| - | - |",
        "| 1 | 2 |",
      }, "\n"),
    }, function(_) end)

    local dialog_buf = vim.fn.bufnr("omniac://permission")
    assert_true(dialog_buf ~= -1, "permission dialog should open")
    assert_equal(vim.bo[dialog_buf].filetype, "markdown", "permission dialog should use markdown filetype")
    assert_true(#render_calls > 0, "permission dialog should call render-markdown")
    assert_equal(render_calls[#render_calls].buf, dialog_buf, "render-markdown should receive the permission buffer")
    assert_equal(
      render_calls[#render_calls].event,
      "OmniacPermissionRender",
      "render-markdown should receive a permission render event"
    )

    vim.wait(50)
    local settled_calls = #render_calls

    feed("j")
    vim.wait(50)
    assert_equal(#render_calls, settled_calls, "moving the permission selection should not rerender the markdown body")

    local dialog_text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    assert_true(dialog_text:match("```sh") ~= nil, "permission body should keep markdown source")
    assert_true(dialog_text:match("| A | B |") ~= nil, "permission body should keep table markdown source")

    dialog.dismiss()
    package.preload["render-markdown"] = nil
    package.loaded["render-markdown"] = nil
  end)

  it("edit permission without diff falls back to selector", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.approval"] = nil
    package.loaded["omniac.permission_dialog"] = nil
    local ui = require("omniac.ui")
    local approval = require("omniac.approval")
    local dialog_text

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    local replied
    approval.review_acp_permission({
      sessionId = "sess_1",
      toolCall = {
        kind = "edit",
        status = "pending",
        toolCallId = "call_edit_without_diff",
        content = vim.NIL,
      },
      options = {
        { optionId = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, { ui = { chat_width = 48 } })

    vim.wait(1200, function()
      return vim.fn.bufnr("omniac://permission") ~= -1
    end)
    local dialog_buf = vim.fn.bufnr("omniac://permission")
    dialog_text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    feed("1")

    vim.wait(50, function()
      return replied ~= nil
    end)

    local chat_buf = vim.fn.bufnr("omniac")
    local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(dialog_text:match("Permission requested: edit") ~= nil, "edit fallback selector should stay compact")
    assert_true(chat:match("Decision: Allow Once") ~= nil, "edit fallback should record the selected decision")
    assert_equal(replied.outcome.optionId, "allow_once", "edit fallback should reply with selected option")
  end)

  it("late edit permission diff replaces fallback selector", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.approval"] = nil
    package.loaded["omniac.permission_dialog"] = nil
    local ui = require("omniac.ui")
    local approval = require("omniac.approval")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    local replied
    approval.review_acp_permission({
      sessionId = "sess_1",
      toolCall = {
        kind = "edit",
        status = "pending",
        toolCallId = "call_late_diff",
        content = vim.NIL,
      },
      options = {
        { optionId = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, { ui = { chat_width = 48 } })

    vim.wait(1200, function()
      return vim.fn.bufnr("omniac://permission") ~= -1
    end)
    assert_true(vim.fn.bufnr("omniac://permission") ~= -1, "fallback selector should open while waiting for diff")

    local opened = approval.attach_acp_permission_diff({
      toolCallId = "call_late_diff",
      path = "/tmp/omniac-late-new-file.md",
      oldText = vim.NIL,
      newText = "# Late\n",
    })

    assert_true(opened, "late permission diff should open a review")
    assert_equal(vim.fn.bufnr("omniac://permission"), -1, "late diff should close fallback selector")
    local current = vim.api.nvim_get_current_buf()
    local current_name = vim.api.nvim_buf_get_name(current)
    assert_true(
      current_name:match("Omniac permission: /tmp/omniac%-late%-new%-file%.md") ~= nil,
      "diff review should show the file path"
    )
    assert_equal(
      vim.api.nvim_buf_get_lines(current, 0, -1, false)[1],
      "# Late",
      "diff review should show proposed content"
    )

    vim.cmd("w")
    assert_true(replied ~= nil, "accepting late diff should reply")
    assert_equal(replied.outcome.optionId, "allow_once", "accepted late diff should use the allow option")
  end)

  it("edited diff approval rejects the original edit and captures adjusted text", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    local approval = require("omniac.approval")
    local replied
    local adjusted

    approval.review_acp_permission({
      sessionId = "sess_adjusted",
      toolCall = {
        kind = "edit",
        toolCallId = "call_adjusted",
        content = { { type = "diff", path = "/tmp/omniac-adjusted.txt", oldText = "old", newText = "proposed" } },
      },
      options = {
        { optionId = "allow_once", kind = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", kind = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, {}, function(item)
      adjusted = item
      return true
    end)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "user edit" })
    vim.cmd("w")

    assert_equal(replied.outcome.optionId, "reject_once", "adjusted approval should reject original proposal")
    assert_equal(adjusted.path, "/tmp/omniac-adjusted.txt", "adjustment should retain target path")
    assert_equal(adjusted.proposedText, "proposed", "adjustment should retain original proposal")
    assert_equal(adjusted.adjustedText, "user edit", "adjustment should capture final buffer contents")
    assert_equal(vim.fn.filereadable(adjusted.path), 0, "approval should not write the target file")
  end)

  it("diff edit followed by undo still uses the adjusted approval flow", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.approval"] = nil
    local approval = require("omniac.approval")
    local replied
    local adjusted

    approval.review_acp_permission({
      sessionId = "sess_undo",
      toolCall = {
        kind = "edit",
        toolCallId = "call_undo",
        content = { { type = "diff", path = "/tmp/omniac-undo.txt", oldText = "old", newText = "proposed" } },
      },
      options = {
        { optionId = "allow_once", kind = "allow_once", name = "Allow Once" },
        { optionId = "reject_once", kind = "reject_once", name = "Reject" },
      },
    }, function(result)
      replied = result
    end, {}, function(item)
      adjusted = item
      return true
    end)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "temporary" })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "proposed" })
    vim.cmd("w")

    assert_equal(replied.outcome.optionId, "reject_once", "any text edit should use the follow-up flow")
    assert_equal(adjusted.adjustedText, "proposed", "final text should be captured without comparing it")
  end)

  it("adjusted approval waits for turn completion before prompting", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    local original_message = ui.add_message
    ui.set_activity = function() end
    ui.add_message = function() end

    local prompts = {}
    local client = { session_id = "sess_followup", active_turn_id = 7 }
    client.prompt = function(self, text, _, callback)
      table.insert(prompts, text)
      self.active_turn_id = 8
      self.prompt_callback = callback
    end
    local followup = require("omniac.modified_approval").new(client, {}, function()
      return true
    end)
    assert_true(
      followup:queue({
        sessionId = "sess_followup",
        path = "/tmp/example.txt",
        proposedText = "proposed",
        adjustedText = "adjusted",
      }),
      "adjustment should queue during the active turn"
    )
    assert_true(
      followup:queue({
        sessionId = "sess_followup",
        path = "/tmp/second.txt",
        proposedText = "second proposal",
        adjustedText = "second adjustment",
      }),
      "another adjusted file should join the same turn"
    )
    assert_equal(#prompts, 0, "permission response must not start another prompt")

    followup:finish_turn({ sessionId = "sess_followup", turnId = 7, stopReason = "cancelled" })
    client.active_turn_id = nil
    vim.wait(100, function()
      return #prompts == 1
    end)
    assert_equal(#prompts, 1, "follow-up should start after a rejected edit ends the turn as cancelled")
    assert_true(prompts[1]:match("adjusted") ~= nil, "follow-up should carry adjusted content")
    assert_true(prompts[1]:match("second adjustment") ~= nil, "follow-up should carry every adjusted file")
    client.active_turn_id = nil
    client.prompt_callback(nil, {})

    ui.set_activity = original_activity
    ui.add_message = original_message
  end)

  it("auto-approves only the matching adjusted edit in its follow-up turn", function()
    cleanup_omniac_buffers()
    local path = "/private/tmp/omniac-followup-" .. tostring(vim.loop.hrtime()) .. ".txt"
    vim.fn.writefile({ "original" }, path)
    local client = { session_id = "sess_match", active_turn_id = 10 }
    client.prompt = function(self, _, _, callback)
      self.active_turn_id = 11
      self.prompt_callback = callback
    end
    local followup = require("omniac.modified_approval").new(client, {}, function()
      return true
    end)
    followup:queue({
      sessionId = "sess_match",
      path = path,
      proposedText = "proposal",
      adjustedText = "user edit\n",
    })
    followup:finish_turn({ sessionId = "sess_match", turnId = 10, stopReason = "cancelled" })
    client.active_turn_id = nil
    vim.wait(100, function()
      return client.active_turn_id == 11
    end)

    local approval = require("omniac.approval")
    local function request(new_text, old_text)
      return {
        sessionId = "sess_match",
        toolCall = {
          kind = "edit",
          toolCallId = "match-" .. tostring(vim.loop.hrtime()),
          content = { { type = "diff", path = path, oldText = old_text, newText = new_text } },
        },
        options = {
          { optionId = "allow_once", kind = "allow_once", name = "Allow Once" },
          { optionId = "cancel", kind = "reject_once", name = "Reject" },
        },
      }
    end
    local function review(params)
      local response
      approval.review_acp_permission(
        params,
        function(result)
          response = result
        end,
        {},
        nil,
        function(permission, payload)
          return followup:matches_followup(permission, payload)
        end
      )
      return response
    end

    local matched = review(request("user edit\n", "original\n"))
    assert_equal(matched.outcome.optionId, "allow_once", "exact adjusted text should be accepted without a diff")
    assert_equal(vim.fn.bufnr("Omniac permission: " .. path), -1, "automatic approval should not open a diff")

    local repeated = review(request("user edit\n", "original\n"))
    assert_equal(repeated, nil, "matching approval should be consumed after one use")
    vim.cmd("q")

    local changed = review(request("other edit\n", "original\n"))
    assert_equal(changed, nil, "different proposed content should require review")
    vim.cmd("q")

    vim.fn.writefile({ "changed elsewhere" }, path)
    local stale = review(request("user edit\n", "original\n"))
    assert_equal(stale, nil, "changed current content should require review")
    vim.cmd("q")

    client.active_turn_id = nil
    client.prompt_callback(nil, {})
    vim.fn.delete(path)
  end)

  it("adjusted approval queue is discarded when its connection closes", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    ui.set_activity = function() end

    local prompt_count = 0
    local client = { session_id = "sess_closed", active_turn_id = 3 }
    client.prompt = function()
      prompt_count = prompt_count + 1
    end
    local followup = require("omniac.modified_approval").new(client, {}, function()
      return true
    end)
    assert_true(
      followup:queue({
        sessionId = "sess_closed",
        path = "/tmp/example.txt",
        proposedText = "before",
        adjustedText = "after",
      }),
      "adjustment should queue before disconnect"
    )
    followup:finish_turn({ sessionId = "sess_closed", turnId = 3 })
    followup:close()
    client.active_turn_id = nil
    vim.wait(50)
    assert_equal(prompt_count, 0, "closed connection must not send a queued follow-up")

    ui.set_activity = original_activity
  end)

  it("adjusted approval reports a failed follow-up", function()
    local ui = require("omniac.ui")
    local original_activity = ui.set_activity
    local original_message = ui.add_message
    local messages = {}
    ui.set_activity = function() end
    ui.add_message = function(_, message)
      table.insert(messages, message)
    end

    local client = { session_id = "sess_error", active_turn_id = 4 }
    client.prompt = function(self, _, _, callback)
      self.active_turn_id = 5
      self.prompt_callback = callback
    end
    local followup = require("omniac.modified_approval").new(client, {}, function()
      return true
    end)
    followup:queue({
      sessionId = "sess_error",
      path = "/tmp/example.txt",
      proposedText = "before",
      adjustedText = "after",
    })
    followup:finish_turn({ sessionId = "sess_error", turnId = 4 })
    client.active_turn_id = nil
    vim.wait(100, function()
      return client.prompt_callback ~= nil
    end)
    client.active_turn_id = nil
    client.prompt_callback(nil, { stopReason = "error" })
    assert_true(messages[1]:match("follow%-up failed") ~= nil, "failed follow-up should be visible")

    ui.set_activity = original_activity
    ui.add_message = original_message
  end)

  it("permission dialog ignores escape without cancelling", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.permission_dialog"] = nil
    local dialog = require("omniac.permission_dialog")
    local choice = "unset"

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
      { optionId = "reject_once", name = "Reject" },
    }, {
      prompt = "Permission requested: execute",
    }, function(selected)
      choice = selected
    end)

    feed("<Esc><Esc>")
    vim.wait(50)

    assert_equal(choice, "unset", "escape should not choose or cancel permission")
    assert_true(vim.fn.bufnr("omniac://permission") ~= -1, "permission dialog should remain open after escape")

    feed("q")
    vim.wait(50, function()
      return choice ~= "unset"
    end)
    assert_equal(choice.optionId, "reject_once", "q should explicitly reject permission")
  end)

  it("permission dialog replaces an existing dialog", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.permission_dialog"] = nil
    local dialog = require("omniac.permission_dialog")

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
    }, {
      prompt = "Permission requested: first",
    }, function() end)

    dialog.open({
      { optionId = "allow_once", name = "Allow Once" },
    }, {
      prompt = "Permission requested: second",
    }, function() end)

    local dialog_buf = vim.fn.bufnr("omniac://permission")
    local text = table.concat(vim.api.nvim_buf_get_lines(dialog_buf, 0, -1, false), "\n")
    assert_true(text:match("second") ~= nil, "second permission dialog should replace the first")
    assert_true(text:match("first") == nil, "stale permission dialog content should be removed")

    feed("q")
  end)

  it("status shows plan and elevated access without redundant idle labels", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({
      method = "omniac/session_config_update",
      params = {
        configOptions = {
          { id = "mode", currentValue = "agent-full-access" },
          { id = "collaboration_mode", currentValue = "plan" },
        },
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    })

    local status_buf = vim.fn.bufnr("omniac://status")
    local line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    assert_true(line:find("Full access", 1, true) ~= nil, "elevated access should be visible")
    assert_true(line:find("Plan", 1, true) ~= nil, "plan mode should be visible")
    assert_true(line:find("Omniac", 1, true) == nil, "plugin name should not take status space")
    assert_true(line:find("ready", 1, true) == nil, "idle state should not take status space")
  end)

  it("status renders the current ACP session model", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({
      method = "omniac/session_model_update",
      params = {
        currentModelId = "gpt-5-mini",
        currentModelName = "GPT-5 Mini",
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    })

    local status_buf = vim.fn.bufnr("omniac://status")
    local line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    ui.handle_notification({
      method = "omniac/session_config_update",
      params = { configOptions = { { id = "reasoning_effort", currentValue = "medium" } } },
    }, {})
    line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    assert_true(line:find("GPT-5 Mini · Medium", 1, true) ~= nil, "model and effort should share a capsule")
  end)

  it("status renders ACP context usage as a percentage", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    }, function() end)

    ui.handle_notification({
      method = "omniac/session_model_update",
      params = {
        currentModelId = "gpt-5-mini",
        currentModelName = "GPT-5 Mini",
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    })
    ui.handle_notification({
      method = "omniac/usage_update",
      params = {
        used = 75000,
        size = 100000,
      },
    }, {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 58 },
    })

    local status_buf = vim.fn.bufnr("omniac://status")
    local line = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    local model_start = line:find("GPT-5 Mini", 1, true)
    local usage_start = line:find("ctx 75%", 1, true)
    local usage_hl = vim.api.nvim_get_hl(0, { name = "OmniacStatusUsage" })
    assert_true(line:match("ctx 75%%") ~= nil, "status should include context-window usage")
    assert_true(model_start < usage_start, "context usage should render after the model")
    assert_equal(usage_hl.bg, tonumber("89b4fa", 16), "context usage should use its own capsule color")
  end)

  it("ACP protocol file logs follow debug option", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local base = "/private/tmp/omniac-acp-log-test-" .. tostring(vim.loop.hrtime())
    local off_dir = base .. "-off"
    local on_dir = base .. "-on"

    local off_client = acp.new({
      debug = false,
      logs = { dir = off_dir },
    })
    off_client:_debug("request", { method = "session/new", params = {} })
    local off_logs = vim.fn.globpath(off_dir, "acp-*.jsonl", false, true)
    assert_equal(#off_logs, 0, "debug=false should not write ACP protocol files")

    local on_client = acp.new({
      debug = true,
      logs = { dir = on_dir },
    })
    on_client:_debug("request", { method = "session/new", params = {} })
    on_client:_debug("notification", {
      method = "session/update",
      params = { update = { sessionUpdate = "agent_message_chunk", content = "hello" } },
    })
    vim.wait(100, function()
      local paths = vim.fn.globpath(on_dir, "acp-*.jsonl", false, true)
      return #paths == 1 and #vim.fn.readfile(paths[1]) == 2
    end)
    local on_logs = vim.fn.globpath(on_dir, "acp-*.jsonl", false, true)
    assert_equal(#on_logs, 1, "debug=true should write ACP protocol files")
    assert_equal(#vim.fn.readfile(on_logs[1]), 2, "queued protocol events should flush together without loss")

    pcall(vim.fn.delete, off_dir, "rf")
    pcall(vim.fn.delete, on_dir, "rf")
  end)

  it("ACP close marks the subprocess exit as intentional", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local transport_closed = false

    client.running = true
    client.transport = {
      close = function()
        transport_closed = true
      end,
    }

    client:close()

    assert_equal(client.closing, true, "close should mark the following exit as intentional")
    assert_equal(transport_closed, true, "close should stop the ACP transport")
  end)

  it("ACP mode config options cycle with set_config_option", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requests = {}
    local updates = {}

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        table.insert(requests, {
          method = method,
          params = params,
        })
        callback(nil, {
          configOptions = {
            {
              id = "mode",
              name = "Session Mode",
              category = "mode",
              type = "select",
              currentValue = params.value,
              options = {
                { value = "plan", name = "Plan" },
                { value = "agent", name = "Agent" },
              },
            },
          },
        })
      end,
    }
    client:on_notification(function(message)
      if message.method == "omniac/session_mode_update" then
        table.insert(updates, message.params)
      end
    end)

    client:_apply_session_state({
      configOptions = {
        {
          id = "mode",
          name = "Session Mode",
          category = "mode",
          type = "select",
          currentValue = "plan",
          options = {
            { value = "plan", name = "Plan" },
            { value = "agent", name = "Agent" },
          },
        },
      },
    })
    client:cycle_session_mode(function(err)
      assert_equal(err, nil, "cycling config-backed mode should succeed")
    end)

    assert_equal(requests[1].method, "session/set_config_option", "config-backed modes should use set_config_option")
    assert_equal(requests[1].params.configId, "mode", "request should target the mode config option")
    assert_equal(requests[1].params.value, "agent", "cycle should select the next mode")
    vim.wait(50, function()
      return #updates > 0 and updates[#updates].currentModeName == "Agent"
    end)
    assert_equal(updates[#updates].currentModeName, "Agent", "mode update should expose the selected mode name")
  end)

  it("ACP model config options change with set_config_option", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local request
    local updates = {}

    client:on_notification(function(message)
      if message.method == "omniac/session_model_update" then
        table.insert(updates, message.params)
      end
    end)

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        request = { method = method, params = params }
        callback(nil, {
          configOptions = {
            {
              id = "model",
              category = "model",
              type = "select",
              currentValue = params.value,
              options = {
                { value = "gpt-5", name = "GPT-5" },
                { value = "gpt-5-mini", name = "GPT-5 Mini" },
              },
            },
          },
        })
      end,
    }
    client:_apply_session_state({
      configOptions = {
        {
          id = "model",
          category = "model",
          type = "select",
          currentValue = "gpt-5",
          options = {
            { value = "gpt-5", name = "GPT-5" },
            { value = "gpt-5-mini", name = "GPT-5 Mini" },
          },
        },
      },
    })

    vim.wait(50, function()
      return #updates > 0
    end)
    assert_equal(client:get_session_model().currentModelId, "gpt-5", "model state should expose the current model")
    assert_equal(#client:get_session_model().availableModels, 2, "model state should expose selectable models")
    assert_equal(updates[#updates].currentModelName, "GPT-5", "model update should expose the selected model name")

    local selected
    client:set_session_model("GPT-5 Mini", function(err, _, model_id)
      assert_equal(err, nil, "setting an advertised model should succeed")
      selected = model_id
    end)

    vim.wait(50, function()
      return #updates > 1
    end)
    assert_equal(request.method, "session/set_config_option", "model changes should use set_config_option")
    assert_equal(request.params.configId, "model", "request should target the model config option")
    assert_equal(request.params.value, "gpt-5-mini", "model names should resolve to their option value")
    assert_equal(selected, "gpt-5-mini", "callback should expose the selected model id")
    assert_equal(client:get_session_model().currentModelId, "gpt-5-mini", "selected model should update local state")
    assert_equal(updates[#updates].currentModelName, "GPT-5 Mini", "model update should follow model changes")
  end)

  it("ACP permission-like config modes are ignored", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local updates = {}

    client:on_notification(function(message)
      if message.method == "omniac/session_mode_update" then
        table.insert(updates, message.params)
      end
    end)
    client:_apply_session_state({
      configOptions = {
        {
          id = "mode",
          name = "Mode",
          category = "mode",
          type = "select",
          currentValue = "agent",
          options = {
            { value = "agent", name = "Agent" },
            { value = "full-access", name = "Full Access" },
            { value = "read-only", name = "Read Only" },
          },
        },
      },
    })

    vim.wait(20)
    assert_equal(#updates, 0, "permission-like modes should not be treated as planning modes")
  end)

  it("ACP legacy planning modes cycle with set_mode", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local request

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        request = {
          method = method,
          params = params,
        }
        callback(nil, {})
      end,
    }
    client:_apply_session_state({
      modes = {
        currentModeId = "plan",
        availableModes = {
          { id = "plan", name = "Plan" },
          { id = "agent", name = "Agent" },
        },
      },
    })
    client:cycle_session_mode(function(err)
      assert_equal(err, nil, "cycling legacy modes should succeed")
    end)

    assert_equal(request.method, "session/set_mode", "legacy modes should use set_mode")
    assert_equal(request.params.modeId, "agent", "cycle should select the next legacy mode")
  end)

  it("ACP cancel sends session cancel notification", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      notify = function(_, method, params)
        notification = {
          method = method,
          params = params,
        }
      end,
    }

    client:cancel(function(err)
      assert_equal(err, nil, "cancel should succeed")
    end)

    assert_equal(notification.method, "session/cancel", "cancel should use the ACP notification")
    assert_equal(notification.params.sessionId, "sess_1", "cancel should target the active session")
  end)

  it("ACP completed tool call emits tool result output", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client:on_notification(function(message)
      if message.method == "omniac/tool_result" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call_update",
          kind = "execute",
          status = "completed",
          title = "Check file",
          toolCallId = "call_tool_result",
          rawInput = {
            command = "test -f foo && echo exist || echo not exist",
            cwd = "/tmp",
          },
          rawOutput = {
            output = "exist\n",
            exit_code = 0,
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "completed tool call should emit tool_result")
    assert_equal(
      notification.params.command,
      "test -f foo && echo exist || echo not exist",
      "tool result should keep command"
    )
    assert_equal(notification.params.output, "exist\n", "tool result should keep output")
    assert_equal(notification.params.exitCode, 0, "tool result should keep exit code")
  end)

  it("ACP usage updates expose context-window consumption", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client.session_id = "sess_1"
    client:on_notification(function(message)
      if message.method == "omniac/usage_update" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "usage_update",
          used = 90000,
          size = 100000,
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "usage update should be emitted")
    assert_equal(notification.params.sessionId, "sess_1", "usage update should keep the session id")
    assert_equal(notification.params.used, 90000, "usage update should keep used tokens")
    assert_equal(notification.params.size, 100000, "usage update should keep context size")
  end)

  it("ACP prompt sends image content blocks when advertised", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local request

    client.session_id = "sess_1"
    client.running = true
    client.agent_capabilities = {
      promptCapabilities = {
        image = true,
      },
    }
    client.transport = {
      request = function(_, method, params, callback)
        request = {
          method = method,
          params = params,
        }
        callback(nil, {})
      end,
    }

    client:prompt("look", {
      prompt = {
        { type = "text", text = "look" },
        { type = "image", mimeType = "image/png", data = "aW1n" },
      },
    }, function(err)
      assert_equal(err, nil, "image prompt should be accepted when advertised")
    end)

    assert_equal(request.method, "session/prompt", "image prompts should use session/prompt")
    assert_equal(request.params.prompt[2].type, "image", "image content block should be preserved")
    assert_equal(request.params.prompt[2].data, "aW1n", "image data should be preserved")
  end)

  it("ACP prompt response emits stop reason", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local completed

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, _, callback)
        assert_equal(method, "session/prompt", "prompt should use session/prompt")
        client:_handle_notification({
          method = "session/update",
          params = {
            update = {
              sessionUpdate = "agent_message_chunk",
              content = {
                {
                  type = "text",
                  text = "hello",
                },
              },
            },
          },
        })
        client:_handle_notification({
          method = "session/update",
          params = {
            update = {
              sessionUpdate = "agent_message_chunk",
              content = {
                {
                  type = "text",
                  text = " world",
                },
              },
            },
          },
        })
        assert_equal(#client.response_chunks, 2, "streamed response chunks should accumulate without string copying")
        callback(nil, {
          stopReason = "max_tokens",
        })
      end,
    }
    client:on_notification(function(message)
      if message.method == "omniac/response_completed" then
        completed = message
      end
    end)

    client:prompt("hello")

    vim.wait(50, function()
      return completed ~= nil
    end)

    assert_true(completed ~= nil, "streamed prompt should emit response_completed")
    assert_equal(completed.params.stopReason, "max_tokens", "completion event should include stop reason")
    assert_equal(client.last_stop_reason, "max_tokens", "client should remember last stop reason")
  end)

  it("ACP replay chunks do not accumulate as an active response", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "agent_message_chunk",
          content = { { type = "text", text = string.rep("history", 1000) } },
        },
      },
    })

    assert_equal(#client.response_chunks, 0, "session replay should not retain history in the live response buffer")
  end)

  it("ACP empty prompt result still emits response_completed", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local completed

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function(_, method, _, callback)
        assert_equal(method, "session/prompt", "prompt should use session/prompt")
        client:_handle_notification({
          method = "session/update",
          params = {
            update = {
              sessionUpdate = "tool_call_update",
              kind = "execute",
              status = "failed",
              title = "Run tests",
              toolCallId = "call_failed_test",
              rawOutput = {
                output = "1 test failed\n",
                exit_code = 1,
              },
            },
          },
        })
        callback(nil, {
          stopReason = "end_turn",
        })
      end,
    }
    client:on_notification(function(message)
      if message.method == "omniac/response_completed" then
        completed = message
      end
    end)

    client:prompt("run tests")

    vim.wait(50, function()
      return completed ~= nil
    end)

    assert_true(completed ~= nil, "empty prompt result should still emit response_completed")
    assert_equal(completed.params.stopReason, "end_turn", "completion should keep stop reason")
  end)

  it("ACP edit diff emits permission diff for new files", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client:on_notification(function(message)
      if message.method == "omniac/permission_diff" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          title = "Editing files",
          toolCallId = "call_new_file",
          content = {
            {
              type = "diff",
              _meta = { kind = "update" },
              path = "/private/tmp/omniac-new-file.md",
              oldText = vim.NIL,
              newText = "# New\n",
            },
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "new file edits should emit permission_diff")
    assert_equal(notification.params.toolCallId, "call_new_file", "permission diff should keep the tool call id")
    assert_equal(notification.params.path, "/private/tmp/omniac-new-file.md", "permission diff should keep the path")
    assert_equal(notification.params.oldText, "", "new file oldText should be normalized to empty text")
    assert_equal(notification.params.newText, "# New\n", "permission diff should keep the proposed content")
  end)

  it("ACP edit add emits permission diff for created files", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client:on_notification(function(message)
      if message.method == "omniac/permission_diff" then
        notification = message
      end
    end)

    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          title = "Editing files",
          toolCallId = "call_added_file",
          content = {
            {
              type = "diff",
              _meta = { kind = "add" },
              path = "/private/tmp/omniac-added-file.md",
              oldText = vim.NIL,
              newText = "# Added\n",
            },
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)

    assert_true(notification ~= nil, "created file edits should emit permission_diff")
    assert_equal(notification.params.toolCallId, "call_added_file", "created file diff should keep tool call id")
    assert_equal(notification.params.path, "/private/tmp/omniac-added-file.md", "created file diff should keep path")
    assert_equal(notification.params.oldText, "", "created file oldText should be normalized to empty text")
    assert_equal(notification.params.newText, "# Added\n", "created file diff should keep new text")
  end)

  it("ACP completed edits keep the turn that started the tool call", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification

    client.session_id = "sess_1"
    client.active_turn_id = 7
    client:on_notification(function(message)
      if message.method == "omniac/file_update" then
        notification = message
      end
    end)
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          toolCallId = "call_turn_7",
        },
      },
    })

    client.active_turn_id = 8
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call_update",
          kind = "edit",
          status = "completed",
          toolCallId = "call_turn_7",
          content = {
            {
              type = "diff",
              path = "/tmp/turn-7.lua",
              oldText = "old\n",
              newText = "new\n",
            },
          },
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)
    assert_true(notification ~= nil, "completed edit should emit a file update")
    assert_equal(notification.params.sessionId, "sess_1", "file update should include its session")
    assert_equal(notification.params.turnId, 7, "file update should retain the originating turn")
  end)

  it("ACP completed edits retain earlier diffs when completion omits content", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local notification
    local path = "/private/tmp/omniac-edit-snapshot-" .. tostring(vim.loop.hrtime()) .. ".txt"
    vim.fn.writefile({ "before", "rest" }, path)

    client.session_id = "sess_1"
    client.active_turn_id = 3
    client:on_notification(function(message)
      if message.method == "omniac/file_update" then
        notification = message
      end
    end)
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call",
          kind = "edit",
          status = "in_progress",
          toolCallId = "call_snapshot",
          content = {
            {
              type = "diff",
              path = path,
              oldText = "before",
              newText = "after",
            },
          },
        },
      },
    })

    vim.fn.writefile({ "after", "rest" }, path)
    client:_handle_notification({
      method = "session/update",
      params = {
        update = {
          sessionUpdate = "tool_call_update",
          status = "completed",
          toolCallId = "call_snapshot",
        },
      },
    })

    vim.wait(50, function()
      return notification ~= nil
    end)
    pcall(vim.fn.delete, path)

    assert_true(notification ~= nil, "content-less completion should emit the cached file update")
    assert_equal(notification.params.turnId, 3, "cached file update should keep its originating turn")
    assert_equal(notification.params.oldText, "before\nrest\n", "file update should preserve the full baseline")
    assert_equal(notification.params.newText, "after\nrest\n", "file update should read the full completed file")
  end)

  it("ACP prompt rejects image content blocks without capability", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requested = false
    local received_err

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function()
        requested = true
      end,
    }

    client:prompt("look", {
      prompt = {
        { type = "text", text = "look" },
        { type = "image", mimeType = "image/png", data = "aW1n" },
      },
    }, function(err)
      received_err = err
    end)

    assert_equal(requested, false, "unsupported image prompt should not call transport")
    assert_true(received_err and received_err.message:match("image prompts"), "unsupported image prompt should error")
  end)

  it("ACP prompt rejects embedded references without capability", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requested = false
    local received_err

    client.session_id = "sess_1"
    client.running = true
    client.transport = {
      request = function()
        requested = true
      end,
    }

    client:prompt("explain", {
      prompt = {
        { type = "text", text = "explain" },
        {
          type = "resource",
          resource = {
            uri = "file:///tmp/example.lua#L1-L2",
            mimeType = "text/plain",
            text = "local example = true",
          },
        },
      },
    }, function(err)
      received_err = err
    end)

    assert_equal(requested, false, "unsupported embedded context should not call transport")
    assert_true(received_err and received_err.message:match("embedded context"), "unsupported resource should error")
  end)

  it("ACP list sessions requests even without advertised capability", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({
      agent = {
        cwd = "/tmp/project",
      },
    })
    local request
    local listed

    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        request = {
          method = method,
          params = params,
        }
        callback(nil, {
          sessions = {
            { sessionId = "sess_1", title = "One" },
          },
        })
      end,
    }

    client:list_sessions(function(err, sessions)
      assert_equal(err, nil, "list_sessions should not fail before trying request")
      listed = sessions
    end)

    assert_equal(request.method, "session/list", "list_sessions should optimistically request session/list")
    assert_equal(request.params.cwd, "/tmp/project", "session/list should include the configured cwd")
    assert_equal(listed[1].sessionId, "sess_1", "session/list results should be returned")
  end)

  it("ACP list sessions returns the first page without blocking on pagination", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local requests = {}
    local listed

    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        table.insert(requests, {
          method = method,
          params = params,
        })
        callback(nil, {
          sessions = {
            { sessionId = "sess_1" },
          },
          nextCursor = "cursor_2",
        })
      end,
    }

    client:list_sessions(function(err, sessions)
      assert_equal(err, nil, "list_sessions should return the first page")
      listed = sessions
    end)

    assert_equal(#requests, 1, "session selection should not wait for later pages")
    assert_equal(requests[1].params.cursor, nil, "session selection should request the latest page")
    assert_equal(#listed, 1, "sessions from the first page should be returned")
    assert_equal(listed[1].sessionId, "sess_1", "the recent session should be included")
  end)

  it("ACP select session falls back when list request fails", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local selector_opts
    local client = acp.new({
      agent = {
        session = {
          action = "select",
        },
      },
      session_selector = function(sessions, opts, callback)
        selector_opts = opts
        callback({ action = "new" })
      end,
    })
    local methods = {}

    client.running = true
    client.transport = {
      request = function(_, method, params, callback)
        table.insert(methods, method)
        if method == "session/list" then
          callback({ message = "not supported" }, nil)
        elseif method == "session/new" then
          callback(nil, { sessionId = "new_session" })
        else
          callback(nil, {})
        end
      end,
    }

    client:_setup_session(function(err, result, method)
      assert_equal(err, nil, "select fallback should continue with chosen new session")
      assert_equal(method, "session/new", "fallback selection should create a new session")
    end)

    assert_equal(methods[1], "session/list", "select setup should try session/list first")
    assert_equal(selector_opts.list_supported, false, "selector should know list failed")
    assert_true(selector_opts.message:match("not supported") ~= nil, "selector should receive the list error message")
  end)

  it("ACP mode state can be nested in session result", function()
    package.loaded["omniac.backend.acp"] = nil
    local acp = require("omniac.backend.acp")
    local client = acp.new({})
    local updates = {}

    client:on_notification(function(message)
      if message.method == "omniac/session_mode_update" then
        table.insert(updates, message.params)
      end
    end)
    client:_apply_session_state({
      session = {
        modes = {
          currentModeId = "plan",
          availableModes = {
            { id = "plan", name = "Plan" },
            { id = "auto", name = "Auto" },
          },
        },
      },
    })

    vim.wait(50, function()
      return #updates > 0 and updates[#updates].currentModeName == "Plan"
    end)
    assert_equal(updates[#updates].currentModeName, "Plan", "nested session mode should be parsed")
  end)

  it("ACP fs/read_text_file prefers unsaved buffer content", function()
    package.loaded["omniac.filesystem"] = nil
    local filesystem = require("omniac.filesystem")
    local path = "/private/tmp/omniac-fs-read-" .. tostring(vim.loop.now()) .. ".txt"
    vim.fn.writefile({ "disk" }, path)

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "buffer", "changed" })
    vim.bo[buf].modified = true

    local result, err = filesystem.handle_request("fs/read_text_file", {
      sessionId = "session",
      path = path,
      line = 2,
      limit = 1,
    })

    assert_equal(err, nil, "read_text_file should not return an error")
    assert_equal(result.content, "changed\n", "read_text_file should read from the loaded buffer")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("ACP fs/write_text_file writes disk and updates loaded buffer", function()
    package.loaded["omniac.filesystem"] = nil
    local filesystem = require("omniac.filesystem")
    local path = "/private/tmp/omniac-fs-write-" .. tostring(vim.loop.now()) .. ".txt"
    vim.fn.writefile({ "old" }, path)

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "old" })
    vim.bo[buf].modified = true

    local result, err = filesystem.handle_request("fs/write_text_file", {
      sessionId = "session",
      path = path,
      content = "new\nvalue\n",
    })

    assert_equal(err, nil, "write_text_file should not return an error")
    assert_equal(result, vim.NIL, "write_text_file should return JSON null")
    assert_equal(table.concat(vim.fn.readfile(path), "\n"), "new\nvalue", "file should be written to disk")
    assert_equal(
      table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
      "new\nvalue",
      "loaded buffer should be updated"
    )
    assert_equal(vim.bo[buf].modified, false, "loaded buffer should be marked unmodified after write")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("slash input opens command suggestions below chat", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.set_available_commands({
      { name = "test", description = "Run project tests" },
      { name = "plan", description = "Create a plan" },
    })

    feed("i/<Esc>")
    vim.cmd("redraw")

    local command_buf
    local command_win
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
        command_buf = buf
        break
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if command_buf and vim.api.nvim_win_get_buf(win) == command_buf then
        command_win = win
        break
      end
    end

    assert_true(command_buf ~= nil, "commands buffer should be created")
    assert_true(command_win ~= nil, "commands window should be visible")
    assert_true(vim.api.nvim_win_get_height(command_win) <= 5, "commands window should show up to five rows")

    local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
    assert_true(lines:match("/exit") ~= nil, "local exit command should be listed")
    assert_true(lines:match("/changes") ~= nil, "local changes command should be listed")
    assert_true(lines:match("/model") ~= nil, "local model command should be listed")
    assert_true(lines:match("/resume") ~= nil, "local resume command should be listed")
    assert_true(lines:match("/plan") ~= nil, "agent command should be listed")
    assert_true(lines:match("@README") == nil, "slash suggestions should not include file mentions")

    feed("a<BS>hello<Esc>")
    vim.cmd("redraw")

    assert_equal(vim.api.nvim_win_is_valid(command_win), false, "commands window should close for non-slash input")
  end)

  it("slash command suggestions tolerate null input metadata", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.set_available_commands({
      { name = "compact", description = vim.NIL, input = vim.NIL },
    })

    feed("i/com<Esc>")
    vim.cmd("redraw")

    local command_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
        command_buf = buf
        break
      end
    end

    assert_true(command_buf ~= nil, "commands buffer should be available")
    local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
    assert_true(lines:match("/compact") ~= nil, "command with null metadata should be listed")
  end)

  it("dollar input opens agent skill suggestions", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.set_available_commands({
      { name = "skills", description = "List skills" },
      { name = "$imagegen", description = "Generate images" },
      { name = "$openai-docs", description = "OpenAI docs" },
    })

    feed("i$im<Esc>")
    vim.cmd("redraw")

    local command_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
        command_buf = buf
        break
      end
    end

    assert_true(command_buf ~= nil, "skill suggestions should use the commands buffer")
    local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
    assert_true(lines:match("%$imagegen") ~= nil, "dollar-prefixed skill should be listed")
    assert_true(lines:match("/skills") == nil, "dollar suggestions should not include slash commands")
  end)

  it("at input opens file mention suggestions", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    feed("i@READ<Esc>")
    vim.cmd("redraw")

    local command_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == "omniac://commands" then
        command_buf = buf
        break
      end
    end

    assert_true(command_buf ~= nil, "mentions should reuse the suggestions buffer")
    local lines = table.concat(vim.api.nvim_buf_get_lines(command_buf, 0, -1, false), "\n")
    assert_true(lines:match("@README.md") ~= nil, "file mention suggestions should use @")
    assert_true(lines:match("/resume") == nil, "mention suggestions should not include slash commands")
  end)

  it("enter completes best slash command candidate", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      submitted = text
    end)

    feed("i/res<CR>")
    vim.cmd("redraw")

    assert_equal(submitted, "/resume", "enter should complete the best slash command candidate")
  end)

  it("visual range command attaches an ACP reference to the next prompt", function()
    cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.selection"] = nil
    for _, name in ipairs({
      "Omniac",
      "OmniacConnect",
      "OmniacDisconnect",
      "OmniacExit",
      "OmniacSession",
      "OmniacSessionNew",
      "OmniacSessionLoad",
      "OmniacSessionResume",
      "OmniacAsk",
      "OmniacResize",
      "OmniacDebug",
      "OmniacAskFiles",
      "OmniacReference",
      "OmniacReferenceBuffer",
      "OmniacTreeAdd",
      "OmniacChanges",
      "OmniacDiff",
      "OmniacDiffAccept",
      "OmniacDiffDeny",
    }) do
      pcall(vim.api.nvim_del_user_command, name)
    end

    local omniac = require("omniac")
    omniac.setup({
      agent = { cmd = { "custom-acp" } },
      ui = { chat_width = 48 },
    })

    local request
    omniac.backend = {
      supports_prompt_capability = function(_, capability)
        return capability == "embeddedContext"
      end,
      prompt = function(_, _, params, callback)
        request = params
        callback(nil, {})
      end,
    }

    local source_buf = vim.api.nvim_create_buf(false, true)
    local source_path = "/private/tmp/omniac-reference-command.lua"
    vim.api.nvim_buf_set_name(source_buf, source_path)
    vim.bo[source_buf].filetype = "lua"
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
      "local first = true",
      "local selected = true",
      "return selected",
    })
    vim.api.nvim_set_current_buf(source_buf)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    feed("Vj:OmniacReference<CR>")
    require("omniac.ui").set_status("ready", omniac.config)

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Attached ref:") ~= nil, "reference should be visible")

    local input_buf = vim.fn.bufnr("omniac://input")
    local input_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == input_buf then
        input_win = win
        break
      end
    end
    vim.api.nvim_set_current_win(input_win)
    vim.api.nvim_buf_set_lines(input_buf, 1, 2, false, { "│ > explain this" })
    feed("<CR>")

    assert_true(request ~= nil, "submitting should send the referenced prompt")
    assert_equal(request.prompt[1].type, "text", "typed instructions should remain text")
    assert_equal(request.prompt[2].type, "text", "selection should include instructions to inspect the selected range")
    assert_true(
      request.prompt[2].text:find("Please inspect", 1, true) ~= nil,
      "selection should include instructions to inspect its source"
    )
    assert_equal(request.prompt[3].type, "resource", "selection should use ACP embedded context")
    assert_equal(request.prompt[3].resource.uri:match("#L2%-L3$") ~= nil, true, "resource should retain its range")
    assert_equal(
      request.prompt[3].resource.text,
      "local selected = true\nreturn selected",
      "resource should contain the selected buffer text"
    )

    cleanup_omniac_buffers()
    if vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_delete(source_buf, { force = true })
    end
  end)

  it("slash exit closes chat without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    for _, name in ipairs({
      "Omniac",
      "OmniacConnect",
      "OmniacDisconnect",
      "OmniacExit",
      "OmniacSession",
      "OmniacSessionNew",
      "OmniacSessionLoad",
      "OmniacSessionResume",
      "OmniacAsk",
      "OmniacDebug",
      "OmniacAskFiles",
      "OmniacReference",
      "OmniacReferenceBuffer",
      "OmniacTreeAdd",
      "OmniacChanges",
      "OmniacDiff",
      "OmniacDiffAccept",
      "OmniacDiffDeny",
    }) do
      pcall(vim.api.nvim_del_user_command, name)
    end

    local omniac = require("omniac")
    omniac.setup({
      agent = { cmd = { "custom-acp" } },
      ui = { chat_width = 48 },
    })
    local submitted = false
    omniac.ask = function()
      submitted = true
    end

    omniac.open_chat()
    assert_true(has_window_for_buffer_name("omniac://input"), "input window should open")

    feed("i/exit<CR>")
    vim.cmd("redraw")

    assert_equal(submitted, false, "exit should not submit a prompt")
    assert_equal(has_window_for_buffer_name("omniac://input"), false, "input window should close")
    assert_equal(has_window_for_buffer_name("omniac"), false, "chat window should close")
  end)

  it("slash model argument changes the ACP session model without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    for _, name in ipairs({
      "Omniac",
      "OmniacConnect",
      "OmniacDisconnect",
      "OmniacExit",
      "OmniacSession",
      "OmniacSessionNew",
      "OmniacSessionLoad",
      "OmniacSessionResume",
      "OmniacAsk",
      "OmniacResize",
      "OmniacDebug",
      "OmniacAskFiles",
      "OmniacReference",
      "OmniacReferenceBuffer",
      "OmniacTreeAdd",
      "OmniacChanges",
      "OmniacDiff",
      "OmniacDiffAccept",
      "OmniacDiffDeny",
    }) do
      pcall(vim.api.nvim_del_user_command, name)
    end

    local omniac = require("omniac")
    omniac.setup({
      agent = { cmd = { "custom-acp" } },
      ui = { chat_width = 48 },
    })
    local selected
    omniac.backend = {
      get_session_model = function()
        return {
          currentModelId = "gpt-5",
          availableModels = {
            { id = "gpt-5", name = "GPT-5" },
            { id = "gpt-5-mini", name = "GPT-5 Mini" },
          },
        }
      end,
      set_session_model = function(_, model, callback)
        selected = model
        callback(nil, {}, model)
      end,
    }
    local submitted = false
    omniac.ask = function()
      submitted = true
    end

    omniac.open_chat()
    feed("i/model gpt-5-mini<CR>")
    vim.cmd("redraw")

    assert_equal(selected, "gpt-5-mini", "/model should pass its argument to the ACP backend")
    assert_equal(submitted, false, "/model should not be submitted as a prompt")
    assert_equal(omniac.config.agent.model, "gpt-5-mini", "selected model should be retained in config")
  end)

  it("slash model opens an approval-style model selector", function()
    cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    package.loaded["omniac.model_dialog"] = nil
    package.loaded["omniac.permission_dialog"] = nil
    for _, name in ipairs({
      "Omniac",
      "OmniacConnect",
      "OmniacDisconnect",
      "OmniacExit",
      "OmniacSession",
      "OmniacSessionNew",
      "OmniacSessionLoad",
      "OmniacSessionResume",
      "OmniacAsk",
      "OmniacResize",
      "OmniacDebug",
      "OmniacAskFiles",
      "OmniacReference",
      "OmniacReferenceBuffer",
      "OmniacTreeAdd",
      "OmniacChanges",
      "OmniacDiff",
      "OmniacDiffAccept",
      "OmniacDiffDeny",
    }) do
      pcall(vim.api.nvim_del_user_command, name)
    end

    local omniac = require("omniac")
    omniac.setup({
      agent = { cmd = { "custom-acp" } },
      ui = { chat_width = 48 },
    })
    local selected
    omniac.backend = {
      get_session_model = function()
        return {
          currentModelId = "gpt-5-mini",
          availableModels = {
            { id = "gpt-5", name = "GPT-5" },
            { id = "gpt-5-mini", name = "GPT-5 Mini" },
          },
        }
      end,
      set_session_model = function(_, model, callback)
        selected = model
        callback(nil, {}, model)
      end,
    }

    omniac.open_chat()
    feed("i/model<CR>")
    vim.wait(50, function()
      return vim.fn.bufnr("omniac://permission-selector") ~= -1
    end)

    local body_buf = vim.fn.bufnr("omniac://permission")
    local selector_buf = vim.fn.bufnr("omniac://permission-selector")
    local body_win = vim.fn.win_findbuf(body_buf)[1]
    local body_config = vim.api.nvim_win_get_config(body_win)
    local body = table.concat(vim.api.nvim_buf_get_lines(body_buf, 0, -1, false), "\n")
    local choices = table.concat(vim.api.nvim_buf_get_lines(selector_buf, 0, -1, false), "\n")

    assert_equal(body_config.title[1][1], " Model ", "model selector should use a model title")
    assert_true(body:match("Current model: gpt%-5%-mini") ~= nil, "model selector should show the current model")
    assert_true(choices:match("› 2  GPT%-5 Mini  %(current%)") ~= nil, "current model should start selected")
    assert_true(choices:match("GPT%-5 Mini") ~= nil, "available models should be shown in the list")
    assert_true(choices:match("q close") ~= nil, "model selector should describe q as close")

    feed("1")
    vim.wait(50, function()
      return selected ~= nil
    end)

    assert_equal(selected, "gpt-5", "choosing a model should update the ACP session")
    assert_equal(omniac.config.agent.model, "gpt-5", "chosen model should be retained in config")
  end)

  it("enter completes file mention without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      submitted = text
    end)

    feed("i@READ<CR>")
    vim.cmd("redraw")

    local input_buf = vim.fn.bufnr("omniac://input")
    local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
    assert_true(lines:match("@README.md") ~= nil, "enter should complete the file mention in the input")
    assert_equal(submitted, nil, "enter completion should not submit file mentions")
  end)

  it("tab completes slash input without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      submitted = text
    end)

    feed("i/res<Tab><Esc>")
    vim.cmd("redraw")

    local input_buf = vim.fn.bufnr("omniac://input")
    local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
    assert_true(lines:match("/resume") ~= nil, "tab should complete the slash command input text")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "tab completion should keep input focused")
    assert_equal(submitted, nil, "tab completion should not submit")
  end)

  it("tab completes local model command without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      submitted = text
    end)

    feed("i/mo<Tab>")
    vim.cmd("redraw")

    local input_buf = vim.fn.bufnr("omniac://input")
    local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
    assert_true(lines:match("/model") ~= nil, "tab should complete /mo to the local model command")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "model completion should keep input focused")
    assert_equal(submitted, nil, "model completion should not submit")
  end)

  it("tab completes file mention input without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      submitted = text
    end)

    feed("i@READ<Tab><Esc>")
    vim.cmd("redraw")

    local input_buf = vim.fn.bufnr("omniac://input")
    local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
    assert_true(lines:match("@README.md") ~= nil, "tab should complete the file mention input text")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "tab completion should keep input focused")
    assert_equal(submitted, nil, "tab completion should not submit")
  end)

  it("tab completes dollar skill input without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      submitted = text
    end)
    ui.set_available_commands({
      { name = "$imagegen", description = "Generate images" },
    })

    feed("i$im<Tab><Esc>")
    vim.cmd("redraw")

    local input_buf = vim.fn.bufnr("omniac://input")
    local lines = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
    assert_true(lines:match("%$imagegen") ~= nil, "tab should complete the dollar skill input text")
    assert_equal(vim.api.nvim_buf_get_name(0), "omniac://input", "tab completion should keep input focused")
    assert_equal(submitted, nil, "tab completion should not submit")
  end)

  it("enter completes and submits dollar skill", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local submitted

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      submitted = text
    end)
    ui.set_available_commands({
      { name = "$imagegen", description = "Generate images" },
    })

    feed("i$im<CR>")
    vim.cmd("redraw")

    assert_equal(submitted, "$imagegen", "enter should complete and submit the dollar skill")
  end)

  it("insert esc exits insert mode before normal esc cancels active turn", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local cancels = 0

    ui.set_cancel_handler(function()
      cancels = cancels + 1
    end)
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    feed("i<Esc>")
    assert_equal(cancels, 0, "insert esc should not cancel the active turn")
    assert_equal(vim.api.nvim_get_mode().mode, "n", "insert esc should return to normal mode")

    feed("<Esc><Esc>")
    vim.cmd("redraw")
    vim.wait(50, function()
      return cancels > 0
    end)

    assert_equal(cancels, 1, "normal esc should send one cancel request while working")
  end)

  it("cancel failure allows retry", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local cancels = 0

    ui.set_cancel_handler(function()
      cancels = cancels + 1
      ui.handle_notification({
        method = "omniac/prompt_cancel_failed",
        params = {
          message = "cancel failed",
        },
      }, { ui = { chat_width = 48 } })
    end)
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    feed("i<Esc>")
    assert_equal(cancels, 0, "insert esc should not send the first cancel request")

    feed("<Esc>")
    vim.cmd("redraw")
    vim.wait(50, function()
      return cancels >= 1
    end)
    feed("<Esc>")
    vim.cmd("redraw")
    vim.wait(50, function()
      return cancels >= 2
    end)

    assert_equal(cancels, 2, "failed cancel should allow a later esc retry")
  end)

  it("cancelled turn restores working activity on restart", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({ method = "omniac/prompt_cancelled", params = {} }, { ui = { chat_width = 48 } })
    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, { ui = { chat_width = 48 } })

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "restarted turn should restore working activity")
    assert_true(activity:match("Cancelled current turn") == nil, "restarted turn should clear cancelled activity")
  end)

  it("late cancelled completion from old turn is ignored", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = { turnId = 1 } }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/prompt_cancelled", params = { turnId = 1 } },
      { ui = { chat_width = 48 } }
    )
    ui.handle_notification({ method = "omniac/prompt_started", params = { turnId = 2 } }, { ui = { chat_width = 48 } })
    ui.handle_notification(
      { method = "omniac/response_completed", params = { turnId = 1, stopReason = "cancelled" } },
      { ui = { chat_width = 48 } }
    )

    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(activity:match("Working") ~= nil, "late cancelled completion should not replace working activity")
    assert_true(activity:match("Cancelled current turn") == nil, "late cancelled completion should stay hidden")
  end)

  it("cancel suppresses late current-turn tool output", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local config = {
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48, tool_results = "all" },
    }

    ui.set_cancel_handler(function() end)
    ui.open(config, function() end)

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, config)
    feed("i<Esc><Esc>")
    vim.cmd("redraw")

    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "late command",
        output = "late output\n",
        exitCode = 0,
      },
    }, config)

    local chat_buf = vim.fn.bufnr("omniac")
    local cancelled = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(cancelled:match("late command") == nil, "late cancelled tool output should be hidden")

    ui.handle_notification({
      method = "omniac/response_completed",
      params = {
        stopReason = "max_tokens",
      },
    }, config)

    cancelled = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local activity_buf = vim.fn.bufnr("omniac://activity")
    local activity = table.concat(vim.api.nvim_buf_get_lines(activity_buf, 0, -1, false), "\n")
    assert_true(
      cancelled:match("Stopped: token limit") == nil,
      "late cancelled completion should not add a stop reason footer"
    )
    assert_true(
      activity:match("Stopped: max_tokens") == nil,
      "late cancelled completion should not add stop reason activity"
    )

    ui.handle_notification({ method = "omniac/prompt_started", params = {} }, config)
    ui.handle_notification({
      method = "omniac/tool_result",
      params = {
        kind = "execute",
        status = "completed",
        command = "next command",
        output = "next output\n",
        exitCode = 0,
      },
    }, config)

    local next_turn = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    assert_true(next_turn:match("next command") ~= nil, "next turn tool output should render normally")
  end)

  it("shift tab switches to chat without cycling session mode", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local count = 0

    ui.set_mode_cycle_handler(function()
      count = count + 1
    end)
    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function() end)

    feed("i<S-Tab><Esc>")
    vim.cmd("redraw")

    assert_equal(count, 0, "shift-tab should not call the mode cycle handler")
    assert_equal(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "omniac", "shift-tab should focus chat")
  end)

  it("command suggestions do not drift input window", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)

    local input_win = vim.api.nvim_get_current_win()
    local initial_row = vim.api.nvim_win_get_position(input_win)[1]

    for _ = 1, 3 do
      feed("i/<Esc>")
      vim.cmd("redraw")
      feed("a<BS><Esc>")
      vim.cmd("redraw")
    end

    vim.wait(20)
    vim.cmd("redraw")
    assert_equal(vim.api.nvim_win_get_position(input_win)[1], initial_row, "input window row should not drift")
  end)

  it("shrinking command suggestions stay below input", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(_) end)
    ui.set_available_commands({
      { name = "alpha", description = "one" },
      { name = "alpine", description = "two" },
      { name = "apply", description = "three" },
      { name = "archive", description = "four" },
      { name = "banana", description = "five" },
    })

    local input_win = vim.api.nvim_get_current_win()
    local initial_row = vim.api.nvim_win_get_position(input_win)[1]

    feed("i/a<Esc>")
    vim.cmd("redraw")
    assert_equal(
      vim.api.nvim_win_get_position(input_win)[1],
      initial_row,
      "input row should stay while suggestions open"
    )

    feed("arch<Esc>")
    vim.cmd("redraw")
    assert_equal(
      vim.api.nvim_win_get_position(input_win)[1],
      initial_row,
      "input row should stay when suggestions shrink"
    )
  end)

  it("omniac ui buffers are named and unlisted", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 42 },
    }, function(_) end)

    local expected = {
      ["omniac"] = false,
      ["omniac://input"] = false,
      ["omniac://activity"] = false,
      ["omniac://status"] = false,
    }

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      local basename = vim.fn.fnamemodify(name, ":t")
      local key = expected[name] ~= nil and name or basename
      if expected[key] ~= nil then
        expected[key] = true
        assert_equal(vim.bo[buf].buflisted, false, key .. " should be hidden from buffer list")
      end
    end

    for name, seen in pairs(expected) do
      assert_true(seen, name .. " buffer should exist")
    end
  end)
end)
