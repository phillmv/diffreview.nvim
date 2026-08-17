local eq = require("diffview.tests.helpers").eq
local ReviewSelection = require("diffview.scene.views.review.selection").ReviewSelection

local commits = {
  { hash = "head", parent = "two" },
  { hash = "two", parent = "three" },
  { hash = "three", parent = "four" },
  { hash = "four", parent = "root" },
  { hash = "root" },
}

describe("ReviewSelection", function()
  it("defaults to current working-tree changes", function()
    local selection = ReviewSelection(commits, 0)
    local range = selection:range()

    eq(0, range.first)
    eq(0, range.last)
    eq("head", range.base)
    eq(true, range.current)
    eq(true, range.editable)
  end)

  it("selects a default suffix ending at HEAD", function()
    local selection = ReviewSelection(commits, 3)
    local range = selection:range()

    eq(0, range.first)
    eq(3, range.last)
    eq("head", range.newest.hash)
    eq("three", range.oldest.hash)
    eq("four", range.base)
    eq(false, range.current)
    eq(true, range.editable)
  end)

  it("normalizes a historical selection in either direction", function()
    local selection = ReviewSelection(commits, 1)
    selection:apply(4, 2)
    local range = selection:range()

    eq(2, range.first)
    eq(4, range.last)
    eq("two", range.newest.hash)
    eq("four", range.oldest.hash)
    eq("root", range.base)
    eq(false, range.editable)
  end)

  it("treats the HEAD commit without the working tree as historical", function()
    local selection = ReviewSelection(commits, 0)
    selection:apply(1)
    local range = selection:range()

    eq(1, range.first)
    eq(1, range.last)
    eq("head", range.newest.hash)
    eq("two", range.base)
    eq(false, range.current)
    eq(false, range.editable)
  end)

  it("tracks and cancels a pending range", function()
    local selection = ReviewSelection(commits, 2)
    selection:begin(2)

    local first, last = selection:pending(4)
    eq(2, first)
    eq(4, last)

    selection:cancel()
    first, last = selection:pending(5)
    eq(0, first)
    eq(2, last)
  end)
end)
