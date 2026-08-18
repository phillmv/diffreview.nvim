return function(view)
  return {
    refresh_files = function()
      view:refresh()
    end,
    review_anchor = function()
      if view.review_session then return end
      local index = view.panel.commit_panel:get_index_at_cursor()
      if index then
        view.selection:begin(index)
        view.panel.commit_panel:render()
        view.panel.commit_panel:redraw()
      end
    end,
    review_apply = function()
      if view.review_session then return end
      local index = view.panel.commit_panel:get_index_at_cursor()
      if not index then return end

      view.selection:apply(view.selection.anchor or index, index)
      view:apply_selection()
    end,
    review_cancel = function()
      if view.review_session then return end
      view.selection:cancel()
      view.panel.commit_panel:render()
      view.panel.commit_panel:redraw()
    end,
    review_next_commit = function()
      if view.review_session then return end
      view.panel.commit_panel:move_cursor(vim.v.count1)
    end,
    review_prev_commit = function()
      if view.review_session then return end
      view.panel.commit_panel:move_cursor(-vim.v.count1)
    end,
    review_start = function()
      view:start_review()
    end,
    review_resume = function()
      view:resume_review()
    end,
    review_comment = function()
      view:comment()
    end,
    review_submit = function()
      view:open_submit_editor()
    end,
    review_leave = function()
      view:leave_review()
    end,
    review_session_activate = function()
      view:activate_review_panel_item()
    end,
  }
end
