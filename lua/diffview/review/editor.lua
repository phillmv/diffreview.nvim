local api = vim.api

local M = {}

local next_id = 0

---@class ReviewEditorOptions
---@field title string # Shown in the editor's winbar.
---@field hint? string # Key hints for the winbar.
---@field lines? string[]
---@field filetype? string
---@field on_write fun(lines: string[]): boolean?
---@field on_submit? fun(lines: string[])
---@field on_close? fun() # Runs once the window has gone and the layout settled.

---Open a scratch buffer in a split below the diff, in the style of
---`COMMIT_EDITMSG`: write it to save, and quit to close.
---
---`on_write` decides what a given body means, including an empty one, and
---returns false to refuse the write and keep the buffer open.
---
---When `on_submit` is given it runs once the window closes, provided the
---buffer was last written successfully and has no unsaved edits.
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

  local height = math.max(5, math.min(12, math.floor(vim.o.lines * 0.3)))
  vim.cmd(("botright %dsplit"):format(height))
  local winid = api.nvim_get_current_win()
  api.nvim_win_set_buf(winid, bufnr)

  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].spell = true
  vim.wo[winid].winfixheight = true

  local hint = opt.hint or ":wq to save  ·  :q! to cancel"
  local banner = ("  %s  ·  %s"):format(opt.title, hint)

  if vim.fn.has("nvim-0.8") == 1 then
    vim.wo[winid].winbar = banner:gsub("%%", "%%%%")
  else
    vim.wo[winid].statusline = banner:gsub("%%", "%%%%")
  end

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

  if opt.on_submit or opt.on_close then
    api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(winid),
      once = true,
      callback = function()
        -- Only submit what was actually written: anything typed since the last
        -- successful write leaves the buffer modified, and is discarded.
        local dirty = api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified

        if opt.on_submit and last_write and not dirty then
          opt.on_submit(last_write)
        end

        -- The window is still present during `WinClosed`; wait for the rows it
        -- occupied to be handed back before anyone measures the layout.
        if opt.on_close then vim.schedule(opt.on_close) end
      end,
    })
  end

  return bufnr, winid
end

return M

