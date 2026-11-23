module Users
  class BudgetsController < ApplicationController
    layout "app_shell", only: :show

    def index
      @budgets = Current.user.budgets.order(:name)
    end

    def show
      @budget = Current.user.budgets.find_by!(public_id: params[:public_id])
    end
  end
end
