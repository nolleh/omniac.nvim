local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers

describe("omniac.nvim chat", function()
  after_each(helpers.cleanup_after_test)

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

  it("streaming follows chat at the bottom while the input window is active", function()
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
    vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(chat_buf), 0 })
    local input_buf = vim.fn.bufnr("omniac://input")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == input_buf then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
    assert_true(vim.api.nvim_get_current_win() ~= chat_win, "input should be focused")

    ui.append_response_chunk(
      table.concat(
        vim.tbl_map(function(index)
          return "streamed text " .. index
        end, vim.fn.range(1, 40)),
        "\n"
      ),
      config
    )
    vim.wait(100, function()
      local chat = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      return chat:match("streamed text") ~= nil
    end)

    assert_equal(
      vim.api.nvim_win_get_cursor(chat_win)[1],
      vim.api.nvim_buf_line_count(chat_buf),
      "chat at the bottom should follow while input has focus"
    )
    local view = vim.api.nvim_win_call(chat_win, vim.fn.winsaveview)
    assert_true(
      view.topline + vim.api.nvim_win_get_height(chat_win) >= vim.api.nvim_buf_line_count(chat_buf),
      "new chat content should remain visible while input has focus"
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
