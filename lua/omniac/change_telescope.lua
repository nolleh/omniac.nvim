local M = {}

local labels = { add = "A", copy = "C", delete = "D", modify = "M", move = "R" }

function M.available()
  return pcall(require, "telescope.pickers")
end

function M.open(items, opts, callback)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values

  opts = opts or {}
  pickers
    .new({}, {
      prompt_title = "Omniac changes: " .. (opts.scope or "turn"),
      default_selection_index = opts.selected or 1,
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          local path = vim.fn.fnamemodify(item.path, ":.")
          return {
            value = item,
            display = (labels[item.operation] or "M") .. "  " .. path,
            ordinal = path,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          local item = entry.value
          local patch = vim.diff(item.oldText, item.newText, {
            result_type = "unified",
            ctxlen = 3,
          })
          local lines = {
            "--- a/" .. item.path,
            "+++ b/" .. item.path,
          }
          vim.list_extend(lines, vim.split(patch, "\n", { trimempty = true, plain = true }))
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "diff"
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        local function choose(action)
          local selected = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selected and callback then
            for index, item in ipairs(items) do
              if item == selected.value then
                callback(item, index, action)
                break
              end
            end
          end
        end
        actions.select_default:replace(function()
          choose("review")
        end)
        map("i", "<C-e>", function()
          choose("edit")
        end)
        map("n", "<C-e>", function()
          choose("edit")
        end)
        return true
      end,
    })
    :find()
end

return M
