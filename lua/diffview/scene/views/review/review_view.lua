local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local DiffHunk = lazy.require("diffview.scene.views.review.diff_hunk") ---@module "diffview.scene.views.review.diff_hunk"
local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local Editor = lazy.require("diffview.scene.views.review.editor") ---@module "diffview.scene.views.review.editor"
local ReviewFilePanel = lazy.access("diffview.scene.views.review.file_panel", "ReviewFilePanel") ---@type ReviewFilePanel|LazyModule
local ReviewStore = lazy.access("diffview.scene.views.review.store", "ReviewStore") ---@type ReviewStore|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await
local M = {}
local annotation_ns = api.nvim_create_namespace("diffview_review_comments")

local function same_rev(a, b)
  return a.type == b.type and a.commit == b.commit and a.stage == b.stage
end

local function same_scope(a, b)
  if a.left.kind ~= b.left.kind or a.left.oid ~= b.left.oid then
    return false
  end
  if a.right.kind ~= b.right.kind then return false end
  return a.right.kind == "working_tree" or a.right.oid == b.right.oid
end

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

---@class ReviewView : DiffView
---@field selection ReviewSelection
---@field review_store ReviewStore
---@field review_session? table
---@field comment_marks table<integer, table<integer, table>>
local ReviewView = oop.create_class("ReviewView", DiffView.__get())

function ReviewView:init(opt)
  self.selection = opt.selection
  self.review_store = ReviewStore(opt.adapter.ctx.dir)
  self.comment_marks = {}
  self:super(opt)
end

---@override
function ReviewView:create_file_panel()
  return ReviewFilePanel(
    self.adapter,
    self.files,
    self.path_args,
    self.rev_arg,
    self.selection
  )
end

---@return Rev left
---@return Rev right
---@return string label
function ReviewView:selection_revisions()
  local range = self.selection:range()
  local left = range.base
      and self.adapter.Rev(RevType.COMMIT, range.base)
      or self.adapter.Rev.new_null_tree()
  local right = range.editable
      and self.adapter.Rev(RevType.LOCAL)
      or self.adapter.Rev(RevType.COMMIT, range.newest.hash)
  local label

  if range.current then
    label = "HEAD..WORKING TREE"
  elseif range.editable then
    label = ("%s..WORKING TREE"):format(left:abbrev(7))
  else
    label = ("%s..%s"):format(left:abbrev(7), right:abbrev(7))
  end

  return left, right, label
end

function ReviewView:apply_selection()
  if self.review_session then
    utils.warn("Leave review mode before changing the selected range.")
    return
  end

  local left, right, label = self:selection_revisions()

  self.panel.commit_panel:render()
  self.panel.commit_panel:redraw()
  self:set_revisions(left, right, label)
end

function ReviewView:refresh()
  if self.review_session then
    self:update_files()
    return
  end

  local range = self.selection:range()
  local include_hash = range.oldest and range.oldest.hash
  local max_count = config.get_config().review_panel.max_count
  local err, commits = self.adapter:review_commits(max_count, include_hash)

  if err then
    utils.err("Failed to refresh DiffviewReview commits: " .. err)
    return
  elseif not commits or #commits == 0 then
    utils.err("DiffviewReview requires a repository with at least one commit.")
    return
  end

  if not self.selection:reconcile(commits) then
    self.selection:reset(commits, 0)
    utils.warn(
      "DiffviewReview: selected range is no longer present in first-parent history; "
        .. "showing HEAD..WORKING TREE instead."
    )
  end

  local commit_panel = self.panel.commit_panel
  commit_panel:update_components()
  commit_panel:render()
  commit_panel:redraw()
  commit_panel:highlight_selection()

  local left, right, label = self:selection_revisions()
  if same_rev(left, self.left) and same_rev(right, self.right) then
    self.rev_arg = label
    self.panel.rev_pretty_name = label
    self:update_files()
  else
    self:set_revisions(left, right, label)
  end
end

