local M = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
  if vim.base64 and vim.base64.encode then
    return vim.base64.encode(data)
  end

  return (
    (data:gsub(".", function(char)
      local byte = char:byte()
      local bits = {}
      for index = 8, 1, -1 do
        bits[#bits + 1] = byte % 2 ^ index - byte % 2 ^ (index - 1) > 0 and "1" or "0"
      end
      return table.concat(bits)
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
      if #bits < 6 then
        return ""
      end
      local value = 0
      for index = 1, 6 do
        if bits:sub(index, index) == "1" then
          value = value + 2 ^ (6 - index)
        end
      end
      return b64chars:sub(value + 1, value + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1]
  )
end

local function read_file(path)
  local fd = vim.loop.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.loop.fs_fstat(fd)
  if not stat then
    vim.loop.fs_close(fd)
    return nil
  end
  local data = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)
  return data
end

local function temp_path(extension)
  return vim.fn.tempname() .. extension
end

local function osascript_escape(value)
  return tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function read_macos_image()
  if vim.fn.has("mac") ~= 1 then
    return nil, "image clipboard paste is only implemented for macOS"
  end
  if vim.fn.executable("osascript") ~= 1 then
    return nil, "osascript is required to read image clipboard data"
  end

  local candidates = {
    { mime_type = "image/png", extension = ".png", apple_type = "«class PNGf»" },
    { mime_type = "image/jpeg", extension = ".jpg", apple_type = "«class JPEG»" },
  }

  for _, candidate in ipairs(candidates) do
    local path = temp_path(candidate.extension)
    local script = {
      "-e",
      'set outputPath to "' .. osascript_escape(path) .. '"',
      "-e",
      "try",
      "-e",
      "set imageData to the clipboard as " .. candidate.apple_type,
      "-e",
      "set outputFile to open for access (POSIX file outputPath) with write permission",
      "-e",
      "set eof outputFile to 0",
      "-e",
      "write imageData to outputFile",
      "-e",
      "close access outputFile",
      "-e",
      'return "ok"',
      "-e",
      "on error",
      "-e",
      "try",
      "-e",
      "close access (POSIX file outputPath)",
      "-e",
      "end try",
      "-e",
      'return "no"',
      "-e",
      "end try",
    }
    local result = vim.fn.system({ "osascript", unpack(script) })
    if vim.v.shell_error == 0 and tostring(result):match("ok") then
      local data = read_file(path)
      pcall(vim.loop.fs_unlink, path)
      if data and data ~= "" then
        return {
          type = "image",
          mimeType = candidate.mime_type,
          data = base64_encode(data),
          byteSize = #data,
        }
      end
    else
      pcall(vim.loop.fs_unlink, path)
    end
  end

  return nil, "clipboard does not contain a PNG or JPEG image"
end

function M.read_image()
  return read_macos_image()
end

function M._base64_encode(data)
  return base64_encode(data or "")
end

return M
