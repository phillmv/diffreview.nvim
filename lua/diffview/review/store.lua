local lazy = require("diffview.lazy")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local scope_lib = lazy.require("diffview.review.scope") ---@module "diffview.review.scope"

local uv = vim.loop
local pl = utils.path
local islist = vim.islist or vim.tbl_islist

local M = {}

---Bumped when the on-disk layout changes incompatibly. Manifests written by
---any other version are ignored rather than guessed at.
local SCHEMA_VERSION = 1

M.SCHEMA_VERSION = SCHEMA_VERSION

local function timestamp()
  local seconds, microseconds = uv.gettimeofday()
  return os.date("!%Y%m%dT%H%M%S", seconds)
    .. (".%03dZ"):format(math.floor(microseconds / 1000))
end

local function iso_timestamp()
  local seconds, microseconds = uv.gettimeofday()
  return os.date("!%Y-%m-%dT%H:%M:%S", seconds)
    .. (".%03dZ"):format(math.floor(microseconds / 1000))
end

---Encode JSON with stable key ordering and indentation, so that the on-disk
---files stay diffable.
local function json_encode(value, indent)
  indent = indent or ""
  local value_type = type(value)

  if value_type ~= "table" then
    return vim.json.encode(value)
  end

  local next_indent = indent .. "  "
  local lines = {}
  if islist(value) then
    if #value == 0 then return "[]" end
    for _, item in ipairs(value) do
      lines[#lines + 1] = next_indent .. json_encode(item, next_indent)
    end
    return "[\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "]"
  end

  local keys = vim.tbl_keys(value)
  table.sort(keys)
  if #keys == 0 then return "{}" end
  for _, key in ipairs(keys) do
    lines[#lines + 1] = next_indent
      .. vim.json.encode(key)
      .. ": "
      .. json_encode(value[key], next_indent)
  end
  return "{\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "}"
end

local function split_lines(text)
  if not text or text == "" then return {} end
  return vim.split(text, "\n", { plain = true })
end

local function atomic_write(path, data)
  local parent = pl:parent(path)
  if parent and vim.fn.mkdir(parent, "p") == 0 and not pl:is_dir(parent) then
    return nil, "Failed to create directory: " .. parent
  end

  local temp = path .. ".tmp"
  local ok, write_err = pcall(vim.fn.writefile, split_lines(data), temp, "b")
  if not ok then
    return nil, tostring(write_err)
  end

  local renamed, rename_err = uv.fs_rename(temp, path)
  if not renamed then
    uv.fs_unlink(temp)
    return nil, rename_err
  end

  return true
end

local function read_file(path)
  local fd, open_err = uv.fs_open(path, "r", 438)
  if not fd then return nil, open_err end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then return nil, read_err end
  return data
end

local function read_json(path)
  local data, err = read_file(path)
  if not data then return nil, err end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then return nil, tostring(decoded) end
  return decoded
end

