local eq = require("diffview.tests.helpers").eq
local Editor = require("diffview.review.editor")

describe("Review editor", function()
  it("opens in a split, not a float", function()
    local _, winid = Editor.open({
      title = "Comment",
      lines = { "" },
      on_write = function() return true end,
    })

    eq("", vim.api.nvim_win_get_config(winid).relative)
    vim.api.nvim_win_close(winid, true)
  end)

  it("saves and closes on :wq", function()
    local saved
    local bufnr, winid = Editor.open({
      title = "Comment",
      lines = { "" },
      on_write = function(lines)
        saved = table.concat(lines, "\n")
        return true
      end,
    })

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Please change this." })
    vim.api.nvim_win_call(winid, function()
      vim.cmd("wq")
    end)

    eq("Please change this.", saved)
    eq(false, vim.api.nvim_win_is_valid(winid))
  end)

  -- Emptiness is the caller's business now, so the editor just forwards it.
  it("passes an empty body through to on_write", function()
    local seen
    local _, winid = Editor.open({
      title = "Comment",
      lines = { "" },
      on_write = function(lines)
        seen = table.concat(lines, "\n")
        return true
      end,
    })

    vim.api.nvim_win_call(winid, function()
      vim.cmd("wq")
    end)

    eq("", seen)
  end)

  it("keeps the buffer open when the caller refuses the write", function()
    local bufnr, winid = Editor.open({
      title = "Comment",
      lines = { "" },
      on_write = function() return false end,
    })

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Rejected." })
    vim.api.nvim_win_call(winid, function()
      pcall(vim.cmd, "wq")
    end)

    eq(true, vim.api.nvim_win_is_valid(winid))
    eq(true, vim.bo[bufnr].modified)
    vim.api.nvim_win_close(winid, true)
  end)

  it("persists comment text on write", function()
    local saved
    local bufnr, winid = Editor.open({
      title = "Comment",
      lines = { "" },
      on_write = function(lines)
        saved = table.concat(lines, "\n")
        return true
      end,
    })

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Please change this." })
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("write")
    end)

    eq("Please change this.", saved)
    eq(false, vim.bo[bufnr].modified)
    vim.api.nvim_win_close(winid, true)
  end)
end)
