module Api
  module V1
    # YNAB money movement endpoints (spec: MoneyMovementsResponse). Money
    # movements record funds moved between categories in a month, or
    # to/from Ready to Assign; they are recorded when a month-category
    # assignment changes (issue #32). These endpoints are read-only.
    # Nested under /v1/plans/:plan_id.
    class MoneyMovementsController < BaseController
      before_action :set_plan
      before_action :set_month, only: :for_month

      # GET /v1/plans/:plan_id/money_movements -
      # { data: { money_movements: [MoneyMovement], server_knowledge } }.
      # Supports last_knowledge_of_server delta requests.
      def index
        render_data({
          money_movements: delta_scope(plan.money_movements).order(:knowledge).includes(:money_movement_group, :performed_by_user, :from_category, :to_category).map { |movement| MoneyMovementSerializer.as_json(movement) },
          server_knowledge: plan.server_knowledge
        })
      end

      # GET /v1/plans/:plan_id/months/:month/money_movements - money
      # movements scoped to one plan month (spec: getMoneyMovementsByMonth).
      def for_month
        return if @month.nil?

        render_data({
          money_movements: delta_scope(plan.money_movements.where(month: @month)).order(:knowledge).includes(:money_movement_group, :performed_by_user, :from_category, :to_category).map { |movement| MoneyMovementSerializer.as_json(movement) },
          server_knowledge: plan.server_knowledge
        })
      end

      private
        # "current" resolves to the current calendar month (UTC); otherwise
        # an ISO plan month (first of month). Invalid or future months get
        # a 400 (spec: 400 on the month endpoints).
        def set_month
          current = Date.current.beginning_of_month
          if params[:month] == "current"
            @month = current
            return
          end

          @month = Date.iso8601(params[:month]).beginning_of_month
          if @month > current
            render_api_error(:bad_request, "The month cannot be in the future.", id: "400", name: "bad_request")
            @month = nil
          end
        rescue ArgumentError, TypeError
          render_api_error(:bad_request, "The month is not valid; use ISO format (e.g. 2016-12-01) or \"current\".", id: "400", name: "bad_request")
          @month = nil
        end
    end
  end
end
