local eq = require("diffview.tests.helpers").eq
local scope = require("diffview.review.scope")

local A = string.rep("a", 40)
local B = string.rep("b", 40)

local function commit(oid, track_head)
  return { kind = "commit", oid = oid, track_head = track_head }
end

local function make(left, right, path_args)
  return {
    toplevel = "/repo",
    left = left,
    right = right,
    path_args = path_args or {},
  }
end

describe("Review scope", function()
  describe("same()", function()
    it("matches identical scopes", function()
      eq(true, scope.same(
        make(commit(A), { kind = "local" }),
        make(commit(A), { kind = "local" })
      ))
    end)

    it("separates different commits", function()
      eq(false, scope.same(
        make(commit(A), { kind = "local" }),
        make(commit(B), { kind = "local" })
      ))
    end)

    it("separates different repositories", function()
      local a = make(commit(A), { kind = "local" })
      local b = make(commit(A), { kind = "local" })
      b.toplevel = "/other"

      eq(false, scope.same(a, b))
    end)

    it("separates different rev kinds", function()
      eq(false, scope.same(
        make({ kind = "stage", stage = 0 }, { kind = "local" }),
        make(commit(A), { kind = "local" })
      ))
    end)

    it("separates different stages", function()
      eq(false, scope.same(
        make(commit(A), { kind = "stage", stage = 0 }),
        make(commit(A), { kind = "stage", stage = 2 })
      ))
    end)

    -- The working tree keeps meaning "the working tree" as HEAD moves, so a
    -- draft survives committing partway through a review.
    it("treats the working tree as a stable target", function()
      local a = make(commit(A), { kind = "local", head_oid = A })
      local b = make(commit(A), { kind = "local", head_oid = B })

      eq(true, scope.same(a, b))
    end)

    -- Same reasoning for a rev that tracks HEAD.
    it("treats a HEAD-tracking rev as a stable target", function()
      eq(true, scope.same(
        make(commit(A, true), { kind = "local" }),
        make(commit(B, true), { kind = "local" })
      ))
    end)

    it("does not conflate a HEAD-tracking rev with a pinned one", function()
      eq(false, scope.same(
        make(commit(A, true), { kind = "local" }),
        make(commit(A), { kind = "local" })
      ))
    end)

    it("separates different path args", function()
      eq(false, scope.same(
        make(commit(A), { kind = "local" }, { "src" }),
        make(commit(A), { kind = "local" }, { "doc" })
      ))
    end)

    it("separates a narrowed diff from the whole diff", function()
      eq(false, scope.same(
        make(commit(A), { kind = "local" }, { "src" }),
        make(commit(A), { kind = "local" }, {})
      ))
    end)

    it("is nil-safe", function()
      eq(false, scope.same(nil, make(commit(A), { kind = "local" })))
      eq(false, scope.same(make(commit(A), { kind = "local" }), nil))
    end)

    -- Scopes are read back off disk, so they can be truncated or hand-edited.
    -- A malformed one must compare unequal rather than throw.
    it("rejects malformed scopes instead of erroring", function()
      local good = make(commit(A), { kind = "local" })

      local broken = {
        { toplevel = "/repo", right = { kind = "local" } },            -- no left
        { toplevel = "/repo", left = commit(A) },                      -- no right
        { left = commit(A), right = { kind = "local" } },              -- no toplevel
        { toplevel = "/repo", left = "nonsense", right = { kind = "local" } },
        { toplevel = "/repo", left = {}, right = { kind = "local" } }, -- no kind
        {},
        "not a table",
        42,
      }

      for i, scrap in ipairs(broken) do
        local ok, res = pcall(scope.same, good, scrap)
        assert.is_true(ok, ("scope.same threw on case %d: %s"):format(i, res))
        eq(false, res)

        ok, res = pcall(scope.same, scrap, good)
        assert.is_true(ok, ("scope.same threw on reversed case %d: %s"):format(i, res))
        eq(false, res)
      end
    end)
  end)

  describe("encode()", function()
    local adapter = { ctx = { toplevel = "/repo" } }

    it("stores path args relative to the top level, sorted", function()
      local encoded = scope.encode({
        adapter = adapter,
        left = { type = 3, stage = 0 },
        right = { type = 1 },
        path_args = { "/repo/lua/b.lua", "/repo/lua/a.lua" },
      })

      eq({ "lua/a.lua", "lua/b.lua" }, encoded.path_args)
    end)

    it("makes path args order-insensitive", function()
      local function encode(paths)
        return scope.encode({
          adapter = adapter,
          left = { type = 2, commit = A },
          right = { type = 1 },
          path_args = paths,
        })
      end

      eq(true, scope.same(
        encode({ "/repo/a", "/repo/b" }),
        encode({ "/repo/b", "/repo/a" })
      ))
    end)

    it("encodes each rev type", function()
      local encoded = scope.encode({
        adapter = adapter,
        left = { type = 2, commit = A, track_head = true },
        right = { type = 3, stage = 0 },
      })

      eq({ kind = "commit", oid = A, track_head = true }, encoded.left)
      eq({ kind = "stage", stage = 0 }, encoded.right)
    end)
  end)

  describe("render()", function()
    it("abbreviates commits and names the working tree", function()
      eq("aaaaaaaaa..WORKING TREE", scope.render(
        make(commit(A), { kind = "local" })
      ))
    end)

    it("includes path args", function()
      eq("aaaaaaaaa..INDEX -- lua doc", scope.render(
        make(commit(A), { kind = "stage", stage = 0 }, { "lua", "doc" })
      ))
    end)

    it("names the index and higher stages", function()
      eq("INDEX..WORKING TREE", scope.render(
        make({ kind = "stage", stage = 0 }, { kind = "local" })
      ))
      eq("aaaaaaaaa..STAGE 2", scope.render(
        make(commit(A), { kind = "stage", stage = 2 })
      ))
    end)
  end)
end)
