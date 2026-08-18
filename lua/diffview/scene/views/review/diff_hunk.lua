local M = {}

local function parse_header(header)
  local old_start, old_count, new_start, new_count =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then return end
  return {
    old_start = tonumber(old_start),
    old_count = tonumber(old_count ~= "" and old_count or "1"),
    new_start = tonumber(new_start),
    new_count = tonumber(new_count ~= "" and new_count or "1"),
  }
end

local function contains(start, count, line)
  return count > 0 and line >= start and line < start + count
end

---@param unified string
---@param side "left"|"right"
---@param line integer
---@return string?
function M.find(unified, side, line)
  local current
  local hunks = {}
  for _, text in ipairs(vim.split(unified, "\n", { plain = true })) do
    if text:match("^@@ ") then
      current = { header = parse_header(text), lines = { text } }
      hunks[#hunks + 1] = current
    elseif current then
      current.lines[#current.lines + 1] = text
    end
  end

  for _, hunk in ipairs(hunks) do
    local header = hunk.header
    if header and (
      side == "left" and contains(header.old_start, header.old_count, line)
      or side == "right" and contains(header.new_start, header.new_count, line)
    ) then
      return table.concat(hunk.lines, "\n")
    end
  end
end

---@param left_lines string[]
---@param right_lines string[]
---@param side "left"|"right"
---@param line integer
---@return string?
function M.capture(left_lines, right_lines, side, line)
  local unified = vim.diff(
    table.concat(left_lines, "\n"),
    table.concat(right_lines, "\n"),
    { result_type = "unified", ctxlen = 3 }
  )
  return M.find(unified, side, line)
end

return M
