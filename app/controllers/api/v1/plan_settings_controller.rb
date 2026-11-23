module Api
  module V1
    # Plan settings (spec: PlanSettingsResponse schema):
    # { data: { settings: { date_format, currency_format } } }.
    # PATCH is a documented extension for issue #54 (PLAN-03). It saves the
    # date and currency display formats only; stored amounts never change.
    class PlanSettingsController < BaseController
      before_action :set_plan

      def show
        render_data({ settings: settings_json })
      end

      # PATCH /v1/plans/:plan_id/settings
      #   { settings: { date_format: { format }, currency_format: { ... } } }
      # Either key may be sent. Invalid input is a 400 and nothing is saved.
      def update
        settings = params.require(:settings)
        date_format = settings.dig(:date_format, :format)
        currency_values = settings[:currency_format]&.permit(*CurrencyFormat.new.as_json.keys)&.to_h
        updates = {}

        if settings.key?(:date_format)
          return bad_request("date_format.format must be one of #{PlanLifecycle::DATE_FORMATS.join(', ')}.") unless PlanLifecycle::DATE_FORMATS.include?(date_format)

          updates[:date_format] = date_format
        end
        if settings.key?(:currency_format)
          return bad_request("currency_format must be an object.") if currency_values.nil?

          format, errors = CurrencyFormat.build(currency_values, base: plan.currency_format)
          return bad_request(errors.to_sentence) unless errors.empty?

          updates[:currency_format] = format.as_json
        end

        plan.update!(updates) if updates.any?
        render_data({ settings: settings_json }, server_knowledge: plan.server_knowledge)
      rescue ActionController::ParameterMissing
        bad_request("Request body must include a settings object.")
      end

      private
        def settings_json
          { date_format: { format: plan.date_format }, currency_format: plan.currency_format.as_json }
        end

        def bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
        end
    end
  end
end