local function fence_for(text)
  local longest = 0
  for ticks in (text or ""):gmatch("`+") do
    longest = math.max(longest, #ticks)
  end
  return string.rep("`", math.max(3, longest + 1))
end

---@param review table
---@param comments table[]
---@return string
local function render_markdown(review, comments)
  local lines = {
    "# Submitted Diffview Review",
    "",
    "- Review: `" .. review.review_id .. "`",
    "- Range: `" .. scope_lib.render(review.scope) .. "`",
    "- Submitted: `" .. review.submitted_at .. "`",
  }

  if review.body and review.body ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Review"
    lines[#lines + 1] = ""
    vim.list_extend(lines, split_lines(review.body))
  end

  table.sort(comments, function(a, b)
    local al = a.location
    local bl = b.location
    if al.path ~= bl.path then return al.path < bl.path end
    if al.side ~= bl.side then return al.side < bl.side end
    if al.line ~= bl.line then return al.line < bl.line end
    return a.comment_id < b.comment_id
  end)

  local current_path
  for _, comment in ipairs(comments) do
    local location = comment.location
    if current_path ~= location.path then
      current_path = location.path
      lines[#lines + 1] = ""
      lines[#lines + 1] = "## `" .. current_path:gsub("`", "\\`") .. "`"
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = ("### %s line %d"):format(
      location.side == "left" and "Left" or "Right",
      location.line
    )
    lines[#lines + 1] = ""
    vim.list_extend(lines, split_lines(comment.body))
    lines[#lines + 1] = ""
    local fence = fence_for(comment.diff_hunk.text)
    lines[#lines + 1] = fence .. "diff"
    vim.list_extend(lines, split_lines(comment.diff_hunk.text))
    lines[#lines + 1] = fence
  end

  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

---@class ReviewStore : diffview.Object
---@field root string
local ReviewStore = oop.create_class("ReviewStore")

---@param git_dir string
function ReviewStore:init(git_dir)
  self.root = pl:join(git_dir, "diffview-review")
end

---@param name string
---@return string
function ReviewStore:pointer_path(name)
  return pl:join(self.root, name)
end

---@param review_id string
---@return boolean? ok
---@return string? err
function ReviewStore:set_current(review_id)
  return atomic_write(self:pointer_path("current-draft"), review_id .. "\n")
end

---@param state "draft"|"submitted"
---@param review_id string
---@return string
function ReviewStore:review_dir(state, review_id)
  local collection = state == "draft" and "drafts" or "submitted"
  return pl:join(self.root, collection, review_id)
end

---@param state "draft"|"submitted"
---@param review_id string
---@return string
function ReviewStore:manifest_path(state, review_id)
  return pl:join(self:review_dir(state, review_id), "review.json")
end

---@param scope ReviewScope
---@return table? review
---@return string? err
function ReviewStore:create(scope)
  local base_id = timestamp()
  local review_id = base_id
  local suffix = 1
  while pl:stat(self:review_dir("draft", review_id))
      or pl:stat(self:review_dir("submitted", review_id)) do
    review_id = base_id .. "-" .. suffix
    suffix = suffix + 1
  end

  local now = iso_timestamp()
  local review = {
    schema_version = SCHEMA_VERSION,
    review_id = review_id,
    state = "draft",
    created_at = now,
    updated_at = now,
    scope = scope,
  }

  local ok, err = atomic_write(
    self:manifest_path("draft", review_id),
    json_encode(review) .. "\n"
  )
  if not ok then return nil, err end

  ok, err = self:set_current(review_id)
  if not ok then return nil, err end
  return review
end

---@param state "draft"|"submitted"
---@param review_id string
---@return table? review
---@return string? err
function ReviewStore:load(state, review_id)
  return read_json(self:manifest_path(state, review_id))
end

---@param review table
---@return boolean? ok
---@return string? err
function ReviewStore:save_review(review)
  review.updated_at = iso_timestamp()
  return atomic_write(
    self:manifest_path(review.state, review.review_id),
    json_encode(review) .. "\n"
  )
end

---@param review table
---@return table[]? comments
---@return string? err
function ReviewStore:load_comments(review)
  local comment_dir = pl:join(self:review_dir(review.state, review.review_id), "comments")
  if not pl:is_dir(comment_dir) then return {} end

  local comments = {}
  local paths = vim.fn.glob(pl:join(comment_dir, "*.json"), false, true)
  table.sort(paths)
  for _, path in ipairs(paths) do
    local comment, err = read_json(path)
    if not comment then return nil, err end
    comments[#comments + 1] = comment
  end
  return comments
end

---@param review table
---@param comment table
---@return string
function ReviewStore:comment_path(review, comment)
  return pl:join(
    self:review_dir("draft", review.review_id),
    "comments",
    comment.comment_id .. ".json"
  )
end

---@param review table
---@param comment table
---@return boolean? ok
---@return string? err
function ReviewStore:save_comment(review, comment)
  local now = iso_timestamp()
  if not comment.comment_id then
    local base_id = timestamp()
    comment.comment_id = base_id
    local suffix = 1
    local comment_dir = pl:join(
      self:review_dir("draft", review.review_id),
      "comments"
    )
    while pl:stat(pl:join(comment_dir, comment.comment_id .. ".json")) do
      comment.comment_id = base_id .. "-" .. suffix
      suffix = suffix + 1
    end
    comment.created_at = now
    comment.schema_version = SCHEMA_VERSION
  end
  comment.updated_at = now

  local ok, err = atomic_write(
    self:comment_path(review, comment),
    json_encode(comment) .. "\n"
  )
  if not ok then return nil, err end
  return self:save_review(review)
end

---Remove a comment from a draft. Deleting one that has already gone is not an
---error, so that repeated writes of an emptied editor stay harmless.
---@param review table
---@param comment table
---@return boolean? ok
---@return string? err
function ReviewStore:delete_comment(review, comment)
  if not comment.comment_id then return true end

  local path = self:comment_path(review, comment)

  if pl:stat(path) then
    local unlinked, unlink_err = uv.fs_unlink(path)
    if not unlinked then return nil, unlink_err end
  end

  return self:save_review(review)
end

---Whether a decoded manifest is one this version knows how to work with.
---@param review any
---@return boolean
local function is_usable(review)
  return type(review) == "table"
    and review.schema_version == SCHEMA_VERSION
    and type(review.review_id) == "string"
    and scope_lib.is_valid(review.scope)
end

---@return table[] drafts
function ReviewStore:list_drafts()
  local drafts = {}
  local paths = vim.fn.glob(pl:join(self.root, "drafts", "*"), false, true)
  for _, path in ipairs(paths) do
    if pl:is_dir(path) then
      local review = read_json(pl:join(path, "review.json"))
      if is_usable(review) and review.state == "draft" then
        local comments = self:load_comments(review)
        review.comment_count = comments and #comments or 0
        drafts[#drafts + 1] = review
      end
    end
  end
  table.sort(drafts, function(a, b) return a.review_id > b.review_id end)
  return drafts
end

---Find the most recent draft covering the same scope.
---@param scope ReviewScope
---@return table? review
function ReviewStore:find_draft(scope)
  for _, draft in ipairs(self:list_drafts()) do
    if scope_lib.same(scope, draft.scope) then
      draft.comment_count = nil
      return draft
    end
  end
end

---@param review table
---@param body string
---@return table? submitted
---@return string? err
function ReviewStore:submit(review, body)
  local comments, comments_err = self:load_comments(review)
  if not comments then return nil, comments_err end

  review.body = body ~= "" and body or nil
  review.state = "submitted"
  review.submitted_at = iso_timestamp()
  review.updated_at = review.submitted_at
  local markdown = render_markdown(review, comments)

  local draft_dir = self:review_dir("draft", review.review_id)
  local submitted_dir = self:review_dir("submitted", review.review_id)
  local ok, err = atomic_write(
    pl:join(draft_dir, "review.json"),
    json_encode(review) .. "\n"
  )
  if not ok then return nil, err end

  ok, err = atomic_write(
    pl:join(draft_dir, "review.md"),
    markdown
  )
  if not ok then return nil, err end

  vim.fn.mkdir(pl:parent(submitted_dir), "p")
  local renamed, rename_err = uv.fs_rename(draft_dir, submitted_dir)
  if not renamed then return nil, rename_err end

  ok, err = atomic_write(self:pointer_path("latest.md"), markdown)
  if not ok then return nil, err end
  ok, err = atomic_write(self:pointer_path("current-draft"), "")
  if not ok then return nil, err end
  return review
end

M.ReviewStore = ReviewStore
M.render_markdown = render_markdown
return M
