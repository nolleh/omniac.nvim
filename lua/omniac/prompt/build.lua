local mentions = require("omniac.editor.mentions")

local M = {}

function M.text(extra)
  local parts = {}
  if extra and extra ~= "" then
    table.insert(parts, extra)
  end
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname ~= "" and bufname ~= "omniac" and not bufname:match("^omniac://") then
    table.insert(parts, "Current file: " .. bufname)
  end
  return table.concat(parts, "\n\n")
end

local function reference_label(reference)
  local path = reference.path
  if not path or path == "" then
    path = "[No Name]"
  else
    path = vim.fn.fnamemodify(path, ":.")
  end
  if reference.startLine and reference.endLine then
    return string.format("%s:%d-%d", path, reference.startLine, reference.endLine)
  end
  return path
end

local function append_attachment(items, attachment, supports_embedded_context)
  if type(attachment) ~= "table" then
    return
  end
  if attachment.type == "image" then
    table.insert(items, { type = "image", mimeType = attachment.mimeType, data = attachment.data })
    return
  end
  if attachment.type ~= "reference" then
    return
  end

  if attachment.pathOnly then
    local filename = vim.fn.fnamemodify(attachment.path, ":t")
    local instruction = string.format("Please inspect the referenced file: %s.", reference_label(attachment))
    local description = "Source file reference."
    if attachment.startLine and attachment.endLine then
      instruction = string.format(
        "Please inspect lines %d-%d in %s.",
        attachment.startLine,
        attachment.endLine,
        reference_label(attachment)
      )
      description = string.format("Source file reference, lines %d-%d.", attachment.startLine, attachment.endLine)
    end
    table.insert(items, { type = "text", text = instruction })
    table.insert(items, {
      type = "resource_link",
      uri = attachment.uri,
      name = filename ~= "" and filename or "[No Name]",
      title = reference_label(attachment),
      mimeType = "text/plain",
      description = description,
    })
    return
  end

  table.insert(items, {
    type = "text",
    text = string.format(
      "Please inspect this selected buffer content from %s (unsaved buffer contents are included below).",
      reference_label(attachment)
    ),
  })
  if supports_embedded_context then
    table.insert(items, {
      type = "resource",
      resource = { uri = attachment.uri, mimeType = "text/plain", text = attachment.text },
    })
  else
    table.insert(items, {
      type = "text",
      text = string.format("Referenced code from %s:\n%s", reference_label(attachment), attachment.text or ""),
    })
  end
end

function M.items(text, attachments, supports_embedded_context)
  local items = {}
  local positioned = {}
  local trailing = {}
  for index, attachment in ipairs(attachments or {}) do
    if type(attachment) == "table" and type(attachment._position) == "number" then
      attachment._order = attachment._order or index
      table.insert(positioned, attachment)
    else
      table.insert(trailing, attachment)
    end
  end
  table.sort(positioned, function(left, right)
    if left._position == right._position then
      return (left._order or 0) < (right._order or 0)
    end
    return left._position < right._position
  end)

  local cursor = 1
  for _, attachment in ipairs(positioned) do
    local position = math.min(math.max(attachment._position, 0), #text)
    local segment = text:sub(cursor, position)
    if segment ~= "" then
      table.insert(items, { type = "text", text = segment })
    end
    append_attachment(items, attachment, supports_embedded_context)
    cursor = position + 1
  end
  local remainder = text:sub(cursor)
  if remainder ~= "" then
    table.insert(items, { type = "text", text = remainder })
  end
  for _, attachment in ipairs(trailing) do
    append_attachment(items, attachment, supports_embedded_context)
  end
  if #items == 0 then
    table.insert(items, { type = "text", text = text })
  end
  return items
end

function M.with_files(extra, paths)
  local result = M.text(extra)
  local file_mentions = mentions.collect(paths)
  if #file_mentions > 0 then
    result = result .. "\n\nFiles:\n" .. table.concat(file_mentions, "\n")
  end
  return result
end

return M
