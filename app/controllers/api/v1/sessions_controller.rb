module Api
  module V1
    class SessionsController < BaseController
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> {
        render_api_error(:too_many_requests, "Too many login attempts. Try again later.")
      }

      before_action :authenticate_bearer_session!, only: :destroy

      def create
        user = User.authenticate_by(params.permit(:email_address, :password))
        return render_api_error(:unauthorized, "Invalid email address or password.") unless user

        session = user.sessions.create!(ip_address: request.remote_ip, user_agent: request.user_agent)
        access_token = session.generate_api_token!

        render json: {
          data: {
            access_token: access_token,
            token_type: "bearer"
          }
        }, status: :created
      end

      def destroy
        Current.session.destroy!
        head :no_content
      end
    end
  end
end
