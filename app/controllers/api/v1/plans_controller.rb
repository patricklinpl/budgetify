module Api
  module V1
    # YNAB plan endpoints (spec: PlanSummaryResponse, PlanDetailResponse).
    # Our Budget model is a YNAB "plan". Create, rename and Fresh Start are
    # documented extensions for issue #54.
    class PlansController < BaseController
      before_action :set_plan, only: %i[show update fresh_start]

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

      # POST /v1/plans { plan: { name } } creates one plan with the initial
      # default categories, no accounts, and its own settings (PLAN-01).
      def create
        name = plan_name_param
        return if name.nil?

        created = PlanLifecycle.create_plan(Current.user, name: name)
        render_data({ plan: PlanSummary.as_json(created) }, server_knowledge: created.server_knowledge, status: :created)
      end

      # PATCH /v1/plans/:plan_id { plan: { name } } renames the plan (PLAN-02).
      # An invalid name changes nothing.
      def update
        name = plan_name_param
        return if name.nil?

        plan.update!(name: name)
        render_data({ plan: PlanSummary.as_json(plan) }, server_knowledge: plan.server_knowledge)
      end

      # POST /v1/plans/:plan_id/fresh_start { plan: { name } } (PLAN-04,
      # PLAN-05). The optional name is for the new plan; by default it takes
      # the original name and the original is archived under a dated name.
      def fresh_start
        named = params[:plan].respond_to?(:key?) && params[:plan].key?(:name)
        name = named ? plan_name_param : nil
        return if named && name.nil?

        fresh = PlanLifecycle.fresh_start(plan, name: name)
        render_data({ plan: PlanSummary.as_json(fresh), archived_plan: PlanSummary.as_json(plan.reload) },
          server_knowledge: fresh.server_knowledge, status: :created)
      end

      private
        # Returns the stripped name, or renders a 400 and returns nil.
        def plan_name_param
          raw = params.require(:plan).permit(:name)[:name]
          name = raw.is_a?(String) ? raw.strip : ""
          if name.empty? || name.length > PlanLifecycle::MAX_NAME_LENGTH
            render_api_error(:bad_request, "Plan name is required and must be at most #{PlanLifecycle::MAX_NAME_LENGTH} characters.", id: "400", name: "bad_request")
            return nil
          end
          name
        rescue ActionController::ParameterMissing
          render_api_error(:bad_request, "Request body must include a plan object.", id: "400", name: "bad_request")
          nil
        end
    end
  end
end
