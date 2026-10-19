local M = {}

function M.summary(attachments)
  if #(attachments or {}) == 0 then
    return nil
  end
  local parts = {}
  for index, attachment in ipairs(attachments) do
    if attachment.type == "reference" then
      local path = attachment.path
      if not path or path == "" then
        path = "[No Name]"
      else
        path = vim.fn.fnamemodify(path, ":t")
      end
      local label = attachment.pathOnly and "file" or "ref"
      if attachment.startLine and attachment.endLine then
        table.insert(parts, string.format("%s: %s:%d-%d", label, path, attachment.startLine, attachment.endLine))
      else
        table.insert(parts, string.format("%s: %s", label, path))
      end
    else
      local size = attachment.byteSize and string.format(" %.1fKB", attachment.byteSize / 1024) or ""
      table.insert(parts, string.format("image %d: %s%s", index, attachment.mimeType or "image", size))
    end
  end
  return table.concat(parts, ", ")
end

function M.marker(state, attachment)
  if attachment._input_marker then
    return attachment._input_marker
  end
  state.next_attachment_id = state.next_attachment_id + 1
  local kind = attachment.type == "image" and "Image" or "Reference"
  attachment._input_marker = string.format("[%s %d]", kind, state.next_attachment_id)
  return attachment._input_marker
end

function M.ranges(state, line)
  local ranges = {}
  for _, attachment in ipairs(state.input_attachments) do
    local marker = attachment._input_marker
    if marker then
      local from = 1
      while true do
        local start_col, end_col = line:find(marker, from, true)
        if not start_col then
          break
        end
        table.insert(ranges, { from = start_col - 1, to = end_col, attachment = attachment })
        from = end_col + 1
      end
    end
  end
  table.sort(ranges, function(left, right)
    return left.from < right.from
  end)
  return ranges
end

function M.prune(state, lines)
  local value = table.concat(lines or {}, "\n")
  local retained = {}
  for _, attachment in ipairs(state.input_attachments) do
    if attachment._input_marker and value:find(attachment._input_marker, 1, true) then
      table.insert(retained, attachment)
    end
  end
  state.input_attachments = retained
end

function M.clear(state)
  state.input_attachments = {}
end

function M.prepare(state, source)
  local occurrences = {}
  for _, attachment in ipairs(state.input_attachments) do
    local marker = attachment._input_marker
    local from = marker and source:find(marker, 1, true) or nil
    if from then
      table.insert(occurrences, { from = from, to = from + #marker - 1, attachment = attachment })
    end
  end
  table.sort(occurrences, function(left, right)
    return left.from < right.from
  end)

  local clean = {}
  local prepared = {}
  local cursor = 1
  local clean_length = 0
  for _, occurrence in ipairs(occurrences) do
    local preceding = source:sub(cursor, occurrence.from - 1)
    table.insert(clean, preceding)
    clean_length = clean_length + #preceding
    local attachment = vim.deepcopy(occurrence.attachment)
    attachment._position = clean_length
    attachment._order = #prepared + 1
    table.insert(prepared, attachment)
    cursor = occurrence.to + 1
  end
  table.insert(clean, source:sub(cursor))
  return table.concat(clean), prepared
end

function M.insert(state, attachment, lines, cursor)
  attachment = vim.deepcopy(attachment)
  local marker = M.marker(state, attachment)
  table.insert(state.input_attachments, attachment)
  local line_index = math.min(math.max(cursor.line, 1), #lines)
  local line = lines[line_index] or ""
  local col = math.min(math.max(cursor.col, 0), #line)
  lines[line_index] = line:sub(1, col) .. marker .. line:sub(col + 1)
  return lines, { line = line_index, col = col + #marker }
end

function M.restore(state, value, attachments)
  state.input_attachments = vim.deepcopy(attachments or {})
  table.sort(state.input_attachments, function(left, right)
    if (left._position or math.huge) == (right._position or math.huge) then
      return (left._order or 0) < (right._order or 0)
    end
    return (left._position or math.huge) < (right._position or math.huge)
  end)
  local restored = value or ""
  for index = #state.input_attachments, 1, -1 do
    local attachment = state.input_attachments[index]
    local marker = M.marker(state, attachment)
    local position = math.min(math.max(attachment._position or #restored, 0), #restored)
    restored = restored:sub(1, position) .. marker .. restored:sub(position + 1)
  end
  return restored
end

return M
