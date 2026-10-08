module Api
  module V1
    class BaseController < ActionController::API
      private

      def authenticate_bearer_session!
        token = request.authorization&.match(/\ABearer\s+(\S+)\z/i)&.captures&.first
        Current.session = token && Session.authenticate_api_token(token)
        return true if Current.session

        render_api_error(:unauthorized, "A valid bearer token is required.")
        false
      end

      def render_api_error(status, detail)
        status_code = Rack::Utils.status_code(status)
        render json: {
          error: {
            id: status_code.to_s,
            name: Rack::Utils::HTTP_STATUS_CODES.fetch(status_code),
            detail: detail
          }
        }, status: status
      end
    end
  end
end
