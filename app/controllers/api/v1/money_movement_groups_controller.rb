module Api
  module V1
    # YNAB money movement group endpoints (spec:
    # MoneyMovementGroupsResponse). Related money movements are bundled in
    # groups; these endpoints are read-only (issue #32). Nested under
    # /v1/plans/:plan_id.
    class MoneyMovementGroupsController < BaseController
      before_action :set_plan
      before_action :set_month, only: :for_month

      # GET /v1/plans/:plan_id/money_movement_groups -
      # { data: { money_movement_groups: [MoneyMovementGroup], server_knowledge } }.
      # Supports last_knowledge_of_server delta requests.
      def index
        render_data({
          money_movement_groups: delta_scope(plan.money_movement_groups).order(:knowledge).includes(:performed_by_user).map { |group| MoneyMovementGroupSerializer.as_json(group) },
          server_knowledge: plan.server_knowledge
        })
      end

      # GET /v1/plans/:plan_id/months/:month/money_movement_groups - groups
      # scoped to one plan month (spec: getMoneyMovementGroupsByMonth).
      def for_month
        return if @month.nil?

        render_data({
          money_movement_groups: delta_scope(plan.money_movement_groups.where(month: @month)).order(:knowledge).includes(:performed_by_user).map { |group| MoneyMovementGroupSerializer.as_json(group) },
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
