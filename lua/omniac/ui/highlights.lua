local M = {}

local definitions = {
  OmniacTitle = { fg = "#f38ba8", bold = true },
  OmniacBorder = { fg = "#f38ba8" },
  OmniacMuted = { fg = "#7f849c" },
  OmniacAccent = { fg = "#f9e2af", bold = true },
  OmniacGraphic = { fg = "#e7825a", bold = true },
  OmniacGraphicShade = { fg = "#94e2d5", bold = true },
  OmniacGraphicCoralOverMint = { fg = "#e7825a", bg = "#94e2d5" },
  OmniacGraphicMintOverCoral = { fg = "#94e2d5", bg = "#e7825a" },
  OmniacWordmark = { fg = "#f9e2af", bold = true, italic = true },
  OmniacUser = { fg = "#89b4fa", bold = true },
  OmniacUserBubble = { fg = "#cdd6f4", bg = "#313244" },
  OmniacAssistant = { fg = "#cba6f7", bold = true },
  OmniacAssistantText = { fg = "#cdd6f4" },
  OmniacCode = { fg = "#a6e3a1" },
  OmniacToolSummary = { fg = "#89dceb", bold = true },
  OmniacToolOutput = { fg = "#cdd6f4" },
  OmniacError = { fg = "#f38ba8", bold = true },
  OmniacPermissionPending = { fg = "#f9e2af", bold = true },
  OmniacPermissionApproved = { fg = "#a6e3a1", bold = true },
  OmniacPermissionRejected = { fg = "#f38ba8", bold = true },
  OmniacWorking1 = { fg = "#585b70", bold = true },
  OmniacWorking2 = { fg = "#7f849c", bold = true },
  OmniacWorking3 = { fg = "#cba6f7", bold = true },
  OmniacWorking4 = { fg = "#f5c2e7", bold = true },
  OmniacShortcut = { fg = "#11111b", bg = "#a6e3a1", bold = true },
  OmniacInput = { bg = "#313244" },
  OmniacInputText = { fg = "#cdd6f4", bg = "#313244" },
  OmniacInputPrompt = { fg = "#89b4fa", bg = "#313244", bold = true },
  OmniacAttachment = { fg = "#89b4fa", bg = "#313244", bold = true },
  OmniacStatusMode = { fg = "#11111b", bg = "#f38ba8", bold = true },
  OmniacStatus = { fg = "#cdd6f4", bg = "#313244" },
  OmniacStatusCapsule = { fg = "#11111b", bg = "#94e2d5", bold = true },
  OmniacStatusCapsuleEdge = { fg = "#94e2d5", bold = true },
  OmniacStatusModeEdge = { fg = "#f38ba8", bold = true },
  OmniacStatusCapsuleAlt = { fg = "#cdd6f4", bg = "#45475a", bold = true },
  OmniacStatusCapsuleAltEdge = { fg = "#45475a", bold = true },
  OmniacStatusPlan = { fg = "#11111b", bg = "#cba6f7", bold = true },
  OmniacStatusPlanEdge = { fg = "#cba6f7", bold = true },
  OmniacStatusUsage = { fg = "#11111b", bg = "#89b4fa", bold = true },
  OmniacStatusUsageEdge = { fg = "#89b4fa", bold = true },
  OmniacCommandName = { fg = "#89b4fa", bold = true },
  OmniacCommandClientName = { fg = "#a6e3a1", bold = true },
  OmniacCommandText = { fg = "#cdd6f4" },
  OmniacCommandMuted = { fg = "#7f849c" },
  OmniacSessionBorder = { fg = "#f38ba8" },
  OmniacSessionTitle = { fg = "#f9e2af", bold = true },
  OmniacSessionText = { fg = "#cdd6f4" },
  OmniacSessionMuted = { fg = "#7f849c" },
  OmniacSessionSelected = { fg = "#11111b", bg = "#94e2d5", bold = true },
  OmniacSessionKey = { fg = "#89b4fa", bold = true },
  OmniacChangeBorder = { fg = "#f38ba8" },
  OmniacChangeTitle = { fg = "#f9e2af", bold = true },
  OmniacChangeText = { fg = "#cdd6f4" },
  OmniacChangeMuted = { fg = "#7f849c" },
  OmniacChangeSelected = { fg = "#11111b", bg = "#94e2d5", bold = true },
  OmniacChangeKey = { fg = "#89b4fa", bold = true },
  OmniacPermissionBorder = { fg = "#f38ba8" },
  OmniacPermissionTitle = { fg = "#f9e2af", bold = true },
  OmniacPermissionText = { fg = "#cdd6f4" },
  OmniacPermissionMuted = { fg = "#7f849c" },
  OmniacPermissionSelected = { fg = "#11111b", bg = "#94e2d5", bold = true },
}

local function theme_definitions()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local background = normal.bg or (vim.o.background == "light" and 0xffffff or 0x1e1e2e)
  local foreground = normal.fg or (vim.o.background == "light" and 0x202020 or 0xcdd6f4)
  local function shade(amount)
    local color = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
      local base = math.floor(background / 2 ^ shift) % 256
      local target = math.floor(foreground / 2 ^ shift) % 256
      color = color + math.floor(base + (target - base) * amount) * 2 ^ shift
    end
    return color
  end
  return {
    OmniacNormal = { link = "Normal" },
    OmniacSeparator = { fg = shade(0.18), bg = normal.bg },
    OmniacPlanSummary = { fg = foreground, bg = shade(0.12), bold = true },
    OmniacPlanDetail = { fg = foreground, bg = shade(0.04) },
  }
end

function M.setup(prefix)
  local dynamic = theme_definitions()
  for name, definition in pairs(dynamic) do
    if not prefix or name:sub(1, #prefix) == prefix then
      vim.api.nvim_set_hl(0, name, definition)
    end
  end
  for name, definition in pairs(definitions) do
    if not prefix or name:sub(1, #prefix) == prefix then
      vim.api.nvim_set_hl(0, name, definition)
    end
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("OmniacHighlights", { clear = true }),
  callback = function()
    M.setup()
  end,
})

return M
