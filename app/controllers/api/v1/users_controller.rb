module Api
  module V1
    class UsersController < BaseController
      before_action :authenticate_bearer_session!

      def show
        render json: { data: { user: { id: Current.user.public_id } } }
      end
    end
  end
end
