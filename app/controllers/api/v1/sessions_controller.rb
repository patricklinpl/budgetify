module Api
  module V1
    class SessionsController < BaseController
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> {
        render_api_error(:too_many_requests, "Too many login attempts. Try again later.")
      }

      before_action :authenticate_bearer_session!, only: :destroy

      def create
        email = params[:email]
        password = params[:password]
        user = if email.present? && password.present?
          User.authenticate_by(email_address: email, password: password)
        end
        return render json: {
          error: {
            id: "user_not_found",
            message: "Unauthorized: unknown username and/or password"
          }
        }, status: :unauthorized unless user

        user.increment!(:sign_in_count)
        user_session = user.sessions.create!(ip_address: request.remote_ip, user_agent: request.user_agent)
        session_token = user_session.generate_api_token!
        cookies.signed.permanent[:session_id] = {
          value: user_session.id,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production?
        }

        render json: {
          error: nil,
          session_token: session_token,
          email_confirmation_required: false,
          helpscout_user_hash: nil,
          castle_user_jwt: nil,
          user_help_access_initial_jwt: nil,
          user: {
            id: user.public_id,
            username: nil,
            email: user.email_address,
            is_subscribed: false,
            is_tombstone: false,
            trial_expires_on: nil,
            sign_in_count: user.sign_in_count,
            family_id: nil,
            family_role: nil,
            annual_subscription_price: nil,
            trial_days_remaining: nil,
            initial_budget_template: nil,
            required_privacy_policy_version: nil,
            is_referral_program_available: false,
            created_at: user.created_at.utc.iso8601(3),
            confirmed_at: nil,
            first_name: nil,
            self_reported_source: nil,
            initial_intention: nil
          }
        }, status: :ok
      end

      def destroy
        Current.session.destroy!
        cookies.delete(:session_id)
        head :no_content
      end
    end
  end
end
