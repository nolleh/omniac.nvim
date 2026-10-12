local helpers = require("tests.helpers")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true

describe("omniac.nvim live adjusted approval", function()
  it("replays one adjusted file from a two-file diff and finishes the follow-up", function()
    local root = vim.fn.getcwd()
    local fixture = vim.fn.fnamemodify(root, ":h") .. "/.omniac-acp-e2e-" .. tostring(vim.loop.hrtime())
    local first = fixture .. "/first.txt"
    local second = fixture .. "/second.txt"
    vim.fn.mkdir(fixture, "p")
    vim.fn.writefile({ "first=old" }, first)
    vim.fn.writefile({ "second=old" }, second)

    local omniac = require("omniac")
    local ui = require("omniac.ui")
    local config = vim.deepcopy(require("omniac.config").defaults)
    config.agent.cmd = { "codex-acp" }
    config.agent.cwd = root
    config.agent.mode_id = "workspace-write"
    config.ui.change_review = "off"
    config.debug = true
    config.logs.dir = fixture
    omniac.config = config

    local client
    local original_prompt
    local original_result
    local followup_result
    local followup_sent = false
    local events = {}
    local ok, failure = xpcall(function()
      ui.open(config, function() end)
      client = omniac.connect()
      local original_request_handler = client.request_handler
      client:on_request(function(message, reply)
        table.insert(events, "request:" .. tostring(message.method))
        original_request_handler(message, reply)
      end)
      local original_notification_handler = client.notification_handler
      client:on_notification(function(message)
        if message.method ~= "omniac/tool_activity" and message.method ~= "omniac/response_chunk" then
          table.insert(events, "notification:" .. tostring(message.method))
        end
        original_notification_handler(message)
      end)
      original_prompt = client.prompt
      client.prompt = function(self, text, params, callback)
        if text:find("The user adjusted an edit in the approval diff", 1, true) then
          followup_sent = true
          return original_prompt(self, text, params, function(err, result)
            followup_result = { err = err, result = result }
            callback(err, result)
          end)
        end
        return original_prompt(self, text, params, callback)
      end

      assert_true(
        vim.wait(30000, function()
          return client.session_id ~= nil
        end, 20),
        "live ACP session should start"
      )

      client:prompt(
        string.format(
          "Use one apply_patch call to edit both existing files. In %s, replace first=old with first=proposed. In %s, replace second=old with second=proposed. Both files must be in the same edit call. If permission is rejected, stop without retrying. Do not use shell commands.",
          first,
          second
        ),
        nil,
        function(err, result)
          original_result = { err = err, result = result }
        end
      )

      local first_review = "Omniac permission (1/2): " .. first
      local second_review = "Omniac permission (2/2): " .. second
      assert_true(
        vim.wait(45000, function()
          return vim.api.nvim_buf_get_name(0):find(first_review, 1, true) ~= nil
        end, 20),
        "first file of the two-file approval should open; buffer="
          .. vim.api.nvim_buf_get_name(0)
          .. "; events="
          .. table.concat(events, ",")
          .. "; result="
          .. vim.inspect(original_result)
      )
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first=reviewed", "" })
      vim.cmd("write")

      assert_true(
        vim.wait(10000, function()
          return vim.api.nvim_buf_get_name(0):find(second_review, 1, true) ~= nil
        end, 20),
        "second file of the two-file approval should open"
      )
      vim.cmd("write")

      assert_true(
        vim.wait(90000, function()
          return original_result ~= nil and followup_sent
        end, 20),
        "original prompt should end and send the follow-up"
      )
      assert_equal(original_result.err, nil)
      assert_equal(original_result.result.stopReason, "cancelled")

      local unexpected_diff
      assert_true(
        vim.wait(60000, function()
          local name = vim.api.nvim_buf_get_name(0)
          if name:find("Omniac permission", 1, true) then
            unexpected_diff = name
          end
          return followup_result ~= nil or unexpected_diff ~= nil
        end, 20),
        "follow-up prompt should complete; buffer="
          .. vim.api.nvim_buf_get_name(0)
          .. "; events="
          .. table.concat(events, ",")
          .. "; first="
          .. table.concat(vim.fn.readfile(first), "\n")
          .. "; second="
          .. table.concat(vim.fn.readfile(second), "\n")
      )
      assert_equal(unexpected_diff, nil, "follow-up edit should be auto-approved: " .. tostring(unexpected_diff))
      assert_equal(followup_result.err, nil)
      assert_equal(followup_result.result.stopReason, "end_turn")
      assert_equal(table.concat(vim.fn.readfile(first), "\n"), "first=reviewed")
      assert_equal(table.concat(vim.fn.readfile(second), "\n"), "second=proposed")

      local log_path
      assert_true(
        vim.wait(1000, function()
          local paths = vim.fn.globpath(fixture, "acp-*.jsonl", false, true)
          log_path = paths[1]
          if not log_path then
            return false
          end
          local prompts, responses = 0, 0
          for _, line in ipairs(vim.fn.readfile(log_path)) do
            local entry = vim.json.decode(line)
            if entry.event == "client_request" and entry.payload.method == "session/prompt" then
              prompts = prompts + 1
            elseif entry.event == "agent_response" and entry.payload.result and entry.payload.result.stopReason then
              responses = responses + 1
            end
          end
          return prompts == 2 and responses == 2
        end, 20),
        "JSONL should record both prompt requests and responses"
      )
    end, debug.traceback)

    if client then
      omniac.disconnect()
    end
    ui.close()
    vim.fn.delete(fixture, "rf")
    if not ok then
      error(failure)
    end
  end)
end)
