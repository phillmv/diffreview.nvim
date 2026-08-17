local oop = require("diffview.oop")
local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
local ReviewCommitPanel = require("diffview.scene.views.review.commit_panel").ReviewCommitPanel

local M = {}

---@class ReviewFilePanel : FilePanel
---@field commit_panel ReviewCommitPanel
local ReviewFilePanel = oop.create_class("ReviewFilePanel", FilePanel)

function ReviewFilePanel:init(adapter, files, path_args, rev_pretty_name, selection)
  self:super(adapter, files, path_args, rev_pretty_name)
  self.commit_panel = ReviewCommitPanel(self, selection)
end

---@override
function ReviewFilePanel:open()
  ReviewFilePanel.super_class.open(self)
  self.commit_panel:open()
  self.commit_panel:highlight_selection()
end

---@override
function ReviewFilePanel:close()
  self.commit_panel:close()
  ReviewFilePanel.super_class.close(self)
end

---@override
function ReviewFilePanel:destroy()
  self.commit_panel:destroy()
  ReviewFilePanel.super_class.destroy(self)
end

M.ReviewFilePanel = ReviewFilePanel
return M
