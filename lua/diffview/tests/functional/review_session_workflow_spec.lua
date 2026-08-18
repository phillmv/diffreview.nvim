require("diffview.bootstrap")

local assert = require("luassert")
local lib = require("diffview.lib")

local function git(dir, ...)
  local out = vim.fn.system({ "git", "-C", dir, ... })
  assert(vim.v.shell_error == 0, out)
  return vim.trim(out)
end

describe("DiffviewReview session workflow", function()
  local dir
  local view

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "-q")
    git(dir, "config", "user.name", "Diffview Test")
    git(dir, "config", "user.email", "diffview@example.com")
    vim.fn.writefile({ "before", "unchanged" }, dir .. "/example.txt")
    git(dir, "add", ".")
    git(dir, "commit", "-qm", "initial")
    vim.fn.writefile({ "after", "unchanged" }, dir .. "/example.txt")
  end)

  after_each(function()
    if view and view:is_valid() then
      view:close()
      lib.dispose_view(view)
    end
    vim.fn.delete(dir, "rf")
  end)

  it("starts, annotates, and submits a review", function()
    view = assert(lib.review({ "-C" .. dir }))
    view:open()

    assert(vim.wait(5000, function()
      return view.ready
        and view.cur_entry
        and view.cur_layout:get_main_win().file:is_valid()
    end, 20), "review view did not finish opening")

    view:start_review()
    assert.is_truthy(view.review_session)
    assert.is_true(view.panel.session_panel:is_open())
    assert.is_false(view.panel.commit_panel:is_open())

    local diff_win = view.cur_layout:get_main_win()
    diff_win:focus()
    vim.api.nvim_win_set_cursor(diff_win.id, { 1, 0 })
    view:comment()

    local comment_buf = vim.api.nvim_get_current_buf()
    local comment_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(comment_buf, 0, -1, false, {
      "Please keep the previous value.",
    })
    vim.api.nvim_buf_call(comment_buf, function()
      vim.cmd("write")
    end)
    vim.api.nvim_win_close(comment_win, false)

    assert.equals(1, #view.review_session.comments)
    local review_id = view.review_session.review.review_id
    local panel_lines = vim.api.nvim_buf_get_lines(
      view.panel.session_panel.bufid,
      0,
      -1,
      false
    )
    assert.matches("example.txt:1 %[R%] Please keep", panel_lines[5])

    local extmarks = vim.api.nvim_buf_get_extmarks(
      diff_win.file.bufnr,
      vim.api.nvim_create_namespace("diffview_review_comments"),
      0,
      -1,
      { details = true }
    )
    assert.equals(1, #extmarks)
    assert.matches(
      "Comment: Please keep the previous value",
      extmarks[1][4].virt_text[1][1]
    )

    view:leave_review()
    view:start_review()
    assert.equals(review_id, view.review_session.review.review_id)
    assert.equals(1, #view.review_session.comments)
    assert.equals(1, #view.review_store:list_drafts())

    view:open_submit_editor()
    local submit_buf = vim.api.nvim_get_current_buf()
    local submit_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(submit_buf, 0, -1, false, {
      "Overall review.",
    })
    vim.api.nvim_buf_call(submit_buf, function()
      vim.cmd("write")
    end)
    vim.api.nvim_win_close(submit_win, false)

    assert.is_nil(view.review_session)
    assert.is_true(view.panel.commit_panel:is_open())
    local git_dir = git(dir, "rev-parse", "--absolute-git-dir")
    local markdown = table.concat(vim.fn.readfile(
      git_dir .. "/diffview-review/latest.md"
    ), "\n")
    assert.matches("Overall review", markdown)
    assert.matches("Please keep the previous value", markdown)
    assert.matches("@@ %-1,2 %+1,2 @@", markdown)
  end)

  it("opens DiffviewReview when starting outside a review view", function()
    require("diffview").review_start({ "-C" .. dir }, false)
    view = assert(lib.get_current_view())

    assert(vim.wait(5000, function()
      return view.ready and view.review_session ~= nil
    end, 20), "review session did not finish opening")

    assert.is_truthy(view.review_session)
    assert.is_true(view.panel.session_panel:is_open())
    assert.is_false(view.panel.commit_panel:is_open())

    local first_id = view.review_session.review.review_id
    view:start_review(true)
    assert.not_equals(first_id, view.review_session.review.review_id)
    assert.equals(2, #view.review_store:list_drafts())
  end)
end)
