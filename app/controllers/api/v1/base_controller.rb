module Api
  module V1
    class BaseController < ActionController::API
      include ActionController::Cookies
      include ApiRendering
      include PlanLookup

      # All API endpoints require a bearer token (spec: bearer security
      # scheme). SessionsController skips this for login.
      before_action :authenticate_bearer_session!

      # YNAB rate limit: 200 requests per rolling hour per access token
      # (docs: https://api.ynab.com/ - the window is rolling, so a
      # fixed-window counter like Rails' rate_limit would not be parity).
      # Runs after authentication so the limit keys on the token's session.
      RATE_LIMIT_MAX = 200
      RATE_LIMIT_WINDOW = 1.hour

      before_action :enforce_rolling_rate_limit

      private

      def authenticate_bearer_session!
        token = request.authorization&.match(/\ABearer\s+(\S+)\z/i)&.captures&.first
        Current.session = token && Session.authenticate_api_token(token)
        return true if Current.session

        render_api_error(:unauthorized, "A valid bearer token is required.", name: "not_authorized")
        false
      end

      def enforce_rolling_rate_limit
        key = "rate-limit:api:#{Current.session&.id || request.remote_ip}"
        now = Time.current.to_f
        hits = Array(Rails.cache.read(key)).select { |at| at > now - RATE_LIMIT_WINDOW }

        if hits.size >= RATE_LIMIT_MAX
          return render_api_error(:too_many_requests, "API rate limit exceeded: 200 requests per rolling hour per access token.")
        end

        Rails.cache.write(key, hits + [ now ], expires_in: RATE_LIMIT_WINDOW)
        true
      end
    end
  end
end
