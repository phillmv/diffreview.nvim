require("diffview.bootstrap")

local assert = require("luassert")
local diffview = require("diffview")
local lib = require("diffview.lib")
local review = require("diffview.review.session")

local api = vim.api

local function git(dir, ...)
  local out = vim.fn.system({ "git", "-C", dir, ... })
  assert(vim.v.shell_error == 0, out)
  return vim.trim(out)
end

local function commit(dir, name, lines, message)
  vim.fn.writefile(lines, dir .. "/" .. name)
  git(dir, "add", ".")
  git(dir, "commit", "-qm", message)
end

---Wait until a view has loaded its first entry.
local function await_ready(view)
  assert(vim.wait(10000, function()
    return view.ready
      and view.cur_entry ~= nil
      and view.cur_layout:get_main_win().file:is_valid()
  end, 20), "the diff view did not finish opening")
end

---Wait until a specific entry is loaded and its buffers are live.
local function await_entry(view, path)
  assert(vim.wait(10000, function()
    return view.cur_entry ~= nil
      and view.cur_entry.path == path
      and view.cur_layout:get_main_win().file:is_valid()
  end, 20), "the view did not finish opening " .. path)
end

---Drive the floating editor: replace its contents, write, then close it.
local function write_editor(text)
  local bufnr = api.nvim_get_current_buf()
  local winid = api.nvim_get_current_win()

  assert.matches("diffview://review%-editor/", api.nvim_buf_get_name(bufnr))
  api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
  api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
  api.nvim_win_close(winid, false)
end

