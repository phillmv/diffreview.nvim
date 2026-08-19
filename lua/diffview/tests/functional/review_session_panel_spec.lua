local assert = require("luassert")
local ReviewSessionPanel = require("diffview.review.session_panel").ReviewSessionPanel

describe("ReviewSessionPanel", function()
  local panel

  after_each(function()
    if panel then
      panel:destroy()
      panel = nil
    end
  end)

  it("renders actions and refreshes its comment list", function()
    panel = ReviewSessionPanel({ winid = vim.api.nvim_get_current_win() })
    panel.session = {
      review = { review_id = "20260818T150000.000Z" },
      comments = {},
    }
    panel:open()

    local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
    assert.matches("Review Session 20260818T150000.000Z", lines[1])
    assert.equals("[s] Submit review", lines[2])
    assert.equals("[q] Leave review mode", lines[3])
    assert.matches("Comments %(0%)", lines[4])

    panel:set_session({
      review = { review_id = "20260818T150000.000Z" },
      comments = {
        {
          body = "Use the async API.",
          location = {
            path = "lua/review.lua",
            line = 42,
            side = "right",
          },
        },
      },
    })

    lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
    assert.matches("Comments %(1%)", lines[4])
    assert.matches("lua/review.lua:42 %[R%] Use the async API", lines[5])

    vim.api.nvim_win_set_cursor(panel.winid, { 5, 0 })
    local item = panel:get_item_at_cursor()
    assert.equals("comment", item.kind)
    assert.equals(42, item.comment.location.line)
  end)

  it("resolves the action items under the cursor", function()
    panel = ReviewSessionPanel({ winid = vim.api.nvim_get_current_win() })
    panel.session = { review = { review_id = "x" }, comments = {} }
    panel:open()

    vim.api.nvim_win_set_cursor(panel.winid, { 2, 0 })
    assert.equals("submit", panel:get_item_at_cursor().action)

    vim.api.nvim_win_set_cursor(panel.winid, { 3, 0 })
    assert.equals("leave", panel:get_item_at_cursor().action)
  end)
end)
