local assert = require("luassert")
local ReviewCommitPanel = require("diffview.scene.views.review.commit_panel").ReviewCommitPanel
local ReviewSelection = require("diffview.scene.views.review.selection").ReviewSelection

local commits = {
  { hash = "head", parent = "two", subject = "head" },
  { hash = "two", parent = "three", subject = "two" },
  { hash = "three", parent = "root", subject = "three" },
}

describe("ReviewCommitPanel", function()
  local panel

  after_each(function()
    if panel then
      panel:destroy()
      panel = nil
    end
  end)

  it("renders a pending range from its anchor to the cursor", function()
    local selection = ReviewSelection(commits, 0)
    panel = ReviewCommitPanel({ winid = vim.api.nvim_get_current_win() }, selection)
    panel:open()
    panel:highlight_selection()
    panel:focus()

    panel:move_cursor(1)
    selection:begin(panel:get_index_at_cursor())
    panel:move_cursor(1)

    local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
    local rendered = table.concat(lines, "\n")
    assert.matches("%[READ ONLY%]", lines[1])
    assert.equals("<CR>: apply  <Esc>: cancel", lines[2])
    assert.matches("\n @ head", rendered)
    assert.matches("\n%+  two", rendered)
    assert.matches("\n%+  three", rendered)
  end)
end)
