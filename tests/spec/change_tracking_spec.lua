local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local changes = require("omniac.changes")
local acp = require("omniac.backend.acp")
local snapshot = require("omniac.changes.snapshot")

describe("omniac.nvim agent change tracking", function()
  local cwd, client, complete, finished

  local function write(path, lines)
    vim.fn.writefile(lines, cwd .. "/" .. path)
  end

  local function git(args)
    local command = { "git", "-C", cwd }
    vim.list_extend(command, args)
    local result = vim.system(command):wait()
    assert_equal(result.code, 0, result.stderr)
  end

  local function send(update)
    client:_handle_notification({
      method = "session/update",
      params = { sessionId = client.session_id, update = update },
    })
  end

  local function start()
    finished = false
    client:prompt("update the files")
  end

  local function finish(err, reason)
    complete(err, { stopReason = reason or "end_turn" })
    assert_true(
      vim.wait(1000, function()
        return finished
      end),
      "turn notifications should finish"
    )
  end

  local function by_path(scope)
    local result = {}
    for _, item in ipairs(changes.get(scope or "turn")) do
      result[vim.fn.fnamemodify(item.path, ":t")] = item
    end
    return result
  end

  before_each(function()
    cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    cwd = (vim.uv or vim.loop).fs_realpath(cwd)
    git({ "init", "--quiet" })
    write("tracked.txt", { "original", "keep" })
    write("deleted.txt", { "delete me" })
    write("untouched.txt", { "original" })
    write(".gitignore", { "ignored.txt" })
    git({ "add", "." })
    write("tracked.txt", { "user draft", "keep" })
    write("untouched.txt", { "existing dirty file" })
    write("untracked.txt", { "existing untracked file" })
    client = acp.new({ agent = { cwd = cwd } })
    client.running = true
    client.session_id = "session-1"
    client.transport = {
      request = function(_, method, _, callback)
        assert_equal(method, "session/prompt")
        complete = callback
      end,
      close = function() end,
    }
    changes.reset(client.session_id)
    client:on_request(function()
      error("tracking must not require an approval request")
    end)
    client:on_notification(function(message)
      if message.method == "omniac/prompt_started" then
        changes.start_turn(message.params)
      elseif message.method == "omniac/file_update" then
        changes.record(message.params)
      elseif message.method == "omniac/response_completed" or message.method == "omniac/prompt_failed" then
        changes.finish_turn(message.params)
        finished = true
      end
    end)
  end)

  after_each(function()
    client:close()
    vim.fn.delete(cwd, "rf")
    helpers.cleanup_after_test()
  end)

  it("records auto-approved edits with locations and no permission or diff content", function()
    start()
    send({
      sessionUpdate = "tool_call",
      toolCallId = "edit",
      kind = "edit",
      status = "in_progress",
      locations = { { path = cwd .. "/tracked.txt" } },
    })
    write("tracked.txt", { "agent edit", "keep" })
    send({ sessionUpdate = "tool_call_update", toolCallId = "edit", status = "completed" })
    finish()
    local files = by_path()
    assert_equal(changes.count("turn"), 1)
    assert_equal(files["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(files["tracked.txt"].newText, "agent edit\nkeep\n")
    assert_equal(vim.fn.readfile(cwd .. "/tracked.txt")[1], "agent edit", "tracking must not reapply edits")
  end)

  it("uses full pre-turn contents for completion-only edit diffs", function()
    start()
    write("tracked.txt", { "agent edit", "keep" })
    send({
      sessionUpdate = "tool_call_update",
      toolCallId = "edit",
      status = "completed",
      content = {
        { type = "diff", path = cwd .. "/tracked.txt", oldText = "user draft", newText = "agent edit" },
      },
    })
    finish()
    assert_equal(by_path()["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(by_path()["tracked.txt"].newText, "agent edit\nkeep\n")
  end)

  it("tracks every file when the first edit is written before its start notification", function()
    start()
    write("tracked.txt", { "agent edit", "keep" })
    send({
      sessionUpdate = "tool_call",
      toolCallId = "batch-edit",
      kind = "edit",
      status = "in_progress",
      content = {
        { type = "diff", path = cwd .. "/tracked.txt", oldText = "user draft", newText = "agent edit" },
        { type = "diff", path = cwd .. "/untracked.txt", oldText = "existing untracked file", newText = "updated" },
        { type = "diff", path = cwd .. "/new.txt", oldText = "", newText = "created" },
      },
    })
    write("untracked.txt", { "updated" })
    write("new.txt", { "created" })
    send({ sessionUpdate = "tool_call_update", toolCallId = "batch-edit", status = "completed" })
    finish()
    local files = by_path()
    assert_equal(changes.count("turn"), 3)
    assert_equal(files["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(files["tracked.txt"].newText, "agent edit\nkeep\n")
  end)

  local late_edits = {
    {
      name = "extends a replacement",
      old = "user draft",
      new = "user draft extended",
      current = "user draft extended\nkeep\n",
    },
    { name = "shortens a replacement", old = "user draft", new = "draft", current = "draft\nkeep\n" },
    { name = "prepends text", old = "", new = "header\n", current = "header\nuser draft\nkeep\n" },
    { name = "inserts text", old = "", new = "inserted\n", current = "user draft\ninserted\nkeep\n" },
    { name = "appends text", old = "", new = "tail\n", current = "user draft\nkeep\ntail\n" },
    { name = "inserts repeated text", previous = "aaaa\n", old = "", new = "a", current = "aaaaa\n" },
    { name = "creates a file", path = "new.txt", old = "", new = "created\n", current = "created\n" },
    {
      name = "creates a file without a final newline",
      path = "new.txt",
      old = "",
      new = "created",
      current = "created",
    },
    { name = "deletes text", old = "user draft\n", new = "", current = "keep\n" },
    { name = "deletes a file", path = "deleted.txt", previous = "delete me\n", old = "delete me\n", new = "" },
    {
      name = "replaces one of several occurrences",
      previous = "user draft\nuser draft\nkeep\n",
      old = "user draft",
      new = "updated",
      current = "user draft\nupdated\nkeep\n",
    },
    { name = "replaces an overlapping occurrence", previous = "aaa\n", old = "aa", new = "X", current = "aX\n" },
    {
      name = "replaces the whole file with extended contents",
      old = "user draft\nkeep\n",
      new = "user draft\nkeep\ntail\n",
      current = "user draft\nkeep\ntail\n",
    },
  }

  for index, edit in ipairs(late_edits) do
    it("recovers a late edit that " .. edit.name, function()
      local path = edit.path or "tracked.txt"
      local previous = edit.previous or (path == "tracked.txt" and "user draft\nkeep\n" or "")
      if edit.previous then
        vim.fn.writefile(vim.split(previous, "\n", { plain = true }), cwd .. "/" .. path, "b")
      end
      start()
      if edit.current then
        vim.fn.writefile(vim.split(edit.current, "\n", { plain = true }), cwd .. "/" .. path, "b")
      else
        vim.fn.delete(cwd .. "/" .. path)
      end
      send({
        sessionUpdate = "tool_call",
        toolCallId = "late-edit",
        kind = "edit",
        status = "in_progress",
        locations = index % 2 == 0 and { { path = cwd .. "/" .. path } } or nil,
        content = { { type = "diff", path = cwd .. "/" .. path, oldText = edit.old, newText = edit.new } },
      })
      send({ sessionUpdate = "tool_call_update", toolCallId = "late-edit", status = "completed" })
      finish()
      local file = by_path()[path]
      assert_true(file ~= nil, "late edit must remain in change history")
      assert_equal(changes.count("turn"), 1)
      assert_equal(file.oldText, previous)
      assert_equal(file.newText, edit.current or "")
      assert_equal(require("omniac.editor.filesystem").read_disk_content(cwd .. "/" .. path), edit.current)
    end)
  end

  it("includes terminal writes, additions and deletions without including pre-existing changes", function()
    start()
    send({ sessionUpdate = "tool_call", toolCallId = "exec", kind = "execute", status = "in_progress" })
    write("tracked.txt", { "terminal edit", "keep" })
    write("new file.txt", { "created" })
    write("untracked.txt", { "updated untracked file" })
    write("ignored.txt", { "generated" })
    vim.fn.delete(cwd .. "/deleted.txt")
    send({ sessionUpdate = "tool_call_update", toolCallId = "exec", status = "completed" })
    finish()
    local files = by_path()
    assert_equal(changes.count("turn"), 4)
    assert_equal(files["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(files["tracked.txt"].source, "terminal")
    assert_equal(files["new file.txt"].oldText, "")
    assert_equal(files["deleted.txt"].newText, "")
    assert_equal(files["untracked.txt"].oldText, "existing untracked file\n")
    assert_equal(files["ignored.txt"], nil)
    assert_equal(files["untouched.txt"], nil)
  end)

  it("retains the preceding checkpoint when a late diff arrives at completion", function()
    start()
    for index = 1, 2 do
      local previous = index == 1 and "user draft" or "first edit"
      local current = index == 1 and "first edit" or "second edit"
      write("tracked.txt", { current, "keep" })
      local id = "late-" .. index
      send({
        sessionUpdate = "tool_call",
        toolCallId = id,
        kind = "edit",
        status = "in_progress",
        locations = { { path = cwd .. "/tracked.txt" } },
      })
      send({
        sessionUpdate = "tool_call_update",
        toolCallId = id,
        status = "completed",
        content = {
          { type = "diff", path = cwd .. "/tracked.txt", oldText = previous, newText = current },
        },
      })
    end
    finish()
    local file = by_path()["tracked.txt"]
    assert_true(file ~= nil)
    assert_equal(file.oldText, "user draft\nkeep\n")
    assert_equal(file.newText, "second edit\nkeep\n")
  end)

  it("keeps the existing checkpoint even when disk contents differ from the reported edit", function()
    start()
    write("tracked.txt", { "user save", "keep" })
    send({
      sessionUpdate = "tool_call",
      toolCallId = "noop",
      kind = "edit",
      status = "in_progress",
      content = {
        { type = "diff", path = cwd .. "/tracked.txt", oldText = "user draft", newText = "agent proposal" },
      },
    })
    send({ sessionUpdate = "tool_call_update", toolCallId = "noop", status = "completed" })
    finish()
    local file = by_path()["tracked.txt"]
    assert_equal(changes.count("turn"), 1)
    assert_equal(file.oldText, "user draft\nkeep\n")
    assert_equal(file.newText, "user save\nkeep\n")
    assert_equal(file.beforeSource, "snapshot")
  end)

  it("keeps an earlier saved state when the reported edit is mixed with other changes", function()
    start()
    write("tracked.txt", { "agent proposal", "unrelated user save", "keep" })
    send({
      sessionUpdate = "tool_call",
      toolCallId = "unapplied",
      kind = "edit",
      status = "in_progress",
      content = {
        { type = "diff", path = cwd .. "/tracked.txt", oldText = "user draft", newText = "agent proposal" },
      },
    })
    send({ sessionUpdate = "tool_call_update", toolCallId = "unapplied", status = "completed" })
    finish()
    local file = by_path()["tracked.txt"]
    assert_equal(changes.count("turn"), 1)
    assert_equal(file.oldText, "user draft\nkeep\n")
    assert_equal(file.newText, "agent proposal\nunrelated user save\nkeep\n")
    assert_equal(file.beforeSource, "snapshot")
    assert_equal(by_path("session")["tracked.txt"].beforeSource, "snapshot")
  end)

  it("shows the earlier hello snapshot alongside the actual externally edited file", function()
    write("tracked.txt", { "hello" })
    start()
    write("tracked.txt", { "hello! world" })
    send({
      sessionUpdate = "tool_call",
      toolCallId = "mixed-addition",
      kind = "edit",
      status = "in_progress",
      content = { { type = "diff", path = cwd .. "/tracked.txt", oldText = "hello", newText = "hello world" } },
    })
    send({ sessionUpdate = "tool_call_update", toolCallId = "mixed-addition", status = "completed" })
    finish()
    local file = by_path()["tracked.txt"]
    assert_equal(file.oldText, "hello\n")
    assert_equal(file.newText, "hello! world\n")
    assert_equal(file.beforeSource, "snapshot")
    assert_equal(vim.fn.readfile(cwd .. "/tracked.txt")[1], "hello! world")
  end)

  it("does not attribute changes outside agent tool execution to the session", function()
    start()
    write("untracked.txt", { "user save before execution" })
    send({ sessionUpdate = "tool_call", toolCallId = "exec", kind = "execute", status = "in_progress" })
    write("tracked.txt", { "agent edit" })
    send({ sessionUpdate = "tool_call_update", toolCallId = "exec", status = "completed" })
    write("untouched.txt", { "user save after execution" })
    finish()
    assert_equal(changes.count("turn"), 1)
    assert_true(by_path()["tracked.txt"] ~= nil)
    start()
    write("untracked.txt", { "user save during a conversation-only turn" })
    finish()
    assert_equal(changes.count("turn"), 0)
    assert_equal(changes.count("session"), 1)
  end)

  it("keeps terminal changes after a prompt failure or cancellation", function()
    for _, failed in ipairs({ true, false }) do
      start()
      send({ sessionUpdate = "tool_call", toolCallId = "exec", kind = "execute", status = "in_progress" })
      write("tracked.txt", { failed and "partial result" or "cancelled result" })
      finish(failed and { message = "connection lost" } or nil, "cancelled")
      assert_equal(changes.count("turn"), 1)
      assert_equal(by_path()["tracked.txt"].newText, failed and "partial result\n" or "cancelled result\n")
    end
  end)

  it("waits for interleaved terminal calls and deduplicates repeated completion", function()
    start()
    for _, id in ipairs({ "a", "b" }) do
      send({ sessionUpdate = "tool_call", toolCallId = id, kind = "execute", status = "in_progress" })
    end
    write("tracked.txt", { "first command" })
    send({ sessionUpdate = "tool_call_update", toolCallId = "a", status = "completed" })
    write("tracked.txt", { "second command" })
    for _ = 1, 2 do
      send({ sessionUpdate = "tool_call_update", toolCallId = "b", status = "completed" })
    end
    finish()
    assert_equal(changes.count("turn"), 1)
    assert_equal(by_path()["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(by_path()["tracked.txt"].newText, "second command\n")
  end)

  it("merges edit and terminal changes across turns into one session diff", function()
    start()
    send({
      sessionUpdate = "tool_call",
      toolCallId = "edit",
      kind = "edit",
      status = "in_progress",
      locations = { { path = cwd .. "/tracked.txt" } },
    })
    write("tracked.txt", { "edit result" })
    send({ sessionUpdate = "tool_call_update", toolCallId = "edit", status = "completed" })
    send({ sessionUpdate = "tool_call", toolCallId = "exec", kind = "execute", status = "in_progress" })
    write("tracked.txt", { "terminal result" })
    send({ sessionUpdate = "tool_call_update", toolCallId = "exec", status = "completed" })
    finish()
    assert_equal(changes.count("turn"), 1)
    assert_equal(by_path()["tracked.txt"].oldText, "user draft\nkeep\n")
    start()
    write("tracked.txt", { "next turn" })
    send({ sessionUpdate = "tool_call", toolCallId = "exec", kind = "execute", status = "completed" })
    finish()
    assert_equal(by_path()["tracked.txt"].oldText, "terminal result\n")
    assert_equal(by_path("session")["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(by_path("session")["tracked.txt"].newText, "next turn\n")
    changes.reset("session-2")
    assert_equal(changes.count("session"), 0)
  end)

  it("records actual partial edits on failure but excludes rejected unchanged edits", function()
    start()
    for _, id in ipairs({ "rejected", "partial" }) do
      send({
        sessionUpdate = "tool_call",
        toolCallId = id,
        kind = "edit",
        status = "in_progress",
        locations = { { path = cwd .. "/tracked.txt" } },
      })
      if id == "partial" then
        write("tracked.txt", { "partial edit" })
      end
      send({ sessionUpdate = "tool_call_update", toolCallId = id, status = "failed" })
    end
    finish()
    assert_equal(changes.count("turn"), 1)
    assert_equal(by_path()["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(by_path()["tracked.txt"].newText, "partial edit\n")
  end)

  it("tracks file creation and deletion from auto-approved tool locations", function()
    start()
    send({
      sessionUpdate = "tool_call",
      toolCallId = "create",
      kind = "edit",
      status = "in_progress",
      locations = { { path = cwd .. "/created.txt" } },
    })
    write("created.txt", { "new text" })
    send({ sessionUpdate = "tool_call_update", toolCallId = "create", status = "completed" })
    send({
      sessionUpdate = "tool_call",
      toolCallId = "delete",
      kind = "delete",
      status = "in_progress",
      locations = { { path = cwd .. "/deleted.txt" } },
    })
    vim.fn.delete(cwd .. "/deleted.txt")
    send({ sessionUpdate = "tool_call_update", toolCallId = "delete", status = "completed" })
    finish()
    assert_equal(changes.count("turn"), 2)
    assert_equal(by_path()["created.txt"].oldText, "")
    assert_equal(by_path()["created.txt"].newText, "new text\n")
    assert_equal(by_path()["deleted.txt"].operation, "delete")
  end)

  it("captures auto-approved edits without paths, diffs or a completion notification", function()
    start()
    send({
      sessionUpdate = "tool_call",
      toolCallId = "opaque-edit",
      kind = "edit",
      status = "in_progress",
    })
    write("tracked.txt", { "opaque edit result" })
    finish({ message = "agent disconnected after writing" })
    assert_equal(changes.count("turn"), 1)
    assert_equal(by_path()["tracked.txt"].oldText, "user draft\nkeep\n")
    assert_equal(by_path()["tracked.txt"].newText, "opaque edit result\n")
  end)

  it("ignores notifications from another session", function()
    start()
    client:_handle_notification({
      method = "session/update",
      params = {
        sessionId = "another-session",
        update = {
          sessionUpdate = "tool_call",
          toolCallId = "foreign",
          kind = "edit",
          status = "completed",
          content = { { type = "diff", path = cwd .. "/tracked.txt", oldText = "old", newText = "foreign" } },
        },
      },
    })
    finish()
    assert_equal(changes.count("session"), 0)
  end)

  it("compares text files without Git and skips binary or oversized previews", function()
    vim.fn.delete(cwd .. "/.git", "rf")
    local before = snapshot.capture(cwd)
    write("tracked.txt", { "non-git edit" })
    local uv = vim.uv or vim.loop
    local fd = assert(uv.fs_open(cwd .. "/binary.dat", "w", 438))
    uv.fs_write(fd, "binary\0content", 0)
    uv.fs_close(fd)
    write("large.txt", { string.rep("x", 2 * 1024 * 1024 + 1) })
    local files = snapshot.diff(before, snapshot.capture(cwd))
    assert_equal(#files, 1)
    assert_equal(files[1].newText, "non-git edit\n")
  end)
end)
