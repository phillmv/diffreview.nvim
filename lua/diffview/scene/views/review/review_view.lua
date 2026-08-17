local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local ReviewFilePanel = lazy.access("diffview.scene.views.review.file_panel", "ReviewFilePanel") ---@type ReviewFilePanel|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule

local M = {}

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
    label = "HEAD -> WORKING TREE"
  elseif range.editable then
    label = ("%s -> WORKING TREE"):format(left:abbrev(7))
  else
    label = ("%s -> %s"):format(left:abbrev(7), right:abbrev(7))
  end

  return left, right, label
end

function ReviewView:apply_selection()
  local left, right, label = self:selection_revisions()

  self.panel.commit_panel:render()
  self.panel.commit_panel:redraw()
  self:set_revisions(left, right, label)
end

---@override
function ReviewView:init_event_listeners()
  DiffView.init_event_listeners(self)

  local listeners = require("diffview.scene.views.review.listeners")(self)
  for event, callback in pairs(listeners) do
    self.emitter:on(event, callback)
  end
end

M.ReviewView = ReviewView
return M
