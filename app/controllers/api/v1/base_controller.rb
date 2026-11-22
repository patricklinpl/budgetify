module Api
  module V1
    class BaseController < ActionController::API
      include ActionController::Cookies
      include ApiRendering
      include PlanLookup

      # All API endpoints require a bearer token (spec: bearer security
      # scheme). SessionsController skips this for login.
      before_action :authenticate_bearer_session!

      # YNAB rate limit: 200 requests per hour per access token, answered
      # with the standard error envelope. Runs after authentication so the
      # limit is keyed on the token's session.
      rate_limit to: 200, within: 1.hour,
                 by: -> { Current.session&.id || request.remote_ip },
                 with: -> { render_api_error(:too_many_requests, "API rate limit exceeded: 200 requests per hour per access token.") }

      private

      def authenticate_bearer_session!
        token = request.authorization&.match(/\ABearer\s+(\S+)\z/i)&.captures&.first
        Current.session = token && Session.authenticate_api_token(token)
        return true if Current.session

        render_api_error(:unauthorized, "A valid bearer token is required.")
        false
      end
    end
  end
end
