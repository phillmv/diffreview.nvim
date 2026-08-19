local config = require("diffview.config")
local oop = require("diffview.oop")
local Panel = require("diffview.ui.panel").Panel
local renderer = require("diffview.renderer")

local api = vim.api

local M = {}

local function truncate(text, max_length)
  if #text <= max_length then return text end
  if max_length <= 3 then return text:sub(1, max_length) end
  return text:sub(1, max_length - 3) .. "..."
end

local function summary(body)
  local text = (body or ""):match("([^\n]*)") or ""
  return text ~= "" and text or "(empty comment)"
end

---A split below the file panel, listing the comments in the active review
---session along with the session-level actions.
---@class ReviewSessionPanel : Panel
---@field parent FilePanel
---@field session? ReviewSession
---@field components CompStruct
local ReviewSessionPanel = oop.create_class("ReviewSessionPanel", Panel)

ReviewSessionPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
  },
})

ReviewSessionPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewReviewSession",
})

---@param parent FilePanel
function ReviewSessionPanel:init(parent)
  self.parent = parent

  self:super({
    config = function()
      local conf = config.get_config().review_panel
      return {
        type = "split",
        position = "bottom",
        relative = "win",
        win = self.parent.winid,
        height = conf.height,
        win_opts = conf.win_opts,
      }
    end,
    bufname = "DiffviewReviewSessionPanel",
  })

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

function ReviewSessionPanel:setup_buffer()
  local default_opt = { silent = true, nowait = true, buffer = self.bufid }
  for _, mapping in ipairs(config.get_config().keymaps.review_session_panel) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end
end

---@param session? ReviewSession
function ReviewSessionPanel:set_session(session)
  self.session = session
  self:sync()
end

function ReviewSessionPanel:update_components()
  if self.components then
    self.render_data:destroy()
    renderer.destroy_comp_struct(self.components)
  end

  local comments = { name = "comments" }
  for _, comment in ipairs(self.session and self.session.comments or {}) do
    comments[#comments + 1] = {
      name = "item",
      context = { kind = "comment", comment = comment },
    }
  end

  self.components = self.render_data:create_component({
    { name = "header" },
    {
      name = "actions",
      {
        name = "item",
        context = { kind = "action", action = "submit" },
      },
      {
        name = "item",
        context = { kind = "action", action = "leave" },
      },
    },
    { name = "comment_header" },
    comments,
  })
end

---@return table?
function ReviewSessionPanel:get_item_at_cursor()
  if not self:is_open() then return end
  local line = api.nvim_win_get_cursor(self.winid)[1]
  local comp = self.components.comp:get_comp_on_line(line)
  return comp and comp.name == "item" and comp.context or nil
end

function ReviewSessionPanel:render()
  if not self.render_data then return end
  self.render_data:clear()
  local width = self:infer_width()
  local session = self.session
  local header = self.components.header.comp
  header:add_text("Review Session ", "DiffviewFilePanelTitle")
  header:add_line(
    session and session.review.review_id or "",
    "DiffviewFilePanelCounter"
  )

  local actions = self.components.actions
  actions[1].comp:add_line("[s] Submit review", "DiffviewFilePanelFileName")
  actions[2].comp:add_line("[q] Leave review mode", "DiffviewFilePanelFileName")

  local count = session and #session.comments or 0
  self.components.comment_header.comp:add_text("Comments ", "DiffviewFilePanelTitle")
  self.components.comment_header.comp:add_line(
    ("(%d)"):format(count),
    "DiffviewFilePanelCounter"
  )

  for _, item in ipairs(self.components.comments) do
    local comment = item.comp.context.comment
    local location = comment.location
    local prefix = ("%s:%d [%s] "):format(
      location.path,
      location.line,
      location.side == "left" and "L" or "R"
    )
    item.comp:add_text(prefix, "DiffviewFilePanelPath")
    item.comp:add_line(
      truncate(summary(comment.body), math.max(1, width - #prefix)),
      "DiffviewFilePanelFileName"
    )
  end
end

M.ReviewSessionPanel = ReviewSessionPanel
return M
