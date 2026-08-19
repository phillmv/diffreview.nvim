local lazy = require("diffview.lazy")

local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

---@class ReviewScopeRev
---@field kind "commit"|"local"|"stage"|"custom"
---@field oid? string
---@field stage? integer
---@field track_head? boolean

---A normalized, serializable description of what a review covers. Two reviews
---are "the same review" when their scopes compare equal.
---@class ReviewScope
---@field label? string
---@field toplevel string
---@field left ReviewScopeRev
---@field right ReviewScopeRev
---@field path_args string[] # Relative to `toplevel`, sorted.

---@param rev Rev
---@return ReviewScopeRev
function M.encode_rev(rev)
  if rev.type == RevType.LOCAL then
    return { kind = "local" }
  elseif rev.type == RevType.STAGE then
    return { kind = "stage", stage = rev.stage or 0 }
  elseif rev.type == RevType.COMMIT then
    return {
      kind = "commit",
      oid = rev.commit,
      track_head = rev.track_head or nil,
    }
  end

  return { kind = "custom" }
end

---@param toplevel string
---@param path_args? string[] # Absolute paths.
---@return string[]
local function encode_path_args(toplevel, path_args)
  local seen, out = {}, {}

  for _, path in ipairs(path_args or {}) do
    local rel = pl:relative(path, toplevel)
    if rel == "" then rel = "." end

    if not seen[rel] then
      seen[rel] = true
      out[#out + 1] = rel
    end
  end

  table.sort(out)

  return out
end

---@param opt { adapter: VCSAdapter, left: Rev, right: Rev, path_args?: string[], label?: string }
---@return ReviewScope
function M.encode(opt)
  local toplevel = opt.adapter.ctx.toplevel

  return {
    label = opt.label,
    toplevel = toplevel,
    left = M.encode_rev(opt.left),
    right = M.encode_rev(opt.right),
    path_args = encode_path_args(toplevel, opt.path_args),
  }
end

---@param a ReviewScopeRev
---@param b ReviewScopeRev
---@return boolean
local function same_rev(a, b)
  if a.kind ~= b.kind then return false end

  if a.kind == "stage" then
    return (a.stage or 0) == (b.stage or 0)
  elseif a.kind ~= "commit" then
    -- A "local" rev always points at the working tree, whatever HEAD happens
    -- to be. Reviews of uncommitted work survive committing.
    return true
  end

  -- Likewise, a rev that tracks HEAD keeps meaning "HEAD" as HEAD moves.
  if a.track_head or b.track_head then
    return (a.track_head or false) == (b.track_head or false)
  end

  return a.oid == b.oid
end

---@param side any
---@return boolean
local function valid_rev(side)
  return type(side) == "table" and type(side.kind) == "string"
end

---Whether a decoded scope has the shape this module knows how to compare.
---Manifests are read off disk, so they can be hand-edited, truncated, or
---written by a different schema version.
---@param scope any
---@return boolean
function M.is_valid(scope)
  return type(scope) == "table"
    and type(scope.toplevel) == "string"
    and (scope.path_args == nil or type(scope.path_args) == "table")
    and valid_rev(scope.left)
    and valid_rev(scope.right)
end

---@param a? ReviewScope
---@param b? ReviewScope
---@return boolean
function M.same(a, b)
  if not (M.is_valid(a) and M.is_valid(b)) then return false end
  if a.toplevel ~= b.toplevel then return false end
  if not same_rev(a.left, b.left) then return false end
  if not same_rev(a.right, b.right) then return false end

  local a_paths, b_paths = a.path_args or {}, b.path_args or {}
  if #a_paths ~= #b_paths then return false end

  for i, path in ipairs(a_paths) do
    if path ~= b_paths[i] then return false end
  end

  return true
end

---@param rev ReviewScopeRev
---@return string
local function render_rev(rev)
  if rev.kind == "local" then
    return "WORKING TREE"
  elseif rev.kind == "stage" then
    return (rev.stage or 0) == 0 and "INDEX" or ("STAGE %d"):format(rev.stage)
  elseif rev.kind == "commit" then
    return rev.oid and rev.oid:sub(1, 9) or "HEAD"
  end

  return rev.kind
end

---@param scope ReviewScope
---@return string
function M.render(scope)
  local out = render_rev(scope.left) .. ".." .. render_rev(scope.right)

  if scope.path_args and #scope.path_args > 0 then
    out = out .. " -- " .. table.concat(scope.path_args, " ")
  end

  return out
end

---A short, human-facing description of a scope.
---@param scope ReviewScope
---@return string
function M.describe(scope)
  local label = scope.label

  if not label or label == "" then
    return M.render(scope)
  end

  if scope.path_args and #scope.path_args > 0 then
    label = label .. " -- " .. table.concat(scope.path_args, " ")
  end

  return label
end

return M
