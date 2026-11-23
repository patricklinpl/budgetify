module Users
  class BudgetsController < ApplicationController
    layout "app_shell", only: :show

    def index
      @budgets = Current.user.budgets.order(:name)
    end

    def show
      @budget = Current.user.budgets.find_by!(public_id: params[:public_id])
      # Selected account is shell state carried in the URL so it survives Turbo
      # navigation. Scoped to this plan; unknown ids are a 404.
      if params[:account].present?
        @selected_account = @budget.accounts.not_deleted.find_by!(public_id: params[:account])
      end
    end
  end
end
