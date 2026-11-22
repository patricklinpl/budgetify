module Api
  module V1
    # YNAB category group endpoints (spec: SaveCategoryGroupResponse,
    # PostCategoryGroupWrapper, PatchCategoryGroupWrapper). Nested under
    # /v1/plans/:plan_id.
    class CategoryGroupsController < BaseController
      before_action :set_plan

      # POST /v1/plans/:plan_id/category_groups -
      # { data: { category_group: CategoryGroup, server_knowledge } }.
      def create
        attributes = permitted_group_params
        return if attributes.nil?

        group = plan.category_groups.new(attributes)
        return render_bad_request(group.errors.full_messages.to_sentence) unless group.save

        render json: { data: { category_group: CategoryGroupSerializer.as_json(group), server_knowledge: plan.server_knowledge } }, status: :created
      end

      # PATCH /v1/plans/:plan_id/category_groups/:category_group_id -
      # { data: { category_group: CategoryGroup, server_knowledge } }.
      # Internal groups cannot be modified.
      def update
        group = plan.category_groups.not_deleted.find_by(public_id: params[:category_group_id])
        return render_api_error(:not_found, "No category group was found with the given id.", id: "404.2", name: "resource_not_found") if group.nil?
        return render_bad_request("Internal category groups cannot be modified.") if group.internal?

        attributes = permitted_group_params
        return if attributes.nil?
        return render_bad_request(group.errors.full_messages.to_sentence) unless group.update(attributes)

        render_data({
          category_group: CategoryGroupSerializer.as_json(group),
          category_group_ids: group.categories.not_deleted.order(:knowledge).map(&:public_id)
        }, server_knowledge: plan.server_knowledge)
      end

      private
        def permitted_group_params
          params.require(:category_group).permit(:name).to_h
        rescue ActionController::ParameterMissing
          render_bad_request("Request body must include a category_group object.")
          nil
        end

        def render_bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
          nil
        end
    end
  end
end