---@return table
function ReviewView:review_scope()
  local range = self.selection:range()
  local left, right, label = self:selection_revisions()
  local scope = {
    label = label,
    left = {
      kind = "commit",
      oid = left.commit,
    },
    selection = {
      current = range.current,
      includes_working_tree = range.editable,
      base_oid = left.commit,
    },
  }

  if right.type == RevType.LOCAL then
    local head = self.adapter:head_rev()
    scope.right = {
      kind = "working_tree",
      head_oid = head and head.commit or nil,
    }
  else
    scope.right = {
      kind = "commit",
      oid = right.commit,
    }
  end

  if range.oldest then
    scope.selection.oldest_oid = range.oldest.hash
    scope.selection.newest_oid = range.newest.hash
  end
  return scope
end

---@param review table
---@param comments table[]
function ReviewView:activate_review(review, comments)
  self:clear_comment_annotations()
  table.sort(comments, function(a, b) return a.comment_id < b.comment_id end)
  self.review_session = {
    review = review,
    comments = comments,
  }
  self.panel:enter_review_session(self.review_session)
  if self.cur_entry then self:apply_comment_annotations(self.cur_entry) end
end

---@param review table
---@param restore_range boolean
---@return boolean
function ReviewView:resume_draft(review, restore_range)
  review.comment_count = nil
  if restore_range then
    local selection = review.scope.selection
    local max_count = config.get_config().review_panel.max_count
    local include_hash = selection.oldest_oid or selection.base_oid
    local err, commits = self.adapter:review_commits(max_count, include_hash)
    if err then
      utils.err("Failed to restore review range: " .. err)
      return false
    end
    if not commits or not self.selection:restore(commits, selection) then
      utils.err("The draft's revision range is no longer present in first-parent history.")
      return false
    end
  end

  local comments, comments_err = self.review_store:load_comments(review)
  if not comments then
    utils.err("Failed to load review comments: " .. comments_err)
    return false
  end
  local current_ok, current_err = self.review_store:set_current(review.review_id)
  if not current_ok then
    utils.err("Failed to select review draft: " .. current_err)
    return false
  end

  self:activate_review(review, comments)
  if restore_range then
    local left, right, label = self:selection_revisions()
    self:set_revisions(left, right, label)
  end
  return true
end

---@param force_new? boolean
function ReviewView:start_review(force_new)
  local scope = self:review_scope()
  if not force_new then
    for _, draft in ipairs(self.review_store:list_drafts()) do
      if same_scope(scope, draft.scope) then
        if self:resume_draft(draft, false) then
          utils.info("Resumed review " .. draft.review_id)
        end
        return
      end
    end
  end

  local review, err = self.review_store:create(scope)
  if not review then
    utils.err("Failed to start review: " .. err)
    return
  end
  self:activate_review(review, {})
  utils.info("Started review " .. review.review_id)
end

function ReviewView:resume_review()
  local drafts = self.review_store:list_drafts()
  if #drafts == 0 then
    utils.info("No saved DiffviewReview drafts.")
    return
  end

  vim.ui.select(drafts, {
    prompt = "Resume DiffviewReview draft",
    format_item = function(review)
      return ("%s  %s  (%d comments)"):format(
        review.review_id,
        review.scope.label,
        review.comment_count
      )
    end,
  }, function(review)
    if not review then return end
    self:resume_draft(review, true)
  end)
end

function ReviewView:leave_review()
  if not self.review_session then
    utils.info("No review session is active.")
    return
  end
  self:clear_comment_annotations()
  self.review_session = nil
  self.panel:leave_review_session()
end

---@return Window?
function ReviewView:current_diff_window()
  local winid = api.nvim_get_current_win()
  for _, win in ipairs(self.cur_layout.windows) do
    if win.id == winid and win.file and win.file.symbol then
      return win
    end
  end
end

---@param bufnr integer
---@param line integer
---@return table?
function ReviewView:comment_mark_at(bufnr, line)
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

---@param entry FileEntry
function ReviewView:apply_comment_annotations(entry)
  if not self.review_session then return end

  for _, win in ipairs(entry.layout.windows) do
    local file = win.file
    if file and file.bufnr and api.nvim_buf_is_valid(file.bufnr) then
      api.nvim_buf_clear_namespace(file.bufnr, annotation_ns, 0, -1)
      self.comment_marks[file.bufnr] = {}
      local side = file.symbol == "a" and "left" or "right"
      for _, comment in ipairs(self.review_session.comments) do
        local location = comment.location
        if location.path == entry.path and location.side == side
            and location.line <= api.nvim_buf_line_count(file.bufnr) then
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

