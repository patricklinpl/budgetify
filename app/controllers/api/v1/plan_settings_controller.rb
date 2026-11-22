module Api
  module V1
    # GET /v1/plans/:plan_id/settings - YNAB PlanSettingsResponse (spec:
    # PlanSettingsResponse schema): { data: { settings: { date_format, currency_format } } }.
    class PlanSettingsController < BaseController
      before_action :set_plan

      def show
        render_data({
          settings: {
            date_format: { format: plan.date_format },
            currency_format: plan.currency_format.as_json
          }
        })
      end
    end
  end
end
