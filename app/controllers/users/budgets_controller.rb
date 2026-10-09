module Users
  class BudgetsController < ApplicationController
    def index
      @budgets = Current.user.budgets.order(:name)
    end

    def show
      @budget = Current.user.budgets.find_by!(public_id: params[:public_id])
    end
  end
end
