local oop = require("diffview.oop")
local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
local ReviewCommitPanel = require("diffview.scene.views.review.commit_panel").ReviewCommitPanel
local ReviewSessionPanel = require("diffview.scene.views.review.session_panel").ReviewSessionPanel

local M = {}

---@class ReviewFilePanel : FilePanel
---@field commit_panel ReviewCommitPanel
---@field session_panel ReviewSessionPanel
---@field review_session? table
local ReviewFilePanel = oop.create_class("ReviewFilePanel", FilePanel)

function ReviewFilePanel:init(adapter, files, path_args, rev_pretty_name, selection)
  self:super(adapter, files, path_args, rev_pretty_name)
  self.commit_panel = ReviewCommitPanel(self, selection)
  self.session_panel = ReviewSessionPanel(self)
end

---@override
function ReviewFilePanel:open()
  ReviewFilePanel.super_class.open(self)
  if self.review_session then
    self.session_panel:open()
  else
    self.commit_panel:open()
    self.commit_panel:highlight_selection()
  end
end

---@override
function ReviewFilePanel:close()
  self.commit_panel:close()
  self.session_panel:close()
  ReviewFilePanel.super_class.close(self)
end

---@override
function ReviewFilePanel:destroy()
  self.commit_panel:destroy()
  self.session_panel:destroy()
  ReviewFilePanel.super_class.destroy(self)
end

---@param session table
function ReviewFilePanel:enter_review_session(session)
  self.review_session = session
  if not self:is_open() then
    ReviewFilePanel.super_class.open(self)
  end
  self.commit_panel:close()
  self.session_panel:set_session(session)
  self.session_panel:open()
end

function ReviewFilePanel:leave_review_session()
  local is_open = self:is_open()
  self.review_session = nil
  self.session_panel:close()
  if is_open then
    self.commit_panel:open()
    self.commit_panel:highlight_selection()
  end
end

M.ReviewFilePanel = ReviewFilePanel
return M
