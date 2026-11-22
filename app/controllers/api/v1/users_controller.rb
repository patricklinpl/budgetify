module Api
  module V1
    # GET /v1/user - YNAB UserResponse: { "data": { "user": { "id": uuid } } }
    # (spec: UserResponse schema). Auth and the 401 envelope come from
    # BaseController.
    class UsersController < BaseController
      def show
        render_data({ user: { id: Current.user.public_id } })
      end
    end
  end
end
