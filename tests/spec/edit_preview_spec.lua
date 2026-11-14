local preview = require("omniac.acp.edit_preview")

describe("replacement edit previews", function()
  local directory, path
  before_each(function()
    directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    path = directory .. "/file.txt"
    vim.fn.writefile({ "prefix", "old .* % value", "suffix" }, path)
  end)
  after_each(function()
    vim.fn.delete(directory, "rf")
  end)

  it("builds a whole-file preview from literal replacement strings without writing", function()
    local input = { file_path = "file.txt", old_string = "old .* % value", new_string = "new % text" }
    local result = preview.from_input(input, directory)
    assert.equals(vim.fs.normalize(path), result.path)
    assert.equals("prefix\nold .* % value\nsuffix\n", result.oldText)
    assert.equals("prefix\nnew % text\nsuffix\n", result.newText)
    assert.equals("old .* % value", vim.fn.readfile(path)[2])
    assert.equals("file.txt", input.file_path)
  end)

  it("requires explicit replace-all for repeated matches and supports deletion", function()
    vim.fn.writefile({ "repeat repeat" }, path)
    local input = { filePath = path, oldString = "repeat", newString = "" }
    assert.is_nil(preview.from_input(input))
    input.replaceAll = true
    assert.equals(" \n", preview.from_input(input).newText)
    input.oldString = "missing"
    assert.is_nil(preview.from_input(input))
  end)

  it("allows creating an absent file but does not invent insertions into existing content", function()
    local input = { path = directory .. "/new.txt", old_string = "", new_string = "created" }
    assert.equals("", preview.from_input(input).oldText)
    assert.equals("created", preview.from_input(input).newText)
    assert.equals(0, vim.fn.filereadable(input.path))
    input.path = path
    assert.is_nil(preview.from_input(input))
    input.old_string = nil
    assert.is_nil(preview.from_input(input))
    input.path = directory
    input.old_string = ""
    assert.is_nil(preview.from_input(input))
  end)

  it("retains otherwise unknown approval arguments in the permission body", function()
    local body = require("omniac.approval.request").body({
      toolCall = {
        kind = "edit",
        rawInput = { file_path = path, old_string = "old", new_string = "new", custom = true },
      },
    })
    assert.is_truthy(body:find(path, 1, true))
    assert.is_truthy(body:find('"old_string":"old"', 1, true))
    assert.is_truthy(body:find('"new_string":"new"', 1, true))
    assert.is_truthy(body:find('"custom":true', 1, true))
  end)
end)
