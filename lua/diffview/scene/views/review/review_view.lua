local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local ReviewFilePanel = lazy.access("diffview.scene.views.review.file_panel", "ReviewFilePanel") ---@type ReviewFilePanel|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

local function same_rev(a, b)
  return a.type == b.type and a.commit == b.commit and a.stage == b.stage
end

---@class ReviewView : DiffView
---@field selection ReviewSelection
local ReviewView = oop.create_class("ReviewView", DiffView.__get())

function ReviewView:init(opt)
  self.selection = opt.selection
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
  local left, right, label = self:selection_revisions()

  self.panel.commit_panel:render()
  self.panel.commit_panel:redraw()
  self:set_revisions(left, right, label)
end

function ReviewView:refresh()
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
