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
}

function M.setup()
  for name, definition in pairs(definitions) do
    vim.api.nvim_set_hl(0, name, definition)
  end
end

return M
