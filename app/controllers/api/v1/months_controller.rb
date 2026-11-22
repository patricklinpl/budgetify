module Api
  module V1
    # YNAB month endpoints (spec: MonthSummariesResponse,
    # MonthDetailResponse). Months carry the budgeting rollups computed
    # from the plan's per-month category amounts. Nested under
    # /v1/plans/:plan_id.
    class MonthsController < BaseController
      before_action :set_plan
      before_action :set_month, only: :show

      # GET /v1/plans/:plan_id/months - { data: { months: [MonthSummary], server_knowledge } }.
      # Months run from the plan's first month through the current month,
      # plus any earlier month with explicit amounts. Supports
      # last_knowledge_of_server delta requests, returning only months
      # whose categories changed after that knowledge (spec:
      # MonthSummariesResponse).
      def index
        render_data({
          months: delta_months(plan_months).map { |month| MonthSerializer.summary_as_json(plan, month) },
          server_knowledge: plan.server_knowledge
        })
      end

      # GET /v1/plans/:plan_id/months/:month - { data: { month: MonthDetail } }
      # with every category's amounts specific to the requested month.
      # "current" resolves to the current calendar month; future months
      # get a 400 (spec: months endpoints).
      def show
        return if @month.nil?

        render_data({ month: MonthSerializer.detail_as_json(plan, @month) })
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
          elsif @month < plan.created_at.to_date.beginning_of_month
            # Months before the plan's first month do not exist (spec:
            # getPlanMonth 404 "The plan month was not found").
            render_api_error(:not_found, "The plan month was not found.", id: "404.2", name: "resource_not_found")
            @month = nil
          end
        rescue ArgumentError, TypeError
          render_api_error(:bad_request, "The month is not valid; use ISO format (e.g. 2016-12-01) or \"current\".", id: "400", name: "bad_request")
          @month = nil
        end

        def plan_months
          current = Date.current.beginning_of_month
          months = []
          month = plan.created_at.to_date.beginning_of_month
          while month <= current
            months << month
            month = month.next_month
          end
          assigned = MonthCategory.joins(:category)
            .where(categories: { budget_id: plan.id })
            .where("month <= ?", current)
            .distinct.pluck(:month)
          (months | assigned).sort
        end

        def delta_months(months)
          knowledge = params[:last_knowledge_of_server]
          return months if knowledge.blank?

          changed_category_ids = plan.categories.where(knowledge: (knowledge.to_i + 1)..).select(:id)
          changed_months = MonthCategory.where(category_id: changed_category_ids).distinct.pluck(:month)
          # Debt inflows and payments can change month rollups even when
          # the transfer has no explicit spending category.
          transaction_months = plan.transactions.where(knowledge: (knowledge.to_i + 1)..).pluck(:date).map(&:beginning_of_month)
          changed_months |= transaction_months
          months & changed_months
        end
    end
  end
end
