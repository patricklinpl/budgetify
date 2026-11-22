module Api
  module V1
    # YNAB month category endpoints (spec: CategoryResponse,
    # PatchMonthCategoryWrapper / SaveMonthCategory). Only the assigned
    # (budgeted) amount can be updated. Nested under /v1/plans/:plan_id.
    class MonthCategoriesController < BaseController
      before_action :set_plan
      before_action :set_month
      before_action :set_category

      # GET /v1/plans/:plan_id/months/:month/categories/:category_id -
      # { data: { category: Category } } with amounts for that plan month.
      def show
        render_data({ category: CategorySerializer.as_json(@category, month: @month) })
      end

      # PATCH /v1/plans/:plan_id/months/:month/categories/:category_id -
      # assigns the month's budgeted amount (spec: SaveMonthCategory; other
      # fields are ignored). Internal categories are not assignable.
      def update
        return render_bad_request("Internal categories cannot be assigned.") if @category.internal?

        begin
          attributes = params.require(:category).permit(:budgeted).to_h
        rescue ActionController::ParameterMissing
          return render_bad_request("Request body must include a category object.")
        end
        return render_bad_request("The budgeted amount is required.") unless attributes.key?("budgeted") && !attributes["budgeted"].nil?

        month_category = @category.month_category_for(@month)
        previous_budgeted = month_category.budgeted.to_i
        month_category.budgeted = attributes["budgeted"]
        return render_bad_request(month_category.errors.full_messages.to_sentence) unless month_category.save

        record_money_movement(@month, month_category.budgeted.to_i - previous_budgeted)

        render_data({ category: CategorySerializer.as_json(@category, month: @month) }, server_knowledge: plan.reload.server_knowledge)
      end

      private
        # Assigning (or unassigning) a month amount records a money
        # movement between Ready to Assign and the category, bundled in its
        # own group (spec: MoneyMovement / MoneyMovementGroup; issue #32).
        # A positive change moves from Ready to Assign to the category; a
        # negative change moves back.
        def record_money_movement(month, delta)
          return if delta.zero?

          group = plan.money_movement_groups.create!(
            group_created_at: Time.current,
            month: month,
            performed_by_user: Current.user
          )
          plan.money_movements.create!(
            money_movement_group: group,
            month: month,
            moved_at: Time.current,
            performed_by_user: Current.user,
            from_category: delta.negative? ? @category : nil,
            to_category: delta.negative? ? nil : @category,
            amount: delta.abs
          )
        end

        # "current" resolves to the current calendar month (UTC); otherwise
        # an ISO plan month (first of month). Invalid or future months get
        # a 400 (spec: 400 on the month category endpoints).
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

        def set_category
          return if @month.nil?

          @category = plan.categories.not_deleted.find_by(public_id: params[:category_id])
          render_api_error(:not_found, "No category was found with the given id.", id: "404.2", name: "resource_not_found") if @category.nil?
        end

        def render_bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
          nil
        end
    end
  end
end
