local oop = require("diffview.oop")

local M = {}

---@class ReviewCommit
---@field hash string
---@field parent? string
---@field author string
---@field rel_date string
---@field subject string

---@class ReviewRange
---@field first? integer
---@field last? integer
---@field newest? ReviewCommit
---@field oldest? ReviewCommit
---@field base? string
---@field editable boolean
---@field current boolean

---@class ReviewSelection : diffview.Object
---@field commits ReviewCommit[]
---@field head string
---@field first integer
---@field last integer
---@field anchor? integer
local ReviewSelection = oop.create_class("ReviewSelection")

---@param commits ReviewCommit[]
---@param default_count? integer
function ReviewSelection:init(commits, default_count)
  assert(#commits > 0, "Review selection requires at least one commit!")

  self.commits = commits
  self.head = commits[1].hash
  self.first = 0
  self.last = math.min(default_count or 0, #commits)
end

---@param index integer
---@return integer
function ReviewSelection:clamp(index)
  return math.max(0, math.min(index, #self.commits))
end

---@param first integer
---@param last? integer
function ReviewSelection:apply(first, last)
  first = self:clamp(first)
  last = self:clamp(last or first)
  self.first = math.min(first, last)
  self.last = math.max(first, last)
  self.anchor = nil
end

---@param index integer
function ReviewSelection:begin(index)
  self.anchor = self:clamp(index)
end

function ReviewSelection:cancel()
  self.anchor = nil
end

---@param cursor integer
---@return integer first
---@return integer last
function ReviewSelection:pending(cursor)
  if not self.anchor then
    return self.first, self.last
  end

  cursor = self:clamp(cursor)
  return math.min(self.anchor, cursor), math.max(self.anchor, cursor)
end

---@return ReviewRange
function ReviewSelection:range()
  if self.first == 0 and self.last == 0 then
    return {
      first = 0,
      last = 0,
      base = self.head,
      editable = true,
      current = true,
    }
  end

  local editable = self.first == 0
  local newest = self.commits[editable and 1 or self.first]
  local oldest = self.commits[self.last]

  return {
    first = self.first,
    last = self.last,
    newest = newest,
    oldest = oldest,
    base = oldest.parent,
    editable = editable,
    current = false,
  }
end

M.ReviewSelection = ReviewSelection
return M
