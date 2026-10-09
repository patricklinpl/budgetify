module Api
  module V1
    class CatalogsController < BaseController
      before_action :authenticate_bearer_session!

      def index
        budgets = Current.user.budgets.order(:name).map do |budget|
          { id: budget.public_id, name: budget.name }
        end

        render json: { data: { budgets: budgets } }
      end
    end
  end
end
