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
        name = nil
        if params.key?(:plan)
          return render_bad_plan unless params[:plan].is_a?(ActionController::Parameters)

          if params[:plan].key?(:name)
            name = PlanLifecycle.clean_name(params[:plan][:name])
            return render_bad_plan if name.nil?
          end
        end

        report = PlanLifecycle.carry_report(plan)
        fresh = PlanLifecycle.fresh_start(plan, name: name)
        render_data({ plan: PlanSummary.as_json(fresh), archived_plan: PlanSummary.as_json(plan.reload), carry_report: report },
          server_knowledge: fresh.server_knowledge, status: :created)
      rescue PlanLifecycle::UnsupportedCarry => e
        render json: { error: { id: "422", name: "unprocessable_entity",
          detail: "#{e.message} Close or fix these scheduled transactions first; nothing was changed." },
          blocking_scheduled_transactions: e.blockers }, status: :unprocessable_entity
      end

      private
        def render_bad_plan
          render_api_error(:bad_request, "Plan name is required, at most #{PlanLifecycle::MAX_NAME_LENGTH} characters, with no control characters.", id: "400", name: "bad_request")
        end

        # Returns the stripped name, or renders a 400 and returns nil.
        def plan_name_param
          plan_params = params[:plan]
          unless plan_params.is_a?(ActionController::Parameters)
            render_api_error(:bad_request, "Request body must include a plan object.", id: "400", name: "bad_request")
            return nil
          end
          name = PlanLifecycle.clean_name(plan_params[:name])
          render_bad_plan if name.nil?
          name
        end
    end
  end
end
