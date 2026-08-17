return function(view)
  return {
    review_anchor = function()
      local index = view.panel.commit_panel:get_index_at_cursor()
      if index then
        view.selection:begin(index)
        view.panel.commit_panel:render()
        view.panel.commit_panel:redraw()
      end
    end,
    review_apply = function()
      local index = view.panel.commit_panel:get_index_at_cursor()
      if not index then return end

      view.selection:apply(view.selection.anchor or index, index)
      view:apply_selection()
    end,
    review_cancel = function()
      view.selection:cancel()
      view.panel.commit_panel:render()
      view.panel.commit_panel:redraw()
    end,
    review_next_commit = function()
      view.panel.commit_panel:move_cursor(vim.v.count1)
    end,
    review_prev_commit = function()
      view.panel.commit_panel:move_cursor(-vim.v.count1)
    end,
  }
end
