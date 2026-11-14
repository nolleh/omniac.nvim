local attachments = require("omniac.ui.chat.attachments")

describe("history image attachment display", function()
  it("handles every possible split without displaying the image payload", function()
    local value = "Before [@image](data:image/png;base64,ABC123==) after"
    for split = 0, #value do
      local state = {}
      local first = attachments.push(state, value:sub(1, split))
      local second = attachments.push(state, value:sub(split + 1))
      assert.equals("Before [Image attachment] after", first .. second .. attachments.push(state, "", true))
    end
  end)

  it("discards large payloads immediately across many chunks", function()
    local state = {}
    assert.equals("[Image attachment]", attachments.push(state, "[@image](data:image/png;base64,"))
    for _ = 1, 20 do
      assert.equals("", attachments.push(state, string.rep("A", 100000)))
      assert.equals("", state.pending)
    end
    assert.equals(
      " caption [Image attachment]",
      attachments.push(state, ") caption [@image](data:image/jpeg;base64,BBB)")
    )
  end)

  it("preserves ordinary links and flushes incomplete prefixes", function()
    local state = {}
    local value = "[docs](https://example.com) [@image](file:///tmp/image.png) [@ima"
    local shown = attachments.push(state, value)
    assert.equals(value, shown .. attachments.push(state, "", true))
  end)
end)
