local acp_backend = require("omniac.backend.acp")
local approval = require("omniac.approval")
local changes = require("omniac.changes")
local filesystem = require("omniac.editor.filesystem")
local modified_approval = require("omniac.approval.followup")
local session_dialog = require("omniac.session.dialog")
local ui = require("omniac.ui")

local M = {}

function M.connect(app, opts, submission_failure)
  opts = opts or {}
  ui.set_session_usage(nil)
  local cfg = app.config
  if opts.session then
    cfg = vim.deepcopy(app.config)
    cfg.agent = cfg.agent or {}
    cfg.agent.session = vim.tbl_extend("force", cfg.agent.session or {}, opts.session)
  end
  cfg.session_selector = function(sessions, selector_opts, callback)
    session_dialog.open(sessions, selector_opts, callback)
  end

  local client = acp_backend.new(cfg)
  local function new_modified_approval()
    return modified_approval.new(client, cfg, function()
      return app.backend == client
    end)
  end
  local followup = new_modified_approval()
  local permission_approval = approval.new()
  app.modified_approval = followup
  app.permission_approval = permission_approval
  client
    :on_request(function(message, reply)
      local method = message and message.method
      local params = message and message.params or {}

      local function logged_reply(result, err)
        return reply(result, err)
      end

      if method == "session/request_permission" then
        permission_approval:review_acp_permission(params, logged_reply, cfg, function(item)
          return followup:queue(item)
        end, function(request, payload)
          return followup:matches_followup(request, payload)
        end)
        return
      end

      if method == "fs/read_text_file" or method == "fs/write_text_file" then
        local before
        if method == "fs/write_text_file" then
          local current = filesystem.read_text_file({ path = params.path })
          before = current and current.content or ""
        end
        local result, err = filesystem.handle_request(method, params)
        if method == "fs/write_text_file" and not err then
          changes.record({
            sessionId = params.sessionId or client.session_id,
            turnId = client.active_turn_id,
            path = params.path,
            oldText = before,
            newText = params.content,
            source = "filesystem",
          })
        end
        logged_reply(result, err)
        return
      end

      logged_reply({})
    end)
    :on_notification(function(message)
      if app.backend ~= client then
        return
      end
      local method = message and message.method
      local params = message and message.params or {}

      if method == "omniac/session_started" then
        changes.reset(params.sessionId)
        followup:close()
        followup = new_modified_approval()
        app.modified_approval = followup
        permission_approval:close()
        permission_approval = approval.new()
        app.permission_approval = permission_approval
      elseif method == "omniac/prompt_started" then
        changes.start_turn(params)
      end

      ui.handle_notification(message, cfg)

      if method == "omniac/permission_diff" then
        permission_approval:attach_acp_permission_diff(params)
        return
      end

      if method == "omniac/file_update" then
        changes.record(params)
        return
      end

      if method == "omniac/prompt_failed" then
        changes.finish_turn(params)
        followup:finish_turn(params)
        return
      end

      if method == "omniac/response" or method == "omniac/response_completed" then
        local count = changes.finish_turn(params)
        local review_mode = cfg.ui and cfg.ui.change_review or "summary"
        if count > 0 and review_mode == "open" then
          vim.schedule(function()
            changes.open("turn", cfg)
          end)
        elseif count > 0 and review_mode == "summary" then
          ui.set_activity(
            string.format("Changed %d file%s this turn\n[t] turn · [s] session", count, count == 1 and "" or "s"),
            cfg,
            { change_summary = true }
          )
        end
        followup:finish_turn(params)
        return
      end

      if method == "omniac/edit_failed" then
        return
      end

      if method == "omniac/error" then
        vim.notify(
          tostring(params.message or params.error or "omniac error"),
          vim.log.levels.ERROR,
          { title = "omniac error" }
        )
      elseif method == "omniac/warning" then
        vim.notify(tostring(params.message or "omniac warning"), vim.log.levels.WARN, { title = "omniac warning" })
      end
    end)
    :on_exit(function(code, signal)
      if client.closing or app.backend ~= client then
        return
      end

      if app.active_submission and app.active_submission.client == client then
        submission_failure(app.active_submission, "ACP agent exited before the prompt completed")
      end
      ui.set_status("closed", cfg)
      vim.notify(
        string.format("agent exited (code=%s, signal=%s)", tostring(code), tostring(signal)),
        vim.log.levels.WARN,
        { title = "omniac exit" }
      )
      app.backend = nil
      followup:close()
      permission_approval:close()
      app.modified_approval = nil
      app.permission_approval = nil
    end)

  app.backend = client:start()
  return app.backend
end

function M.disconnect(app)
  if app.permission_approval then
    app.permission_approval:close()
    app.permission_approval = nil
  end
  if app.modified_approval then
    app.modified_approval:close()
    app.modified_approval = nil
  end
  if app.backend then
    app.backend:close()
    app.backend = nil
  end
end

return M
