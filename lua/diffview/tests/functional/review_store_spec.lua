local eq = require("diffview.tests.helpers").eq
local ReviewStore = require("diffview.review.store").ReviewStore

local A = string.rep("a", 40)
local B = string.rep("b", 40)

describe("ReviewStore", function()
  local root
  local store

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store = ReviewStore(root)
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  local function scope(opt)
    opt = opt or {}
    return {
      label = "aaaaaaa..WORKING TREE",
      toplevel = opt.toplevel or "/repo",
      left = { kind = "commit", oid = opt.oid or A },
      right = { kind = "local" },
      path_args = opt.path_args or {},
    }
  end

  it("retains earlier drafts when creating another", function()
    local first = assert(store:create(scope()))
    local second = assert(store:create(scope()))

    local drafts = store:list_drafts()
    eq(2, #drafts)
    eq(second.review_id, drafts[1].review_id)
    eq(first.review_id, drafts[2].review_id)
  end)

  describe("find_draft()", function()
    it("finds a draft covering the same scope", function()
      local review = assert(store:create(scope()))
      local found = assert(store:find_draft(scope()))

      eq(review.review_id, found.review_id)
    end)

    it("ignores drafts covering a different scope", function()
      assert(store:create(scope()))

      eq(nil, store:find_draft(scope({ oid = B })))
      eq(nil, store:find_draft(scope({ path_args = { "lua" } })))
      eq(nil, store:find_draft(scope({ toplevel = "/other" })))
    end)

    it("returns the most recent matching draft", function()
      assert(store:create(scope()))
      local second = assert(store:create(scope()))

      eq(second.review_id, store:find_draft(scope()).review_id)
    end)

    it("ignores submitted reviews", function()
      local review = assert(store:create(scope()))
      assert(store:submit(review, "Done."))

      eq(nil, store:find_draft(scope()))
    end)
  end)

  it("persists comments independently and renders a submission", function()
    local review = assert(store:create(scope()))
    local first = {
      body = "Use the asynchronous API.",
      location = {
        path = "lua/review.lua",
        side = "right",
        line = 12,
        selected_text = "local value = sync()",
        content_oid = "sha256:abc",
      },
      diff_hunk = {
        format = "unified",
        context_lines = 3,
        text = "@@ -12 +12 @@\n-local value = old()\n+local value = sync()",
      },
    }
    local second = {
      body = "Keep the old name.",
      location = {
        path = "lua/review.lua",
        side = "left",
        line = 4,
        selected_text = "local old_name",
        content_oid = "sha256:def",
      },
      diff_hunk = {
        format = "unified",
        context_lines = 3,
        text = "@@ -4 +4 @@\n-local old_name\n+local new_name",
      },
    }

    assert(store:save_comment(review, first))
    assert(store:save_comment(review, second))
    local comments = assert(store:load_comments(review))
    eq(2, #comments)
    assert.not_equals(comments[1].comment_id, comments[2].comment_id)

    local submitted = assert(store:submit(review, "Overall review body."))
    eq("submitted", submitted.state)
    eq(false, vim.loop.fs_stat(store:review_dir("draft", review.review_id)) ~= nil)
    eq(true, vim.loop.fs_stat(store:review_dir("submitted", review.review_id)) ~= nil)

    local markdown = table.concat(vim.fn.readfile(
      store:review_dir("submitted", review.review_id) .. "/review.md"
    ), "\n")
    assert.matches("# Submitted Diffview Review", markdown)
    assert.matches("Range: `aaaaaaaaa%.%.WORKING TREE`", markdown)
    assert.matches("Overall review body", markdown)
    assert.matches("### Left line 4", markdown)
    assert.matches("### Right line 12", markdown)
    assert.matches("```diff", markdown)
    assert.matches("Use the asynchronous API", markdown)
    eq(markdown, table.concat(vim.fn.readfile(store.root .. "/latest.md"), "\n"))
  end)

  it("re-saving a comment updates it in place", function()
    local review = assert(store:create(scope()))
    local comment = {
      body = "First take.",
      location = { path = "a.lua", side = "right", line = 1 },
      diff_hunk = { format = "unified", context_lines = 3, text = "@@ -1 +1 @@" },
    }

    assert(store:save_comment(review, comment))
    comment.body = "Second take."
    assert(store:save_comment(review, comment))

    local comments = assert(store:load_comments(review))
    eq(1, #comments)
    eq("Second take.", comments[1].body)
  end)

  it("updates the latest review without removing earlier submissions", function()
    local first = assert(store:create(scope()))
    assert(store:submit(first, "First review."))

    local second = assert(store:create(scope()))
    assert(store:submit(second, "Second review."))

    eq(true, vim.loop.fs_stat(store:review_dir("submitted", first.review_id)) ~= nil)
    eq(true, vim.loop.fs_stat(store:review_dir("submitted", second.review_id)) ~= nil)
    local latest = table.concat(vim.fn.readfile(store.root .. "/latest.md"), "\n")
    assert.matches("Second review", latest)
    assert.not_matches("First review", latest)
  end)
end)
