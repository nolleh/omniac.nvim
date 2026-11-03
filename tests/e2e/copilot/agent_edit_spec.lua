local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true

describe("omniac.nvim live Copilot ACP", function()
  it("applies a requested edit through the ACP client", function()
    local root = vim.fn.getcwd()
    local fixture_dir = vim.fn.tempname() .. "-omniac-copilot-e2e"
    local source = root .. "/tests/e2e/fixtures/copilot/change.txt"
    local target = fixture_dir .. "/change.txt"
    vim.fn.mkdir(fixture_dir, "p")
    vim.fn.writefile(vim.fn.readfile(source), target)

    local omniac = require("omniac")
    local config = vim.deepcopy(require("omniac.config").defaults)
    local autopilot_mode = "https://agentclientprotocol.com/protocol/session-modes#autopilot"
    config.agent.cmd = vim.fn.executable("copilot") == 1 and { "copilot", "--acp", "--stdio" }
      or { "npx", "--yes", "@github/copilot", "--acp", "--stdio" }
    config.agent.cwd = fixture_dir
    config.agent.mode_id = autopilot_mode
    config.ui.change_review = "off"
    config.debug = true
    config.logs.dir = fixture_dir
    omniac.setup(config)

    local client
    local prompt_result
    local ok, failure = xpcall(function()
      client = omniac.connect()
      assert_true(
        vim.wait(90000, function()
          return client.session_id ~= nil
            and client.session_mode
            and client.session_mode.currentModeId == autopilot_mode
        end, 50),
        "Copilot ACP session should start in Autopilot mode"
      )

      client:prompt(
        'In change.txt, replace the exact line "before" with "after". Do not modify or create any other file.',
        nil,
        function(err, result)
          prompt_result = { err = err, result = result }
        end
      )

      assert_true(
        vim.wait(180000, function()
          return prompt_result ~= nil
        end, 50),
        "Copilot should finish the edit prompt"
      )
      assert_equal(prompt_result.err, nil)
      assert_equal(prompt_result.result.stopReason, "end_turn")
      assert_equal(table.concat(vim.fn.readfile(target), "\n"), "after")

      local files = vim.fn.glob(fixture_dir .. "/*", false, true)
      assert_equal(#files, 2, "the fixture file and ACP log should be the only files in the workspace")
    end, debug.traceback)

    if client then
      omniac.disconnect()
    end
    vim.fn.delete(fixture_dir, "rf")
    if not ok then
      error(failure)
    end
  end)
end)
