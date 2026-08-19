local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local DiffHunk = lazy.require("diffview.review.diff_hunk") ---@module "diffview.review.diff_hunk"
local Editor = lazy.require("diffview.review.editor") ---@module "diffview.review.editor"
local ReviewStore = lazy.access("diffview.review.store", "ReviewStore") ---@type ReviewStore|LazyModule
local scope_lib = lazy.require("diffview.review.scope") ---@module "diffview.review.scope"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

local annotation_ns = api.nvim_create_namespace("diffview_review_comments")

M.annotation_ns = annotation_ns

local function comment_preview(body)
  local preview = ""
  for _, line in ipairs(vim.split(body or "", "\n", { plain = true })) do
    line = vim.trim(line):gsub("%s+", " ")
    if line ~= "" then
      preview = line
      break
    end
  end

  if vim.fn.strchars(preview) > 50 then
    preview = vim.fn.strcharpart(preview, 0, 47) .. "..."
  end
  return "  Comment: " .. preview
end

local function sort_comments(comments)
  table.sort(comments, function(a, b) return a.comment_id < b.comment_id end)
  return comments
end

---Describe what a view currently has on screen, in the form used both to
---decide whether a draft belongs to it and whether a set of `:DiffviewOpen`
---arguments would land on the same diff.
---@param view DiffView
---@return ReviewScope
function M.scope_of(view)
  return scope_lib.encode({
    adapter = view.adapter,
    left = view.left,
    right = view.right,
    path_args = view.path_args,
    label = view.rev_arg or view.adapter:rev_to_pretty_string(view.left, view.right),
  })
end

---@param adapter VCSAdapter
---@return ReviewStore
local function store_for(adapter)
  return ReviewStore(adapter.ctx.dir)
end

---A review in progress, bound to the `DiffView` it was started from.
---@class ReviewSession : diffview.Object
---@field view DiffView
---@field store ReviewStore
---@field review table
---@field comments table[]
---@field comment_marks table<integer, table<integer, table>>
local ReviewSession = oop.create_class("ReviewSession")

---@param view DiffView
---@param store ReviewStore
---@param review table
---@param comments table[]
function ReviewSession:init(view, store, review, comments)
  self.view = view
  self.store = store
  self.review = review
  self.comments = sort_comments(comments or {})
  self.comment_marks = {}
end

---@return string
function ReviewSession:describe()
  return scope_lib.describe(self.review.scope)
end

---Whether this session is still the one attached to its view.
---
---Editor floats outlive the session that opened them: leaving review mode or
---submitting detaches the session while the float is still on screen. Anything
---driven by an editor callback has to check this first, or it will write to an
---abandoned review and strand extmarks in a buffer that nothing will ever
---clean up again.
---@return boolean
function ReviewSession:is_active()
  return self.view.review_session == self
end

---@return boolean ok
function ReviewSession:reload_comments()
  local comments, err = self.store:load_comments(self.review)

  if not comments then
    utils.err("Failed to reload review comments: " .. err)
    return false
  end

  self.comments = sort_comments(comments)
  self.view.panel:sync_review_session()

  if self.view.cur_entry then self:annotate(self.view.cur_entry) end

  return true
end

---@param entry FileEntry
function ReviewSession:annotate(entry)
  if not entry or not entry.layout then return end

  for _, win in ipairs(entry.layout.windows) do
    local file = win.file

    if file and file.bufnr and api.nvim_buf_is_valid(file.bufnr) then
      api.nvim_buf_clear_namespace(file.bufnr, annotation_ns, 0, -1)
      self.comment_marks[file.bufnr] = {}
      local side = file.symbol == "a" and "left" or "right"
      local line_count = api.nvim_buf_line_count(file.bufnr)

      for _, comment in ipairs(self.comments) do
        local location = comment.location

        if location.path == entry.path
            and location.side == side
            and location.line <= line_count then
          local id = api.nvim_buf_set_extmark(
            file.bufnr,
            annotation_ns,
            location.line - 1,
            0,
            {
              virt_text = { { comment_preview(comment.body), "DiagnosticInfo" } },
              virt_text_pos = "eol",
              hl_mode = "combine",
            }
          )
          self.comment_marks[file.bufnr][id] = comment
        end
      end
    end
  end
