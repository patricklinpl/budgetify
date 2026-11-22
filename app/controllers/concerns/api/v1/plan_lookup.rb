module Api
  module V1
    # Plan lookup and delta-request support shared by all plan-scoped
    # endpoints. Our Budget model is a YNAB "plan" (spec: Plans tag); public
    # ids are the budgets.public_id UUIDs, never internal integer ids.
    module PlanLookup
      extend ActiveSupport::Concern

      # YNAB accepts "last-used" in place of a plan id (spec: plan_id
      # path parameter on /plans/{plan_id} and all plan-scoped routes).
      LAST_USED_PLAN_ID = "last-used"

      private
        attr_reader :plan

        # Resolves params[:plan_id] to the current user's Budget. "last-used"
        # resolves to the most recently used plan. Unknown or soft-deleted
        # ids get YNAB's documented 404.2 "resource_not_found" error (docs:
        # https://api.ynab.com/ - 404.1 "not_found" is for unknown URIs).
        def set_plan
          @plan = find_plan
          return render_api_error(:not_found, "No plan was found with the given id.", id: "404.2", name: "resource_not_found") if @plan.nil?

        # update_column on purpose: a read must not change the plan's data.
        # touch(:last_used_at) would also bump updated_at (the spec's
        # last_modified_on) and stamp a new knowledge value via
        # before_save, making plain GETs look like data changes.
        @plan.update_column(:last_used_at, Time.current)
        end

        # Applies a YNAB delta request to a list scope: when
        # last_knowledge_of_server is supplied, only entities changed after
        # that knowledge are returned, including soft-deleted tombstones
        # (spec: last_knowledge_of_server query parameter).
        def delta_scope(scope)
          knowledge = params[:last_knowledge_of_server]
          return scope.not_deleted if knowledge.blank?

          scope.where(knowledge: (knowledge.to_i + 1)..)
        end

        # The knowledge value to report as server_knowledge in plans-list
        # responses (spec: server_knowledge field on list responses).
        # Plan-scoped resources report plan.server_knowledge instead.
        def current_server_knowledge
          Current.user.server_knowledge
        end

        def find_plan
          plans = Current.user.budgets.not_deleted
          if params[:plan_id] == LAST_USED_PLAN_ID
            plans.order(Arel.sql("COALESCE(last_used_at, created_at) DESC")).first
          else
            plans.find_by(public_id: params[:plan_id])
          end
        end
    end
  end
end
