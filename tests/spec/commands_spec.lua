local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local feed = helpers.feed
local cleanup_omniac_buffers = helpers.cleanup_omniac_buffers
local has_window_for_buffer_name = helpers.has_window_for_buffer_name

describe("omniac.nvim commands", function()
  after_each(helpers.cleanup_after_test)

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
    assert_true(lines:match("/mode") ~= nil, "local mode command should be listed")
    assert_true(lines:match("/resume") ~= nil, "local resume command should be listed")
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

  it("submitting a slash command closes suggestions before opening another window", function()
    cleanup_omniac_buffers()
    package.loaded["omniac.ui"] = nil
    local ui = require("omniac.ui")
    local command_win

    ui.open({
      agent = { cmd = { "codex-acp" } },
      ui = { chat_width = 48 },
    }, function(text)
      assert_equal(text, "/changes", "the local command should be submitted")
      vim.cmd("botright 3new")
    end)

    feed("i/changes<Esc>")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == "omniac://commands" then
        command_win = win
      end
    end
    assert_true(command_win ~= nil, "suggestions should be visible before submission")

    feed("<CR>")
    assert_equal(vim.api.nvim_win_is_valid(command_win), false, "submitted command should close suggestions")
    vim.cmd("close")
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

  it("slash mode changes an advertised ACP config option without submitting", function()
    cleanup_omniac_buffers()
    package.loaded["omniac"] = nil
    package.loaded["omniac.ui"] = nil
    local omniac = require("omniac")
    omniac.setup({ agent = { cmd = { "codex-acp" } }, ui = { chat_width = 48 }, keymaps = false })
    local selected
    omniac.backend = {
      get_session_mode = function()
        return {
          currentModeId = "read-only",
          availableModes = {
            { id = "read-only", name = "Read-only" },
            { id = "agent", name = "Auto review" },
          },
        }
      end,
      set_session_mode = function(_, mode_id, callback)
        selected = mode_id
        callback(nil)
      end,
    }
    local submitted = false
    omniac.ask = function()
      submitted = true
    end

    omniac.open_chat()
    feed("i/mode agent<CR>")

    assert_equal(selected, "agent", "/mode should select the advertised ID")
    assert_equal(submitted, false, "/mode should not submit a prompt")
    assert_equal(omniac.config.agent.mode_id, "read-only", "session changes should not change the configured default")
  end)

  it("mode selector presents the agent's mode names and descriptions", function()
    package.loaded["omniac.mode_dialog"] = nil
    local dialog = require("omniac.mode_dialog")
    local permission_dialog = require("omniac.permission_dialog")
    local original_open = permission_dialog.open
    local shown_options, shown_config
    permission_dialog.open = function(options, config)
      shown_options, shown_config = options, config
    end

    local opened = dialog.open({
      currentModeId = "agent",
      availableModes = {
        { id = "read-only", name = "Read-only", description = "Ask before edits" },
        { id = "agent", name = "Auto review", description = "Review requests automatically" },
      },
    }, function() end)
    permission_dialog.open = original_open

    assert_equal(opened, true, "advertised modes should open the selector")
    assert_equal(shown_options[2].name, "Auto review  (current)", "selector should use the advertised name")
    assert_equal(shown_options[2].description, "Review requests automatically", "selector should show the description")
    assert_equal(shown_config.selected, 2, "selector should focus the current mode")
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

  it("tab completes a local mode command without submitting", function()
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
    assert_true(lines:match("/mode") ~= nil or lines:match("/model") ~= nil, "tab should complete a local mode command")
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
end)
