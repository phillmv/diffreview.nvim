local eq = require("diffview.tests.helpers").eq
local DiffHunk = require("diffview.review.diff_hunk")

describe("Review diff hunk", function()
  local left = {
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
  }
  local right = {
    "one",
    "TWO",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "FOURTEEN",
    "fifteen",
  }

  it("captures the hunk containing a line on either side", function()
    local left_hunk = DiffHunk.capture(left, right, "left", 2)
    local right_hunk = DiffHunk.capture(left, right, "right", 14)

    assert.matches("%-two", left_hunk)
    assert.matches("%+TWO", left_hunk)
    assert.matches("%-fourteen", right_hunk)
    assert.matches("%+FOURTEEN", right_hunk)
  end)

  it("does not attach comments outside a hunk", function()
    eq(nil, DiffHunk.capture(left, right, "right", 8))
  end)

  -- `vim.diff` terminates its output with a newline; the captured text is
  -- embedded in a fenced block, so a trailing blank line shows up there.
  it("does not leave a trailing blank line on the last hunk", function()
    local hunk = DiffHunk.capture(left, right, "right", 14)
    assert.is_truthy(hunk)

    local lines = vim.split(hunk, "\n", { plain = true })
    assert.not_equals("", lines[#lines])
    eq("", hunk:match("\n*$"))
  end)
end)