describe("Review sessions on a diff view", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "-q")
    git(dir, "config", "user.name", "Diffview Test")
    git(dir, "config", "user.email", "diffview@example.com")

    commit(dir, "example.txt", { "one", "unchanged" }, "first")
    commit(dir, "example.txt", { "two", "unchanged" }, "second")
    commit(dir, "example.txt", { "three", "unchanged" }, "third")
    commit(dir, "second.txt", { "alpha", "unchanged" }, "add second")

    -- Uncommitted changes, so the default `:DiffviewOpen` has entries.
    vim.fn.writefile({ "four", "unchanged" }, dir .. "/example.txt")
    vim.fn.writefile({ "beta", "unchanged" }, dir .. "/second.txt")
  end)

  after_each(function()
    for _, view in ipairs(vim.list_slice(lib.views, 1, #lib.views)) do
      pcall(function()
        view:close()
        lib.dispose_view(view)
      end)
    end
    vim.fn.delete(dir, "rf")
  end)

  ---Open a plain `:DiffviewOpen` and focus its main diff window.
  local function open(args)
    local view = assert(lib.diffview_open(args or { "-C" .. dir }))
    view:open()
    await_ready(view)

    local win = view.cur_layout:get_main_win()
    win:focus()
    api.nvim_win_set_cursor(win.id, { 1, 0 })

    return view, win
  end

  it("has no review session until one is asked for", function()
    local view = open()
    assert.is_nil(view.review_session)
    assert.is_nil(view.panel.session_panel)
  end)

  it("starts a session on demand from a plain diff view", function()
    local view = open()

    diffview.review_start({}, false)

    assert.is_truthy(view.review_session)
    assert.is_true(view.panel.session_panel:is_open())
    assert.equals(view, lib.get_current_view())
  end)

  it("auto-starts a session when commenting without one", function()
    local view, win = open()
    assert.is_nil(view.review_session)

    diffview.review_comment()
    write_editor("Please keep the previous value.")

    local session = assert(view.review_session)
    assert.equals(1, #session.comments)
    assert.equals("Please keep the previous value.", session.comments[1].body)
    assert.equals("example.txt", session.comments[1].location.path)
    assert.equals(1, session.comments[1].location.line)
    assert.matches("@@", session.comments[1].diff_hunk.text)

    local panel_lines = api.nvim_buf_get_lines(view.panel.session_panel.bufid, 0, -1, false)
    assert.matches("example.txt:1 %[R%] Please keep", panel_lines[5])

    local extmarks = api.nvim_buf_get_extmarks(
      win.file.bufnr,
      review.annotation_ns,
      0,
      -1,
      { details = true }
    )
    assert.equals(1, #extmarks)
    assert.matches("Comment: Please keep the previous value", extmarks[1][4].virt_text[1][1])
  end)

  it("edits the comment already on a line instead of adding another", function()
    local view, win = open()

    diffview.review_comment()
    write_editor("First take.")

    win:focus()
    api.nvim_win_set_cursor(win.id, { 1, 0 })
    diffview.review_comment()

    local bufnr = api.nvim_get_current_buf()
    assert.same({ "First take." }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
    write_editor("Second take.")

    assert.equals(1, #view.review_session.comments)
    assert.equals("Second take.", view.review_session.comments[1].body)
  end)

  -- Reopening is the case that needs `file_open_post`: the session is attached
  -- before any diff buffer exists, so the annotations can only be applied as
  -- each entry loads.
  it("annotates freshly loaded buffers when a draft is resumed in a new view", function()
    local view, win = open()

    diffview.review_comment()
    write_editor("Keep this line.")

    local review_id = view.review_session.review.review_id
    local old_bufnr = win.file.bufnr
    local function marks_on(bufnr)
      return api.nvim_buf_get_extmarks(bufnr, review.annotation_ns, 0, -1, { details = true })
    end

    assert.equals(1, #marks_on(old_bufnr))

    diffview.close()
    assert.is_nil(lib.get_current_view())

    -- The working-tree side is a real file buffer, so it outlives the view.
    -- Closing the view must have taken its annotations with it.
    assert.is_true(api.nvim_buf_is_valid(old_bufnr))
    assert.equals(0, #marks_on(old_bufnr))

    diffview.review_start({ "-C" .. dir }, false)
    local reopened = assert(lib.get_current_view())
    await_ready(reopened)
    await_entry(reopened, "example.txt")

    assert.equals(review_id, reopened.review_session.review.review_id)
    assert.equals(1, #reopened.review_session.comments)

    local marks = marks_on(reopened.cur_layout:get_main_win().file.bufnr)
    assert.equals(1, #marks)
    assert.matches("Comment: Keep this line", marks[1][4].virt_text[1][1])
  end)

  it("jumps to a comment from the session panel", function()
    local view = open()

    diffview.review_comment()
    write_editor("Keep this line.")

    local session = view.review_session
    view:set_file_by_path("second.txt", false, true)
    await_entry(view, "second.txt")

    session:goto_comment(session.comments[1])
    await_entry(view, "example.txt")

    local target = view.cur_layout:get_main_win()
    assert.equals("example.txt", target.file.path)
    assert.equals(1, api.nvim_win_get_cursor(target.id)[1])
  end)

  it("resumes the draft covering the same diff", function()
    local view = open()

    diffview.review_comment()
    write_editor("Keep this.")

    local review_id = view.review_session.review.review_id
    review.detach(view)
    assert.is_nil(view.review_session)

    diffview.review_start({}, false)
    assert.equals(review_id, view.review_session.review.review_id)
    assert.equals(1, #view.review_session.comments)
    assert.equals(1, #view.review_session.store:list_drafts())
  end)

  it("starts a fresh draft when forced", function()
    local view = open()

    diffview.review_start({}, false)
    local first = view.review_session.review.review_id

    diffview.review_start({}, true)
    assert.not_equals(first, view.review_session.review.review_id)
    assert.equals(2, #view.review_session.store:list_drafts())
  end)

  it("submits the review and leaves review mode", function()
    local view = open()

    diffview.review_comment()
    write_editor("Please keep the previous value.")

    diffview.review_submit()
    write_editor("Overall review.")

    assert.is_nil(view.review_session)
    assert.is_nil(view.panel.session_panel)

    local git_dir = git(dir, "rev-parse", "--absolute-git-dir")
    local markdown = table.concat(
      vim.fn.readfile(git_dir .. "/diffview-review/latest.md"),
      "\n"
    )
    assert.matches("Overall review", markdown)
    assert.matches("Please keep the previous value", markdown)
    assert.matches("@@ %-1,2 %+1,2 @@", markdown)
  end)

  describe("DiffviewReviewStart arguments", function()
    it("opens a diff view when none is running", function()
      assert.is_nil(lib.get_current_view())

      diffview.review_start({ "-C" .. dir }, false)

      local view = assert(lib.get_current_view())
      assert.is_truthy(view.review_session)
      assert.is_true(view.panel.session_panel:is_open())
    end)

    it("reuses the current view when the args resolve to the same diff", function()
      local view = open({ "-C" .. dir, "HEAD~1" })
      local tabs = #api.nvim_list_tabpages()

      diffview.review_start({ "-C" .. dir, "HEAD~1" }, false)

      assert.equals(tabs, #api.nvim_list_tabpages())
      assert.equals(view, lib.get_current_view())
      assert.is_truthy(view.review_session)
    end)

    it("opens a new view when the args resolve to a different diff", function()
      local view = open({ "-C" .. dir, "HEAD~1" })
      local tabs = #api.nvim_list_tabpages()

      diffview.review_start({ "-C" .. dir, "HEAD~2" }, false)

      assert.equals(tabs + 1, #api.nvim_list_tabpages())
      local new_view = assert(lib.get_current_view())
      assert.not_equals(view, new_view)
      assert.is_nil(view.review_session)
      assert.is_truthy(new_view.review_session)
    end)

    it("keeps drafts for different diffs apart", function()
      local view = open({ "-C" .. dir, "HEAD~1" })
      diffview.review_start({ "-C" .. dir, "HEAD~1" }, false)
      local first = view.review_session.review.review_id

      diffview.review_start({ "-C" .. dir, "HEAD~2" }, false)
      local second_view = assert(lib.get_current_view())
      local second = second_view.review_session.review.review_id

      assert.not_equals(first, second)

      -- Going back to the original range resumes the original draft.
      diffview.review_start({ "-C" .. dir, "HEAD~1" }, false)
      assert.equals(first, assert(lib.get_current_view()).review_session.review.review_id)
    end)
  end)
end)
