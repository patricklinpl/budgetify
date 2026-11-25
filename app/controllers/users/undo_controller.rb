module Users
  # Undo and Redo for one plan (Undo slice 1). One POST each, CSRF protected,
  # scoped to the current user's plan. The inverse and the stack move run in one
  # database transaction (UndoHistory); a refusal changes nothing and says why.
  class UndoController < ApplicationController
    before_action :set_budget

    def undo = run { undo_history.undo! }
    def redo = run { undo_history.redo! }

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def run
        flash[:undo_status] = yield
        redirect_back_or_to users_budget_path(@budget.public_id), allow_other_host: false
      rescue UndoHistory::Refused => e
        flash[:undo_status] = e.message
        redirect_back_or_to users_budget_path(@budget.public_id), allow_other_host: false
      end
  end
end