end

function ReviewSession:clear_annotations()
  for bufnr, _ in pairs(self.comment_marks) do
    if api.nvim_buf_is_valid(bufnr) then
      api.nvim_buf_clear_namespace(bufnr, annotation_ns, 0, -1)
    end
  end
  self.comment_marks = {}
end

---@return Window?
function ReviewSession:current_diff_window()
  local winid = api.nvim_get_current_win()

  for _, win in ipairs(self.view.cur_layout.windows) do
    if win.id == winid and win.file and win.file.symbol then
      return win
    end
  end
end

---@param bufnr integer
---@param line integer
---@return table?
function ReviewSession:comment_at(bufnr, line)
  local marks = self.comment_marks[bufnr]
  if not marks then return end

  local extmarks = api.nvim_buf_get_extmarks(
    bufnr,
    annotation_ns,
    { line - 1, 0 },
    { line - 1, -1 },
    {}
  )

  for _, extmark in ipairs(extmarks) do
    if marks[extmark[1]] then return marks[extmark[1]] end
  end
end

---@param comment table
function ReviewSession:open_comment_editor(comment)
  local location = comment.location

  Editor.open({
    title = ("%s:%d [%s]"):format(
      location.path,
      location.line,
      location.side == "left" and "left" or "right"
    ),
    lines = vim.split(comment.body or "", "\n", { plain = true }),
    on_write = function(lines)
      if not self:is_active() then
        utils.err("This review is no longer active; the comment was not saved.")
        return false
      end

      local body = table.concat(lines, "\n")

      if vim.trim(body) == "" then
        utils.err("Review comments cannot be empty.")
        return false
      end

      comment.body = body
      local ok, err = self.store:save_comment(self.review, comment)

      if not ok then
        utils.err("Failed to save review comment: " .. err)
        return false
      end

      return self:reload_comments()
    end,
  })
end

---Comment on the line under the cursor, or edit the comment already there.
function ReviewSession:comment()
  local win = self:current_diff_window()

  if not win or not win.file:is_valid() then
    utils.err("Review comments must be created from a diff buffer.")
    return
  end

  local line = api.nvim_win_get_cursor(win.id)[1]
  local existing = self:comment_at(win.file.bufnr, line)

  if existing then
    self:open_comment_editor(existing)
    return
  end

  local layout = self.view.cur_layout
  local left = layout.a and layout.a.file
  local right = layout.b and layout.b.file

  if not left or not right or not left:is_valid() or not right:is_valid() then
    utils.err("Review comments require a two-way text diff.")
    return
  end

  local side = win.file.symbol == "a" and "left" or "right"
  local left_lines = api.nvim_buf_get_lines(left.bufnr, 0, -1, false)
  local right_lines = api.nvim_buf_get_lines(right.bufnr, 0, -1, false)
  local hunk = DiffHunk.capture(left_lines, right_lines, side, line)

  if not hunk then
    utils.err("Review comments can only be added to lines inside a diff hunk.")
    return
  end

  local source_lines = side == "left" and left_lines or right_lines
  local entry = self.view.cur_entry

  self:open_comment_editor({
    kind = "line",
    body = "",
    location = {
      path = entry.path,
      old_path = entry.oldpath ~= entry.path and entry.oldpath or nil,
      side = side,
      line = line,
      selected_text = source_lines[line] or "",
      content_oid = "sha256:" .. vim.fn.sha256(table.concat(source_lines, "\n")),
    },
    diff_hunk = {
      format = "unified",
      context_lines = 3,
      text = hunk,
    },
  })
end

