local eq = require("diffview.tests.helpers").eq
require("diffview.bootstrap")
local vcs = require("diffview.vcs")

local function git(dir, ...)
  local out = vim.fn.system({ "git", "-C", dir, ... })
  assert(vim.v.shell_error == 0, out)
  return vim.trim(out)
end

describe("GitAdapter review commits", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "-q")
    git(dir, "config", "user.name", "Diffview Test")
    git(dir, "config", "user.email", "diffview@example.com")

    for i = 1, 3 do
      local path = ("%s/file-%d"):format(dir, i)
      vim.fn.writefile({ tostring(i) }, path)
      git(dir, "add", ".")
      git(dir, "commit", "-qm", "commit " .. i)
    end
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("expands the window through a selected commit", function()
    local oldest = git(dir, "rev-parse", "HEAD~2")
    local err, adapter = vcs.get_adapter({
      cmd_ctx = {
        path_args = {},
        cpath = dir,
      },
    })
    eq(nil, err)

    local log_err, commits = adapter:review_commits(1, oldest)
    eq(nil, log_err)
    eq(3, #commits)
    eq(oldest, commits[3].hash)
  end)
end)
