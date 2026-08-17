local config = require("diffview.config")
local hl = require("diffview.hl")
local oop = require("diffview.oop")
local Panel = require("diffview.ui.panel").Panel

local api = vim.api

local M = {}

local function truncate(text, max_length)
  if #text <= max_length then return text end
  if max_length <= 3 then return text:sub(1, max_length) end
  return text:sub(1, max_length - 3) .. "..."
end

---@class ReviewCommitPanel : Panel
---@field parent ReviewFilePanel
---@field selection ReviewSelection
---@field components CompStruct
local ReviewCommitPanel = oop.create_class("ReviewCommitPanel", Panel)

ReviewCommitPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
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

ReviewCommitPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewReviewCommits",
})

---@param parent ReviewFilePanel
---@param selection ReviewSelection
function ReviewCommitPanel:init(parent, selection)
  self.parent = parent
  self.selection = selection

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
    bufname = "DiffviewReviewCommitPanel",
  })

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })

  self:on_autocmd("CursorMoved", {
    callback = function()
      if self.selection.anchor then
        self:render()
        self:redraw()
      end
    end,
  })
end

function ReviewCommitPanel:setup_buffer()
  local default_opt = { silent = true, nowait = true, buffer = self.bufid }
  for _, mapping in ipairs(config.get_config().keymaps.review_panel) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end
end

function ReviewCommitPanel:update_components()
  local commits = { name = "commits" }
  for i, commit in ipairs(self.selection.commits) do
    commits[#commits + 1] = {
      name = "commit",
      context = { index = i, commit = commit },
    }
  end

  self.components = self.render_data:create_component({
    { name = "header" },
    commits,
  })
end

---@return integer?
function ReviewCommitPanel:get_index_at_cursor()
  if not self:is_open() then return end

  local line = api.nvim_win_get_cursor(self.winid)[1]
  local comp = self.components.comp:get_comp_on_line(line)
  return comp and comp.name == "commit" and comp.context.index or nil
end

function ReviewCommitPanel:highlight_selection()
  if not self:is_open() then return end

  local target = self.selection.last or 1
  for _, item in ipairs(self.components.commits) do
    if item.comp.context.index == target then
      pcall(api.nvim_win_set_cursor, self.winid, { item.comp.lstart + 1, 0 })
      return
    end
  end
end

---@param offset integer
function ReviewCommitPanel:move_cursor(offset)
  if not self:is_open() then return end

  local index = self:get_index_at_cursor() or self.selection.last or 1
  index = self.selection:clamp(index + offset)

  for _, item in ipairs(self.components.commits) do
    if item.comp.context.index == index then
      pcall(api.nvim_win_set_cursor, self.winid, { item.comp.lstart + 1, 0 })
      if self.selection.anchor then
        self:render()
        self:redraw()
      end
      return
    end
  end
end

function ReviewCommitPanel:render()
  if not self.render_data then return end

  local cursor = self:get_index_at_cursor() or self.selection.last or 1
  self.render_data:clear()
  local width = self:infer_width()
  local first, last = self.selection:pending(cursor)
  local pending = self.selection.anchor ~= nil
  local range = self.selection:range()
  local editable = pending and first == 1 or not pending and range.editable

  local header = self.components.header.comp
  header:add_text("Commits ", "DiffviewFilePanelTitle")
  header:add_line(editable and "[EDITABLE]" or "[READ ONLY]", "DiffviewFilePanelCounter")
  if pending then
    header:add_line("<CR>: apply  <Esc>: cancel", "DiffviewFilePanelPath")
  else
    header:add_line("v: anchor  <CR>: select one", "DiffviewFilePanelPath")
  end

  for _, item in ipairs(self.components.commits) do
    local ctx = item.comp.context
    local commit = ctx.commit
    local selected = first and ctx.index >= first and ctx.index <= last
    local marker = selected and (pending and "+" or "*") or " "
    local head = ctx.index == 1 and "@" or " "

    item.comp:add_text(marker .. head .. " ", selected and "DiffviewFilePanelSelected" or nil)
    item.comp:add_text(commit.hash:sub(1, 7) .. " ", hl.get_git_hl("M"))
    item.comp:add_line(
      truncate(commit.subject, math.max(1, width - 13)),
      selected and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName"
    )
  end
end

M.ReviewCommitPanel = ReviewCommitPanel
return M
