module Api
  module V1
    # YNAB plan endpoints (spec: PlanSummaryResponse, PlanDetailResponse).
    # Our Budget model is a YNAB "plan".
    class PlansController < BaseController
      before_action :set_plan, only: :show

      # GET /v1/plans - { data: { plans: [...], default_plan: null } }.
      # default_plan is null because default-plan selection is not
      # configured (spec: default_plan nullable). Supports the spec's
      # include_accounts parameter and, as a documented extension (#25),
      # last_knowledge_of_server delta requests.
      def index
        include_accounts = params[:include_accounts] == "true"
        plans = delta_scope(Current.user.budgets).order(:knowledge).map do |plan|
          PlanSummary.as_json(plan, include_accounts: include_accounts)
        end
        render_data({ plans: plans, default_plan: nil }, server_knowledge: current_server_knowledge)
      end

      # GET /v1/plans/:plan_id - { data: { plan: PlanSummary } }. Accepts a
      # plan UUID or "last-used" (spec: plan_id path parameter). As in
      # YNAB's PlanDetailResponse, server_knowledge is included.
      def show
        include_accounts = params[:include_accounts] == "true"
        render_data({ plan: PlanSummary.as_json(plan, include_accounts: include_accounts) },
          server_knowledge: plan.server_knowledge)
      end
    end
  end
end
