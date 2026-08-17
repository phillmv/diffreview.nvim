require("diffview.bootstrap")

local eq = require("diffview.tests.helpers").eq
local ReviewSelection = require("diffview.scene.views.review.selection").ReviewSelection
local ReviewView = require("diffview.scene.views.review.review_view").ReviewView
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType

local commits = {
  { hash = "head", parent = "two" },
  { hash = "two", parent = "root" },
  { hash = "root" },
}

local refreshed = {
  { hash = "new-head", parent = "head" },
  unpack(commits),
}

local function make_view(selection)
  local calls = {}
  local commit_panel = {}
  for _, method in ipairs({ "update_components", "render", "redraw", "highlight_selection" }) do
    commit_panel[method] = function()
      calls[method] = (calls[method] or 0) + 1
    end
  end

  local view = {
    adapter = {
      Rev = GitRev,
      review_commits = function(_, max_count, include_hash)
        calls.max_count = max_count
        calls.include_hash = include_hash
        return nil, refreshed
      end,
    },
    selection = selection,
    panel = {
      commit_panel = commit_panel,
    },
    selection_revisions = function(self)
      return ReviewView.selection_revisions(self)
    end,
    update_files = function()
      calls.update_files = (calls.update_files or 0) + 1
    end,
    set_revisions = function(_, left, right, label)
      calls.set_revisions = { left = left, right = right, label = label }
    end,
  }

  return view, calls
end

describe("ReviewView refresh", function()
  it("preserves an editable boundary and updates files in place", function()
    local view, calls = make_view(ReviewSelection(commits, 1))
    view.left = GitRev(RevType.COMMIT, "two")
    view.right = GitRev(RevType.LOCAL)

    ReviewView.refresh(view)

    eq("head", calls.include_hash)
    eq(1, calls.update_files)
    eq(nil, calls.set_revisions)
    eq(1, calls.update_components)
    eq(0, view.selection.first)
    eq(2, view.selection.last)
    eq("new-head", view.selection:range().newest.hash)
  end)

  it("moves a current-changes review to the new HEAD", function()
    local view, calls = make_view(ReviewSelection(commits, 0))
    view.left = GitRev(RevType.COMMIT, "head")
    view.right = GitRev(RevType.LOCAL)

    ReviewView.refresh(view)

    eq(nil, calls.include_hash)
    eq(nil, calls.update_files)
    eq("new-head", calls.set_revisions.left.commit)
    eq(RevType.LOCAL, calls.set_revisions.right.type)
    eq("HEAD..WORKING TREE", calls.set_revisions.label)
  end)
end)