function ReviewView:clear_comment_annotations()
  for bufnr, _ in pairs(self.comment_marks) do
    if api.nvim_buf_is_valid(bufnr) then
      api.nvim_buf_clear_namespace(bufnr, annotation_ns, 0, -1)
    end
  end
  self.comment_marks = {}
end

---@override
function ReviewView:close()
  self:clear_comment_annotations()
  DiffView.close(self)
end

---@override
function ReviewView:file_open_post(e, new_entry, old_entry)
  DiffView.file_open_post(self, e, new_entry, old_entry)
  self:apply_comment_annotations(new_entry)
end

---@param comment table
function ReviewView:open_comment_editor(comment)
  local location = comment.location
  Editor.open({
    title = ("%s:%d [%s]"):format(
      location.path,
      location.line,
      location.side == "left" and "left" or "right"
    ),
    lines = vim.split(comment.body or "", "\n", { plain = true }),
    on_write = function(lines)
      local body = table.concat(lines, "\n")
      if vim.trim(body) == "" then
        utils.err("Review comments cannot be empty.")
        return false
      end
      comment.body = body
      local ok, err = self.review_store:save_comment(
        self.review_session.review,
        comment
      )
      if not ok then
        utils.err("Failed to save review comment: " .. err)
        return false
      end

      local comments, load_err = self.review_store:load_comments(
        self.review_session.review
      )
      if not comments then
        utils.err("Failed to reload review comments: " .. load_err)
        return false
      end
      table.sort(comments, function(a, b) return a.comment_id < b.comment_id end)
      self.review_session.comments = comments
      self.panel.session_panel:set_session(self.review_session)
      if self.cur_entry then self:apply_comment_annotations(self.cur_entry) end
      return true
    end,
  })
end

function ReviewView:comment()
  if not self.review_session then
    utils.err("Start a review session before adding comments.")
    return
  end

  local win = self:current_diff_window()
  if not win or not win.file:is_valid() then
    utils.err("Review comments must be created from a diff buffer.")
    return
  end

  local line = api.nvim_win_get_cursor(win.id)[1]
  local existing = self:comment_mark_at(win.file.bufnr, line)
  if existing then
    self:open_comment_editor(existing)
    return
  end

  local left = self.cur_layout.a and self.cur_layout.a.file
  local right = self.cur_layout.b and self.cur_layout.b.file
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
  local entry = self.cur_entry
  local comment = {
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
  }
  self:open_comment_editor(comment)
end

function ReviewView:open_submit_editor()
  if not self.review_session then
    utils.err("No review session is active.")
    return
  end

  Editor.open({
    title = ("Submit review (%d comments)"):format(#self.review_session.comments),
    lines = { "" },
    on_write = function()
      return true
    end,
    on_submit = function(lines)
      self:submit_review(table.concat(lines, "\n"))
    end,
  })
end

---@param body string
function ReviewView:submit_review(body)
  local review, err = self.review_store:submit(self.review_session.review, body)
  if not review then
    utils.err("Failed to submit review: " .. err)
    return
  end
  self:clear_comment_annotations()
  self.review_session = nil
  self.panel:leave_review_session()
  utils.info("Submitted review " .. review.review_id)
end

---@param comment table
ReviewView.goto_comment = async.void(function(self, comment)
  await(self:set_file_by_path(comment.location.path, false, true))
  local target
  for _, win in ipairs(self.cur_layout.windows) do
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

function ReviewView:activate_review_panel_item()
  if not self.review_session then return end
  local item = self.panel.session_panel:get_item_at_cursor()
  if not item then return end
  if item.kind == "comment" then
    self:goto_comment(item.comment)
  elseif item.action == "submit" then
    self:open_submit_editor()
  elseif item.action == "leave" then
    self:leave_review()
  end
end

---@override
function ReviewView:init_event_listeners()
  local listeners = require("diffview.scene.views.diff.listeners")(self)
  local review_listeners = require("diffview.scene.views.review.listeners")(self)
  for event, callback in pairs(review_listeners) do
    listeners[event] = callback
  end
  for event, callback in pairs(listeners) do
    self.emitter:on(event, callback)
  end
end

M.ReviewView = ReviewView
return M
