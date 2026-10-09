class AppHomesController < ApplicationController
  def show
    redirect_to users_budgets_path
  end
end
