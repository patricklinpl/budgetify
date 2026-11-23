module Api
  module V1
    # YNAB category endpoints (spec: CategoriesResponse, CategoryResponse,
    # PostCategoryWrapper, PatchCategoryWrapper). Nested under
    # /v1/plans/:plan_id.
    class CategoriesController < BaseController
      before_action :set_plan

      # GET /v1/plans/:plan_id/categories - { data: { category_groups: [...], server_knowledge } }.
      # Each group embeds its categories with current-month amounts (spec:
      # CategoryGroupWithCategories). Supports last_knowledge_of_server
      # delta requests, returning tombstones for deleted groups/categories.
      def index
        groups = category_groups_scope.includes(:categories).order(:knowledge)
        render_data(
          { category_groups: groups.map { |group| serialize_group(group) } },
          server_knowledge: plan.server_knowledge
        )
      end

      # POST /v1/plans/:plan_id/categories - { data: { category: Category } }.
      # (spec: PostCategoryWrapper / NewCategory: name and category_group_id
      # required; internal groups rejected.)
      def create
        attributes = permitted_category_params
        return if attributes.nil?
        return unless apply_goal_frequency(attributes)
        return render_bad_request("The category name is required.") if attributes["name"].blank?

        group = find_group_for_write(attributes["category_group_id"])
        return if group.nil?

        category = group.categories.new(attributes.except("category_group_id").merge(budget: plan))
        apply_goal_defaults(category)
        return render_bad_request(category.errors.full_messages.to_sentence) unless category.save

        render json: { data: { category: CategorySerializer.as_json(category), server_knowledge: plan.reload.server_knowledge } }, status: :created
      end

      # GET /v1/plans/:plan_id/categories/:category_id -
      # { data: { category: Category } } with current-month amounts.
      def show
        category = find_category
        return if category.nil?

        render_data({ category: CategorySerializer.as_json(category) })
      end

      # PATCH /v1/plans/:plan_id/categories/:category_id -
      # { data: { category: Category } } (spec: PatchCategoryWrapper /
      # ExistingCategory). Internal categories cannot be modified; moving to
      # an internal group is rejected (spec: SaveCategory).
      def update
        category = find_category
        return if category.nil?
        return render_bad_request("Internal categories cannot be modified.") if category.internal?

        attributes = permitted_category_params
        return if attributes.nil?
        if category.payment? && (attributes["goal_frequency"].present? || !attributes["goal_needs_whole_amount"].nil?)
          return render_bad_request("These goal fields are not supported for Credit Card Payment categories.")
        end
        return unless apply_goal_frequency(attributes)

        if attributes.key?("category_group_id")
          group = find_group_for_write(attributes["category_group_id"])
          return if group.nil?
          attributes["category_group_id"] = group.id
        end

        apply_goal_defaults(category, attributes)
        return render_bad_request(category.errors.full_messages.to_sentence) unless category.update(attributes)

        render_data({ category: CategorySerializer.as_json(category) }, server_knowledge: plan.reload.server_knowledge)
      end

      # DELETE /v1/plans/:plan_id/categories/:category_id (Budgetify
      # extension, CAT-03/CAT-04). Optional replacement_category_id moves
      # transactions, scheduled items, assignments and availability;
      # return_assigned=true confirms returning assignments to Ready to
      # Assign. Refused with 422 and the impact when neither fits.
      def destroy
        category = find_category
        return if category.nil?

        replacement = nil
        if params[:replacement_category_id].present?
          replacement = plan.categories.find_by(public_id: params[:replacement_category_id])
          return render_bad_request("The replacement_category_id is not valid.") if replacement.nil? || replacement.deleted?
        end
        report = CategoryRemoval.delete_category!(category, replacement: replacement, return_assigned: params[:return_assigned] == "true")
        render_data({ category: CategorySerializer.as_json(category.reload), migration: report }, server_knowledge: plan.reload.server_knowledge)
      rescue CategoryRemoval::Blocked => error
        render json: { error: { id: "422", name: "unprocessable_entity", detail: error.message }, impact: error.impact }, status: :unprocessable_entity
      end

      private
        def permitted_category_params
          params.require(:category).permit(:name, :note, :hidden, :category_group_id, :goal_target, :goal_target_date, :goal_frequency, :goal_needs_whole_amount).to_h
        rescue ActionController::ParameterMissing
          render_bad_request("Request body must include a category object.")
          nil
        end

        def find_group_for_write(public_id)
          group = plan.category_groups.not_deleted.find_by(public_id: public_id)
          return render_bad_request("The category_group_id is not valid.") if group.nil?
          return render_bad_request("An internal category group may not be specified.") if group.internal?

          group
        end

        def find_category
          category = plan.categories.not_deleted.find_by(public_id: params[:category_id])
          render_api_error(:not_found, "No category was found with the given id.", id: "404.2", name: "resource_not_found") if category.nil?
          category
        end

        # spec: SaveCategory.goal_frequency (monthly/weekly/yearly) configures
        # a recurring NEED target of goal_target, replacing any existing
        # target. It requires goal_target and cannot be combined with
        # goal_target_date; a null or omitted frequency leaves cadence alone.
        # Cadence mapping per spec Category.goal_cadence (1 = Monthly,
        # 2 = Weekly, 13 = Yearly).
        GOAL_FREQUENCIES = { "monthly" => 1, "weekly" => 2, "yearly" => 13 }.freeze

        def apply_goal_frequency(attributes)
          return true unless attributes.key?("goal_frequency")

          frequency = attributes.delete("goal_frequency")
          return true if frequency.nil?

          cadence = GOAL_FREQUENCIES[frequency]
          return render_bad_request("The goal_frequency is not valid.") if cadence.nil?
          return render_bad_request("The goal_frequency requires a goal_target.") if attributes["goal_target"].blank?
          return render_bad_request("The goal_frequency cannot be combined with a goal_target_date.") unless attributes["goal_target_date"].nil?

          attributes["goal_type"] = "NEED"
          attributes["goal_cadence"] = cadence
          attributes["goal_cadence_frequency"] = 1
          attributes["goal_target_date"] = nil
          attributes["goal_day"] = nil
          attributes["goal_creation_month"] = Date.current.beginning_of_month
          true
        end

        # A specified goal target without a type defaults to a monthly NEED
        # goal created this month; an explicit null removes the target
        # (spec: SaveCategory.goal_target).
        def apply_goal_defaults(category, attributes = nil)
          if attributes.nil?
            if category.goal_target.present?
              category.goal_type ||= category.payment? ? "MF" : "NEED"
              category.goal_creation_month ||= Date.current.beginning_of_month
            end
          elsif attributes.key?("goal_target")
            if attributes["goal_target"].nil?
              attributes["goal_type"] = nil
              attributes["goal_target_date"] = nil
              attributes["goal_cadence"] = nil
              attributes["goal_cadence_frequency"] = nil
              attributes["goal_needs_whole_amount"] = nil
              attributes["goal_day"] = nil
            elsif attributes["goal_target"].present?
              attributes["goal_type"] ||= category.payment? ? "MF" : "NEED"
              attributes["goal_creation_month"] ||= Date.current.beginning_of_month
            end
          end
        end

        def category_groups_scope
          knowledge = params[:last_knowledge_of_server]
          return plan.category_groups.not_deleted if knowledge.blank?

          changed = knowledge.to_i + 1
          plan.category_groups.where("knowledge >= :changed OR id IN (:ids)",
            changed: changed,
            ids: plan.categories.where(knowledge: changed..).select(:category_group_id))
        end

        def serialize_group(group)
          categories = delta_scope(group.categories).order(:knowledge)
          CategoryGroupSerializer.as_json(group, categories: categories)
        end

        def render_bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
          nil
        end
    end
  end
end
