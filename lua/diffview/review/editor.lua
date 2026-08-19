local utils = require("diffview.utils")

local api = vim.api

local M = {}

local next_id = 0

---@class ReviewEditorOptions
---@field title string
---@field lines? string[]
---@field filetype? string
---@field on_write fun(lines: string[]): boolean?
---@field on_submit? fun(lines: string[])

---Open a floating scratch buffer. Writing it (`:w`) runs `on_write`; if an
---`on_submit` handler is given it runs when the window is closed after a
---successful write.
---@param opt ReviewEditorOptions
---@return integer bufnr
---@return integer winid
function M.open(opt)
  next_id = next_id + 1
  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, ("diffview://review-editor/%d"):format(next_id))
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = opt.filetype or "markdown"
  api.nvim_buf_set_lines(bufnr, 0, -1, false, opt.lines or { "" })
  vim.bo[bufnr].modified = false

  local width = math.max(40, math.min(80, math.floor(vim.o.columns * 0.7)))
  local height = math.max(6, math.min(20, math.floor(vim.o.lines * 0.5)))
  local winid = api.nvim_open_win(bufnr, true, utils.sanitize_float_config({
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. opt.title .. " ",
    title_pos = "center",
  }))

  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].winhl = "Normal:DiffviewNormal,FloatBorder:DiffviewWinSeparator"

  local last_write
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local ok = opt.on_write(lines)
      if ok == false then return end
      last_write = lines
      vim.bo[bufnr].modified = false
    end,
  })

  if opt.on_submit then
    api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(winid),
      once = true,
      callback = function()
        -- Only submit what was actually written: anything typed since the last
        -- successful write leaves the buffer modified, and is discarded.
        local dirty = api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified

        if last_write and not dirty then
          opt.on_submit(last_write)
        end
      end,
    })
  end

  return bufnr, winid
end

return M