---@param comment table
ReviewSession.goto_comment = async.void(function(self, comment)
  await(self.view:set_file_by_path(comment.location.path, false, true))

  local target

  for _, win in ipairs(self.view.cur_layout.windows) do
    local side = win.file.symbol == "a" and "left" or "right"
    if side == comment.location.side then
      target = win
      break
    end
  end

  if not target or not target:is_valid() then return end

  local line = comment.location.line
  local marks = self.comment_marks[target.file.bufnr] or {}

  for id, marked_comment in pairs(marks) do
    if marked_comment.comment_id == comment.comment_id then
      local pos = api.nvim_buf_get_extmark_by_id(
        target.file.bufnr,
        annotation_ns,
        id,
        {}
      )
      if #pos > 0 then line = pos[1] + 1 end
      break
    end
  end

  target:focus()
  pcall(api.nvim_win_set_cursor, target.id, { line, 0 })
end)

function ReviewSession:open_submit_editor()
  Editor.open({
    title = ("Submit review (%d comments)"):format(#self.comments),
    lines = { "" },
    on_write = function()
      if not self:is_active() then
        utils.err("This review is no longer active; it was not submitted.")
        return false
      end

      return true
    end,
    on_submit = function(lines)
      if not self:is_active() then return end
      self:submit(table.concat(lines, "\n"))
    end,
  })
end

---@param body string
function ReviewSession:submit(body)
  local review, err = self.store:submit(self.review, body)

  if not review then
    utils.err("Failed to submit review: " .. err)
    return
  end

  M.detach(self.view)
  utils.info("Submitted review " .. review.review_id)
end

function ReviewSession:activate_panel_item()
  local panel = self.view.panel.session_panel
  local item = panel and panel:get_item_at_cursor()
  if not item then return end

  if item.kind == "comment" then
    self:goto_comment(item.comment)
  elseif item.action == "submit" then
    self:open_submit_editor()
  elseif item.action == "leave" then
    M.leave(self.view)
  end
end

---@param view DiffView
---@param review table
---@param comments table[]
---@return ReviewSession
function M.attach(view, review, comments)
  if view.review_session then
    view.review_session:clear_annotations()
  end

  local session = ReviewSession(view, store_for(view.adapter), review, comments)
  view.review_session = session
  view.panel:enter_review_session(session)

  if view.cur_entry then session:annotate(view.cur_entry) end

  return session
end

---@param view DiffView
function M.detach(view)
  local session = view.review_session
  if not session then return end

  session:clear_annotations()
  view.review_session = nil
  view.panel:leave_review_session()
end

---Start a review of what `view` is showing. Unless `force_new` is set, an
---existing draft covering the same scope is resumed instead.
---@param view DiffView
---@param force_new? boolean
---@return ReviewSession?
function M.start(view, force_new)
  if view.review_session and not force_new then
    utils.info("Already reviewing " .. view.review_session.review.review_id .. ".")
    return view.review_session
  end

  local store = store_for(view.adapter)
  local scope = M.scope_of(view)

  if not force_new then
    local draft = store:find_draft(scope)

    if draft then
      local comments, err = store:load_comments(draft)

      if not comments then
        utils.err("Failed to load review comments: " .. err)
        return
      end

      local ok, set_err = store:set_current(draft.review_id)

      if not ok then
        utils.err("Failed to select review draft: " .. set_err)
        return
      end

      local session = M.attach(view, draft, comments)
      utils.info("Resumed review " .. draft.review_id)
      return session
    end
  end

  local review, err = store:create(scope)

  if not review then
    utils.err("Failed to start review: " .. err)
    return
  end

  local session = M.attach(view, review, {})
  utils.info("Started review " .. review.review_id)

  return session
end

---Return the view's session, starting one if it doesn't have one yet.
---@param view DiffView
---@return ReviewSession?
function M.ensure(view)
  return view.review_session or M.start(view)
end

---Comment on the line under the cursor, starting a session first if needed.
---@param view DiffView
function M.comment(view)
  local session = M.ensure(view)
  if session then session:comment() end
end

---@param view DiffView
function M.submit(view)
  if not view.review_session then
    utils.err("No review session is active.")
    return
  end

  view.review_session:open_submit_editor()
end

---@param view DiffView
function M.leave(view)
  if not view.review_session then
    utils.info("No review session is active.")
    return
  end

  M.detach(view)
  utils.info("Left review mode.")
end

M.ReviewSession = ReviewSession

return M
